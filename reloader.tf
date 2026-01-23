# install reloader.
# NB tls libraries typically load the certificates from ca-certificates.crt
#    file once, when they are started, and they never reload the file again.
#    reloader will automatically restart them when their configmap/secret
#    changes.
# NB the default values are described at:
#       https://github.com/stakater/reloader/blob/v2.2.7/deployments/kubernetes/chart/reloader/values.yaml
#    NB make sure you are seeing the same version of the chart that you are installing.
# see https://github.com/stakater/reloader
# see https://artifacthub.io/packages/helm/stakater/reloader
# see https://cert-manager.io/docs/tutorials/getting-started-with-trust-manager/
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "reloader" {
  namespace  = "kube-system"
  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  # renovate: datasource=helm depName=reloader registryUrl=https://stakater.github.io/stakater-charts
  version      = "2.2.7"
  kube_version = var.kubernetes_version
  api_versions = []
  set = [
    {
      name  = "reloader.autoReloadAll"
      value = "false"
    }
  ]
}
