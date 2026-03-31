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
  if [ -z "${PRIVATE_REGISTRY_SERVER:-}" ] || [ -z "${PRIVATE_REGISTRY_USERNAME:-}" ] || [ -z "${PRIVATE_REGISTRY_PASSWORD:-}" ]; then
    PRIVATE_REGISTRY_HELM_FLAG=""
    return 0
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
  if [ -z "${PRIVATE_REGISTRY_SERVER:-}" ] || [ -z "${PRIVATE_REGISTRY_USERNAME:-}" ] || [ -z "${PRIVATE_REGISTRY_PASSWORD:-}" ]; then
    return 0
  fi

  PRIVATE_REGISTRY_SECRET_NAME="${PRIVATE_REGISTRY_SECRET_NAME:-private-registry-credentials}"
  kubectl patch serviceaccount controller-manager -n splunk-operator --type=merge \
    -p "{\"imagePullSecrets\":[{\"name\":\"${PRIVATE_REGISTRY_SECRET_NAME}\"}]}"
  kubectl patch deployment splunk-operator-controller-manager -n splunk-operator --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"${PRIVATE_REGISTRY_SECRET_NAME}\"}]}}}}"
  kubectl rollout restart deployment splunk-operator-controller-manager -n splunk-operator >/dev/null 2>&1 || true
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
