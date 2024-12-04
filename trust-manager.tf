# install trust-manager.
# NB the default values are described at:
#       https://github.com/cert-manager/trust-manager/blob/v0.14.0/deploy/charts/trust-manager/values.yaml
#    NB make sure you are seeing the same version of the chart that you are installing.
# see https://cert-manager.io/docs/tutorials/getting-started-with-trust-manager/
# see https://github.com/cert-manager/trust-manager
# see https://github.com/golang/go/blob/go1.22.3/src/crypto/x509/root_linux.go
# see https://artifacthub.io/packages/helm/cert-manager/trust-manager
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "trust_manager" {
  namespace  = "cert-manager"
  name       = "trust-manager"
  repository = "https://charts.jetstack.io"
  chart      = "trust-manager"
  # renovate: datasource=helm depName=trust-manager registryUrl=https://charts.jetstack.io
  version      = "0.14.0"
  kube_version = var.kubernetes_version
  api_versions = []
  set {
    name  = "secretTargets.enabled"
    value = "true"
  }
  set {
    name  = "secretTargets.authorizedSecretsAll"
    value = "true"
  }
}
