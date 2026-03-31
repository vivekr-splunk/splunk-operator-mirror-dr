#!/bin/bash

scriptdir=$(dirname "$0")
topdir=${scriptdir}/..

source ${scriptdir}/env.sh

# Check if exactly 2 arguments are supplied
if [ "$#" -ne 2 ]; then
  echo "Error: Exactly 2 arguments are required."
  echo "Usage: $0 <PRIVATE_SPLUNK_OPERATOR_IMAGE> <PRIVATE_SPLUNK_ENTERPRISE_IMAGE>"
  exit 1
fi

# Assign arguments to variables
PRIVATE_SPLUNK_OPERATOR_IMAGE="$1"
PRIVATE_SPLUNK_ENTERPRISE_IMAGE="$2"

effective_private_registry_auth_mode() {
  case "${PRIVATE_REGISTRY_AUTH_MODE:-auto}" in
    node|secret)
      printf '%s\n' "${PRIVATE_REGISTRY_AUTH_MODE}"
      return
      ;;
  esac

  if [ -n "${PRIVATE_REGISTRY_SERVER:-}" ] && [ -n "${PRIVATE_REGISTRY_USERNAME:-}" ] && [ -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]; then
    printf '%s\n' "secret"
    return
  fi

  printf '%s\n' "node"
}

assert_operator_registry_access_mode() {
  OPERATOR_DEPLOYMENT_NAME="$(kubectl get deployment -n splunk-operator -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')"
  if [ -z "${OPERATOR_DEPLOYMENT_NAME}" ]; then
    echo "Unable to locate operator deployment in splunk-operator namespace"
    return 1
  fi

  OPERATOR_SERVICE_ACCOUNT_NAME="$(kubectl get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n splunk-operator -o jsonpath='{.spec.template.spec.serviceAccountName}')"
  if [ -z "${OPERATOR_SERVICE_ACCOUNT_NAME}" ]; then
    OPERATOR_SERVICE_ACCOUNT_NAME="default"
  fi

  EFFECTIVE_REGISTRY_AUTH_MODE="$(effective_private_registry_auth_mode)"
  DEPLOYMENT_PULL_SECRETS="$(kubectl get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n splunk-operator -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}')"
  SERVICE_ACCOUNT_PULL_SECRETS="$(kubectl get serviceaccount "${OPERATOR_SERVICE_ACCOUNT_NAME}" -n splunk-operator -o jsonpath='{.imagePullSecrets[*].name}')"

  echo "Operator registry access mode: ${EFFECTIVE_REGISTRY_AUTH_MODE}"
  echo "Operator deployment image pull secrets: ${DEPLOYMENT_PULL_SECRETS:-<none>}"
  echo "Operator service account image pull secrets: ${SERVICE_ACCOUNT_PULL_SECRETS:-<none>}"

  case "${EFFECTIVE_REGISTRY_AUTH_MODE}" in
    node)
      if [ -n "${DEPLOYMENT_PULL_SECRETS}" ] || [ -n "${SERVICE_ACCOUNT_PULL_SECRETS}" ]; then
        echo "Node registry auth mode must not use Kubernetes imagePullSecrets"
        return 1
      fi
      ;;
    secret)
      if [ -z "${PRIVATE_REGISTRY_SECRET_NAME:-}" ]; then
        PRIVATE_REGISTRY_SECRET_NAME="${PRIVATE_REGISTRY_SECRET_NAME:-private-registry-credentials}"
      fi
      case " ${DEPLOYMENT_PULL_SECRETS} " in
        *" ${PRIVATE_REGISTRY_SECRET_NAME} "*) ;;
        *)
          echo "Operator deployment does not reference the expected image pull secret ${PRIVATE_REGISTRY_SECRET_NAME}"
          return 1
          ;;
      esac
      case " ${SERVICE_ACCOUNT_PULL_SECRETS} " in
        *" ${PRIVATE_REGISTRY_SECRET_NAME} "*) ;;
        *)
          echo "Operator service account does not reference the expected image pull secret ${PRIVATE_REGISTRY_SECRET_NAME}"
          return 1
          ;;
      esac
      ;;
  esac
}

