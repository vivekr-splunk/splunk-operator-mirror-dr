# Splunk Operator Helm Installation

## Distribution Model

The supported Helm distribution model for Splunk Operator is OCI-first.

- the release pipeline packages and validates OCI charts
- release candidates publish to an internal OCI chart repository first
- approved GA releases publish to the official external OCI chart destination recorded in the release notes
- the GitHub Pages Helm repo is compatibility-only for older consumers and should not be used for new automation

Use the chart base published for your release. For GA that is the official external OCI chart base. For rehearsal and RC validation that is the internal staging OCI chart base.

```bash
export SPLUNK_HELM_OCI_BASE=oci://<published-chart-registry-base>
export SPLUNK_OPERATOR_CHART_VERSION=<released-chart-version>
```

Example internal rehearsal base:

```bash
export SPLUNK_HELM_OCI_BASE=oci://docker.repo.splunkdev.net/helm
```

## CRDs

Users must install the latest CRDs manually before the first Helm install. This is a [Helm limitation](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/). The `splunk-operator` chart does not carry the CRDs because they exceed Helm chart size limits.

Install CRDs from a tagged source tree:

```bash
git clone https://github.com/splunk/splunk-operator.git .
git checkout release/3.0.0
make install
```

Or install CRDs from a released asset:

```bash
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-crds.yaml --server-side
```

## Splunk Operator Chart

Inspect chart metadata and values:

```bash
helm show chart "${SPLUNK_HELM_OCI_BASE}/splunk-operator" --version "${SPLUNK_OPERATOR_CHART_VERSION}"
helm show values "${SPLUNK_HELM_OCI_BASE}/splunk-operator" --version "${SPLUNK_OPERATOR_CHART_VERSION}"
```

Install the operator with a values file:

```bash
helm install -f new_values.yaml splunk-operator-test \
  "${SPLUNK_HELM_OCI_BASE}/splunk-operator" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  -n splunk-operator
```

Install the operator with CLI overrides:

```bash
helm install splunk-operator-test \
  "${SPLUNK_HELM_OCI_BASE}/splunk-operator" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  --set splunkOperator.clusterWideAccess=false \
  -n splunk-operator
```

Upgrade an existing release:

```bash
helm upgrade -f new_values.yaml splunk-operator-test \
  "${SPLUNK_HELM_OCI_BASE}/splunk-operator" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  -n splunk-operator
```

Uninstall the operator:

```bash
helm uninstall splunk-operator-test -n splunk-operator
```

## Splunk Enterprise Chart

The `splunk-enterprise` chart depends on the `splunk-operator` chart. In the OCI publication flow that dependency is packaged as part of the published chart artifact, so you do not need to run `helm repo add` or manage a separate chart repository index for normal installs.

Inspect chart metadata and values:

```bash
helm show chart "${SPLUNK_HELM_OCI_BASE}/splunk-enterprise" --version "${SPLUNK_OPERATOR_CHART_VERSION}"
helm show values "${SPLUNK_HELM_OCI_BASE}/splunk-enterprise" --version "${SPLUNK_OPERATOR_CHART_VERSION}"
```

If the operator is already installed, disable the bundled operator dependency:

```bash
helm install splunk-enterprise-test \
  "${SPLUNK_HELM_OCI_BASE}/splunk-enterprise" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  --set splunk-operator.enabled=false \
  -n splunk-operator
```

Example values file:

```yaml
clusterManager:
  enabled: true
  name: cm-test

indexerCluster:
  enabled: true
  name: idxc-test

searchHeadCluster:
  enabled: true
  name: shc-test
```

Install from that values file:

```bash
helm install -f new_values.yaml splunk-enterprise-test \
  "${SPLUNK_HELM_OCI_BASE}/splunk-enterprise" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  -n splunk-operator
```

Uninstall the enterprise release:

```bash
helm uninstall splunk-enterprise-test -n splunk-operator
```

`helm uninstall` removes the Helm-managed resources. CRDs and PVCs still need to be cleaned up manually when appropriate.

## Splunk Validated Architecture Examples

Install a standalone S1 deployment:

```bash
helm install splunk-enterprise-s1 \
  "${SPLUNK_HELM_OCI_BASE}/splunk-enterprise" \
  --version "${SPLUNK_OPERATOR_CHART_VERSION}" \
  --set s1.enabled=true \
  -n splunk-operator
```

The `splunk-enterprise` chart also supports:

- [Single Server Deployment (S1)](https://www.splunk.com/pdfs/technical-briefs/splunk-validated-architectures.pdf#page=9)
- [Distributed Clustered Deployment + SHC - Single Site (C3)](https://www.splunk.com/pdfs/technical-briefs/splunk-validated-architectures.pdf#page=14)
- [Distributed Clustered Deployment + SHC - Multi-Site (M4)](https://www.splunk.com/pdfs/technical-briefs/splunk-validated-architectures.pdf#page=20)

## Troubleshooting

If Helm reports that Splunk custom resources are unknown, install or update the CRDs first:

```text
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: resource mapping not found ...
ensure CRDs are installed first
```

For chart values and defaults in the source tree, see:

- [splunk-operator values](https://github.com/splunk/splunk-operator/blob/develop/helm-chart/splunk-operator/values.yaml)
- [splunk-enterprise values](https://github.com/splunk/splunk-operator/blob/develop/helm-chart/splunk-enterprise/values.yaml)

## Legacy Compatibility Repository

The legacy GitHub Pages repository remains compatibility-only:

```bash
helm repo add splunk https://splunk.github.io/splunk-operator/
helm repo update
```

Use that path only for older consumers that still require an `index.yaml` based Helm repository. New automation and release validation should use OCI chart references.
