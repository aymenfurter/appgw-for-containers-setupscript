#!/bin/bash

RG_LOCATION="eastus"
COMPANY_PREFIX="contoso"
ENVIRONMENT="prod"
AKS_NAME="${COMPANY_PREFIX}-k8s-${ENVIRONMENT}-eastus"
RESOURCE_GROUP="${COMPANY_PREFIX}-rg-${ENVIRONMENT}-eastus"
VNET_NAME="${COMPANY_PREFIX}-vnet-${ENVIRONMENT}-eastus"
ALB_SUBNET_NAME="${COMPANY_PREFIX}-subnet-alb-${ENVIRONMENT}-eastus"
IDENTITY_RESOURCE_NAME="${COMPANY_PREFIX}-azure-alb-identity-${ENVIRONMENT}-eastus"

az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

# Install Azure CLI extensions.
az extension add --name alb

AKS_CLUSTER_EXISTENCE=$(az aks show --name $AKS_NAME --resource-group $RESOURCE_GROUP --output tsv --query "name" 2>/dev/null)

if [ -z "$AKS_CLUSTER_EXISTENCE" ]; then
    az group create --name $RESOURCE_GROUP --location $RG_LOCATION

    az aks create \
      --resource-group $RESOURCE_GROUP \
      --name $AKS_NAME \
      --location $RG_LOCATION \
      --network-plugin azure \
      --enable-oidc-issuer \
      --enable-workload-identity \
      --enable-addons monitoring,http_application_routing \
      --generate-ssh-keys
fi
    MC_RESOURCE_GROUP=$(az aks show --name $AKS_NAME --resource-group $RESOURCE_GROUP --query "nodeResourceGroup" -o tsv)
    CLUSTER_SUBNET_ID=$(az vmss list --resource-group $MC_RESOURCE_GROUP --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv)

    read -d '' VNET_NAME VNET_RESOURCE_GROUP VNET_ID <<< $(az network vnet show --ids $CLUSTER_SUBNET_ID --query '[name, resourceGroup, id]' -o tsv)

    SUBNET_ADDRESS_PREFIX='10.225.0.0/16' 

    az network vnet subnet create \
      --resource-group $VNET_RESOURCE_GROUP \
      --vnet-name $VNET_NAME \
      --name $ALB_SUBNET_NAME \
      --address-prefixes $SUBNET_ADDRESS_PREFIX \
      --delegations 'Microsoft.ServiceNetworking/trafficControllers'

    ALB_SUBNET_ID=$(az network vnet subnet show --name $ALB_SUBNET_NAME --resource-group $VNET_RESOURCE_GROUP --vnet-name $VNET_NAME --query '[id]' --output tsv)

    az identity create --name $IDENTITY_RESOURCE_NAME --resource-group $RESOURCE_GROUP

    principalId=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)
    mcResourceGroupId=$(az group show --name $MC_RESOURCE_GROUP --query id -otsv)

    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

    echo "Deployment complete!"

az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME

AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
az identity federated-credential create --name "azure-alb-identity" \
    --identity-name "$IDENTITY_RESOURCE_NAME" \
    --resource-group $RESOURCE_GROUP \
    --issuer "$AKS_OIDC_ISSUER" \
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
     --version 0.4.023971 \
     --set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query clientId -o tsv)

sleep 5
# Apply the first Kubernetes YAML definition
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: alb-test-infra
EOF

print "ALB Subnet: $ALB_SUBNET_ID"

# Apply the second Kubernetes YAML definition
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-test
  namespace: alb-test-infra
spec:
  associations:
  - $ALB_SUBNET_ID
EOF

kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/traffic-split-scenario/deployment.yaml
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: gateway-01
  namespace: test-infra
  annotations:
    alb.networking.azure.io/alb-namespace: alb-test-infra
    alb.networking.azure.io/alb-name: alb-test
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http-listener
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: http-route
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
    namespace: test-infra
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /bar
    backendRefs:
    - name: backend-v2
      port: 8080
  - matches:
    - headers:
      - type: Exact
        name: magic
        value: foo
      queryParams:
      - type: Exact
        name: great
        value: example
      path:
        type: PathPrefix
        value: /some/thing
      method: GET
    backendRefs:
    - name: backend-v2
      port: 8080
  - backendRefs:
    - name: backend-v1
      port: 8080
EOF
