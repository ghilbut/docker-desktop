resource kubernetes_namespace cassandra {
  metadata {
    name = "cassandra"
  }
}

resource null_resource cassandra {
  triggers = {
    manifest = data.template_file.cassandra.rendered
  }

  provisioner local-exec {
    command = self.triggers.manifest
  }
}

data template_file cassandra {
  template = <<-EOT
    kubectl \
      --context ${var.k8s_context.name} \
      apply --validate=true \
            --wait=true \
            -f - <<EOF
    ---
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: cassandra
      namespace: ${helm_release.argo.namespace}
      labels:
        argo.${var.domain_root}/category: data
        argo.${var.domain_root}/organization: platform
    spec:
      project: default
      source:
        ## https://github.com/bitnami/charts/tree/master/bitnami/mariadb
        repoURL: https://charts.bitnami.com/bitnami/
        chart: cassandra
        targetRevision: 8.0.4
        helm:
          values: |
            dbUser:
              password: cassandrapw
            service:
              type: LoadBalancer
              metricsPort: 58080
            persistence:
              enabled: ${var.cassandra_persistence_enabled}
            ---
          valueFiles:
            - values.yaml
          version: v3
      destination:
        server: https://kubernetes.default.svc
        namespace: ${kubernetes_namespace.cassandra.metadata[0].name}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - Validate=true
    EOF
  EOT
}


##--------------------------------------------------------------
##  cassandra pvc

resource kubernetes_persistent_volume_claim cassandra {
  count = length(kubernetes_persistent_volume.cassandra)

  metadata {
    # name: volumeclaimtemplates-name-statefulset-name-replica-index
    name = "cassandra-cassandra-${count.index}"
    namespace = kubernetes_namespace.cassandra.metadata.0.name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.cassandra_data_size
      }
    }
    volume_name = kubernetes_persistent_volume.cassandra[count.index].metadata[count.index].name
    storage_class_name = "local-storage"
  }
  wait_until_bound = true
}

resource kubernetes_persistent_volume cassandra {
  count = length(null_resource.cassandra_path)

  metadata {
    name = "cassandra-${count.index}"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    capacity = {
      storage = var.cassandra_data_size
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key = "kubernetes.io/hostname"
            operator = "In"
            values = ["docker-desktop"]
          }
        }
      }
    }
    persistent_volume_reclaim_policy = "Recycle"
    persistent_volume_source {
      local {
        path = null_resource.cassandra_path[count.index].triggers.path
      }
    }
    storage_class_name = "local-storage"
    volume_mode = "Filesystem"
  }
}

resource null_resource cassandra_path {
  count = var.cassandra_persistence_enabled ? var.cassandra_replica_count : 0

  depends_on = [
    kubernetes_namespace.cassandra,
  ]

  triggers = {
    path = pathexpand("${var.k8s_pv_root}/cassandra-${count.index}/data")
  }

  provisioner local-exec {
    command = "mkdir -p ${self.triggers.path}"
  }

  provisioner local-exec {
    when    = destroy
    command = "rm -rf ${self.triggers.path}"
  }
}