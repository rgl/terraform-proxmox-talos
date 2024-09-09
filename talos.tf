locals {
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_controller_hostnum + i)
    }
  ]
  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_worker_hostnum + i)
    }
  ]
  common_machine_config = {
    machine = {
      # NB the install section changes are only applied after a talos upgrade
      #    (which we do not do). instead, its preferred to create a custom
      #    talos image, which is created in the installed state.
      #install = {}
      features = {
        # see https://www.talos.dev/v1.7/kubernetes-guides/configuration/kubeprism/
        # see talosctl -n $c0 read /etc/kubernetes/kubeconfig-kubelet | yq .clusters[].cluster.server
        # NB if you use a non-default CNI, you must configure it to use the
        #    https://localhost:7445 kube-apiserver endpoint.
        kubePrism = {
          enabled = true
          port    = 7445
        }
      }
      kernel = {
        modules = [
          // piraeus dependencies.
          {
            name = "drbd"
            parameters = [
              "usermode_helper=disabled",
            ]
          },
          {
            name = "drbd_transport_tcp"
          },
        ]
      }
    }
    cluster = {
      # see https://www.talos.dev/v1.7/talos-guides/discovery/
      # see https://www.talos.dev/v1.7/reference/configuration/#clusterdiscoveryconfig
      discovery = {
        enabled = true
        registries = {
          kubernetes = {
            disabled = false
          }
          service = {
            disabled = true
          }
        }
      }
      network = {
        cni = {
          name = "none"
        }
      }
      proxy = {
        disabled = true
      }
    }
  }
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/resources/machine_secrets
resource "talos_machine_secrets" "talos" {
  talos_version = "v${var.talos_version}"
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            # see https://www.talos.dev/v1.7/talos-guides/network/vip/
            {
              interface = "eth0"
              vip = {
                ip = var.cluster_vip
              }
            }
          ]
        }
      }
    }),
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name     = "spin"
            contents = <<-EOF
            apiVersion: node.k8s.io/v1
            kind: RuntimeClass
            metadata:
              name: wasmtime-spin-v2
            handler: spin
            EOF
          },
          {
            name = "cilium"
            contents = join("---\n", [
              data.helm_template.cilium.manifest,
              "# Source cilium.tf\n${local.cilium_external_lb_manifest}",
            ])
          },
          {
            name = "cert-manager"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = "cert-manager"
                }
              }),
              data.helm_template.cert_manager.manifest,
              "# Source cert-manager.tf\n${local.cert_manager_ingress_ca_manifest}",
            ])
          },
          {
            name     = "trust-manager"
            contents = data.helm_template.trust_manager.manifest
          },
          {
            name     = "reloader"
            contents = data.helm_template.reloader.manifest
          },
          {
            name     = "gitea"
            contents = local.gitea_manifest
          },
          {
            name = "argocd"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = local.argocd_namespace
                }
              }),
              data.helm_template.argocd.manifest,
              "# Source argocd.tf\n${local.argocd_manifest}",
            ])
          },
        ],
      },
    }),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/data-sources/client_configuration
data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/data-sources/cluster_kubeconfig
data "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "controller" {
  count                       = var.controller_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  endpoint                    = local.controller_nodes[count.index].address
  node                        = local.controller_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = local.controller_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    proxmox_virtual_environment_vm.controller,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = local.worker_nodes[count.index].address
  node                        = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = local.worker_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    proxmox_virtual_environment_vm.worker,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.5.0/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
}
