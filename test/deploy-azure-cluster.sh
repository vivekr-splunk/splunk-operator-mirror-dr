#!/bin/bash

azure_scriptdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
azure_topdir=$(cd "${azure_scriptdir}/.." && pwd)
registry_auth_mode_file="${azure_topdir}/rehearsal/azure-registry-auth-mode.txt"

recordRegistryAuthMode() {
  mkdir -p "$(dirname "${registry_auth_mode_file}")"
  printf '%s\n' "$1" > "${registry_auth_mode_file}"
  echo "Azure registry pull mode resolved to: $1"
}

requestedRegistryAuthMode() {
  case "${PRIVATE_REGISTRY_AUTH_MODE:-node}" in
    node|secret|auto)
      printf '%s\n' "${PRIVATE_REGISTRY_AUTH_MODE:-node}"
      ;;
    *)
      printf '%s\n' "node"
      ;;
  esac
}

function deleteCluster() {
  echo "Delete Azure AKS Cluster ${TEST_CLUSTER_NAME}"
  tools/cleanup.sh
  rc=$(az aks delete --name ${TEST_CLUSTER_NAME} --resource-group ${AZURE_RESOURCE_GROUP} --yes)
}

function createCluster() {
  rm -f "${registry_auth_mode_file}"

  # Login to Container Registry (needed to push docker images later on)
  rc=$(az acr login --name ${AZURE_CONTAINER_REGISTRY})
    if [ -z "$rc" ]; then
      echo "Container Registry login issue"
      return 1
    fi

  # Create AKS Cluster
  rc=$(az aks create --resource-group ${AZURE_RESOURCE_GROUP} --name ${TEST_CLUSTER_NAME} --node-count ${CLUSTER_WORKERS} --node-vm-size standard_d8_v3)
  if [[ "${AZURE_MANAGED_ID_ENABLED}" == "true" ]] ;then
    echo "Managed Identity mode: need to assign read access for Kubelet user managed identity to the storage account"
    rc=$(az identity show --name ${AZURE_CLUSTER_AGENTPOOL} --resource-group ${AZURE_CLUSTER_AGENTPOOL_RG} --query 'principalId' --output tsv)
    rc=$(az role assignment create --assignee $rc --role 'Storage Blob Data Reader' --scope /subscriptions/f428689e-c379-4712-a5f4-408c754f16ff/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${AZURE_STORAGE_ACCOUNT})  
  else
    echo "No Azure managed-identity storage assignment requested"
  fi
  if [ -z "$rc" ]; then
    echo "AKS Cluster creation issue"
    return 1
  fi

  registry_auth_mode="$(requestedRegistryAuthMode)"
  has_registry_pull_secret="false"
  if [[ -n "${PRIVATE_REGISTRY_SERVER}" && -n "${PRIVATE_REGISTRY_USERNAME}" && -n "${PRIVATE_REGISTRY_PASSWORD}" ]] ;then
    has_registry_pull_secret="true"
  fi

  case "${registry_auth_mode}" in
    node)
      attach_output="$(az aks update --resource-group ${AZURE_RESOURCE_GROUP} --name ${TEST_CLUSTER_NAME} --attach-acr ${AZURE_CONTAINER_REGISTRY} 2>&1)"
      attach_rc=$?
      echo "${attach_output}"
      if [[ "${attach_rc}" -ne 0 ]] ;then
        echo "AKS ACR attach failed while PRIVATE_REGISTRY_AUTH_MODE=node"
        return 1
      fi
      recordRegistryAuthMode "node"
      ;;
    secret)
      if [[ "${has_registry_pull_secret}" != "true" ]] ;then
        echo "PRIVATE_REGISTRY_AUTH_MODE=secret requires PRIVATE_REGISTRY_SERVER/USERNAME/PASSWORD"
        return 1
      fi
      echo "Using Kubernetes imagePullSecrets for ACR access"
      recordRegistryAuthMode "secret"
      ;;
    auto)
      attach_output="$(az aks update --resource-group ${AZURE_RESOURCE_GROUP} --name ${TEST_CLUSTER_NAME} --attach-acr ${AZURE_CONTAINER_REGISTRY} 2>&1)"
      attach_rc=$?
      echo "${attach_output}"
      if [[ "${attach_rc}" -eq 0 ]] ;then
        recordRegistryAuthMode "node"
      elif [[ "${has_registry_pull_secret}" == "true" ]] ;then
        echo "AKS ACR attach failed; falling back to Kubernetes imagePullSecrets"
        recordRegistryAuthMode "secret"
      else
        echo "AKS ACR attach failed and no Kubernetes pull-secret credentials were supplied"
        return 1
      fi
      ;;
  esac

  rc=$(az aks get-credentials --resource-group ${AZURE_RESOURCE_GROUP} --name ${TEST_CLUSTER_NAME} --overwrite-existing)

  # List created nodes
  rc=$(kubectl get nodes)
  echo "$rc"
}