wait_for_enterprise_crds() {
  for crd in \
    clustermanagers.enterprise.splunk.com \
    clustermasters.enterprise.splunk.com \
    indexerclusters.enterprise.splunk.com \
    licensemanagers.enterprise.splunk.com \
    licensemasters.enterprise.splunk.com \
    monitoringconsoles.enterprise.splunk.com \
    searchheadclusters.enterprise.splunk.com \
    standalones.enterprise.splunk.com
  do
    echo "Waiting for CRD ${crd} to become Established..."
    kubectl wait --for=condition=Established --timeout=300s "crd/${crd}"
  done
}

ensure_private_registry_pull_secret() {
  if [ "$(effective_private_registry_auth_mode)" != "secret" ]; then
    PRIVATE_REGISTRY_HELM_FLAG=""
    return 0
  fi

  if [ -z "${PRIVATE_REGISTRY_SERVER:-}" ] || [ -z "${PRIVATE_REGISTRY_USERNAME:-}" ] || [ -z "${PRIVATE_REGISTRY_PASSWORD:-}" ]; then
    echo "PRIVATE_REGISTRY_AUTH_MODE=secret requires PRIVATE_REGISTRY_SERVER/USERNAME/PASSWORD"
    return 1
  fi

  PRIVATE_REGISTRY_SECRET_NAME="${PRIVATE_REGISTRY_SECRET_NAME:-private-registry-credentials}"
  PRIVATE_REGISTRY_HELM_FLAG="--set splunkOperator.imagePullSecrets[0].name=${PRIVATE_REGISTRY_SECRET_NAME}"
  kubectl get namespace splunk-operator >/dev/null 2>&1 || kubectl create namespace splunk-operator >/dev/null
  kubectl -n splunk-operator create secret docker-registry "${PRIVATE_REGISTRY_SECRET_NAME}" \
    --docker-server="${PRIVATE_REGISTRY_SERVER}" \
    --docker-username="${PRIVATE_REGISTRY_USERNAME}" \
    --docker-password="${PRIVATE_REGISTRY_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

patch_operator_registry_access() {
  if [ "$(effective_private_registry_auth_mode)" != "secret" ]; then
    return 0
  fi

  if [ -z "${PRIVATE_REGISTRY_SERVER:-}" ] || [ -z "${PRIVATE_REGISTRY_USERNAME:-}" ] || [ -z "${PRIVATE_REGISTRY_PASSWORD:-}" ]; then
    echo "PRIVATE_REGISTRY_AUTH_MODE=secret requires PRIVATE_REGISTRY_SERVER/USERNAME/PASSWORD"
    return 1
  fi

  PRIVATE_REGISTRY_SECRET_NAME="${PRIVATE_REGISTRY_SECRET_NAME:-private-registry-credentials}"
  OPERATOR_DEPLOYMENT_NAME="$(kubectl get deployment -n splunk-operator -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')"
  if [ -z "${OPERATOR_DEPLOYMENT_NAME}" ]; then
    echo "Unable to locate operator deployment in splunk-operator namespace"
    return 1
  fi

  OPERATOR_SERVICE_ACCOUNT_NAME="$(kubectl get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n splunk-operator -o jsonpath='{.spec.template.spec.serviceAccountName}')"
  if [ -z "${OPERATOR_SERVICE_ACCOUNT_NAME}" ]; then
    OPERATOR_SERVICE_ACCOUNT_NAME="default"
  fi

  echo "Patching operator registry access with secret ${PRIVATE_REGISTRY_SECRET_NAME} on service account ${OPERATOR_SERVICE_ACCOUNT_NAME} and deployment ${OPERATOR_DEPLOYMENT_NAME}"
  kubectl patch serviceaccount "${OPERATOR_SERVICE_ACCOUNT_NAME}" -n splunk-operator --type=merge \
    -p "{\"imagePullSecrets\":[{\"name\":\"${PRIVATE_REGISTRY_SECRET_NAME}\"}]}" >/dev/null
  kubectl patch deployment "${OPERATOR_DEPLOYMENT_NAME}" -n splunk-operator --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"${PRIVATE_REGISTRY_SECRET_NAME}\"}]}}}}" >/dev/null

  assert_operator_registry_access_mode

  kubectl rollout restart deployment "${OPERATOR_DEPLOYMENT_NAME}" -n splunk-operator >/dev/null
}

ensure_private_registry_pull_secret

if [  "${DEPLOYMENT_TYPE}" == "helm" ]; then
  echo "Installing Splunk Operator using Helm charts"
  helm uninstall splunk-operator -n splunk-operator
  # Install the CRDs
  echo "Installing enterprise CRDs..."
  make kustomize
  make uninstall
  make install
  if [ "${CLUSTER_WIDE}" != "true" ]; then
    helm install splunk-operator --create-namespace --namespace splunk-operator --set splunkOperator.clusterWideAccess=false --set splunkOperator.image.repository=${PRIVATE_SPLUNK_OPERATOR_IMAGE} --set image.repository=${PRIVATE_SPLUNK_ENTERPRISE_IMAGE} --set splunkOperator.splunkGeneralTerms="--accept-sgt-current-at-splunk-com" ${PRIVATE_REGISTRY_HELM_FLAG:-} helm-chart/splunk-operator
  else
    helm install splunk-operator --create-namespace --namespace splunk-operator --set splunkOperator.image.repository=${PRIVATE_SPLUNK_OPERATOR_IMAGE} --set image.repository=${PRIVATE_SPLUNK_ENTERPRISE_IMAGE} --set splunkOperator.splunkGeneralTerms="--accept-sgt-current-at-splunk-com" ${PRIVATE_REGISTRY_HELM_FLAG:-} helm-chart/splunk-operator
  fi
elif [  "${CLUSTER_WIDE}" != "true" ]; then
  # Install the CRDs
  echo "Installing enterprise CRDs..."
  make kustomize
  make uninstall
  bin/kustomize build config/crd | kubectl create -f -
else
  echo "Installing enterprise operator from ${PRIVATE_SPLUNK_OPERATOR_IMAGE} using enterprise image from ${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}..."
  echo "Installing enterprise CRDs..."
  make kustomize
  make uninstall
  make install
  wait_for_enterprise_crds
  make deploy IMG=${PRIVATE_SPLUNK_OPERATOR_IMAGE} SPLUNK_ENTERPRISE_IMAGE=${PRIVATE_SPLUNK_ENTERPRISE_IMAGE} SPLUNK_GENERAL_TERMS="--accept-sgt-current-at-splunk-com" WATCH_NAMESPACE="" ENVIRONMENT=debug
  patch_operator_registry_access
  assert_operator_registry_access_mode
fi

if [ $? -ne 0 ]; then
  echo "Unable to install the operator. Exiting..."
  kubectl describe pod -n splunk-operator
  exit 1
fi

echo "Dumping operator config here..."
kubectl describe deployment splunk-operator-controller-manager -n splunk-operator


if [  "${CLUSTER_WIDE}" == "true" ]; then
  echo "wait for operator pod to be ready..."
  # sleep before checking for deployment, in slow clusters deployment call may not even started
  # in those cases, kubectl will fail with error:  no matching resources found
  sleep 2
  kubectl wait --for=condition=ready pod -l control-plane=controller-manager --timeout=600s -n splunk-operator
  if [ $? -ne 0 ]; then
    echo "kubectl get pods -n kube-system ---"
    kubectl get pods -n kube-system
    echo "kubectl get deployement ebs-csi-controller -n kube-system ---"
    kubectl get deployement ebs-csi-controller -n kube-system
    echo "kubectl describe pvc -n splunk-operator ---"
    kubectl describe pvc -n splunk-operator
    echo "kubectl describe pv ---"
    kubectl describe pv
    echo "kubectl describe pod -n splunk-operator ---"
    kubectl describe pod -n splunk-operator
    echo "Operator installation not ready..."
    exit 1
  fi
fi
