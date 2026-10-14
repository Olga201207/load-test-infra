###############################################################################
# modules/addons
#
# helm_release 3개:
#   k6-operator            (k6-operator-system)
#   kube-prometheus-stack  (monitoring)   Prometheus + Grafana
#   cluster-autoscaler     (kube-system)  loadgen 노드그룹 0 <-> N
#
# destroy 가 깨지지 않도록 지키는 규칙:
#   - Service 는 전부 ClusterIP. LoadBalancer 를 만들지 않는다 (남은 ELB가 VPC 삭제를 막는다).
#   - PVC 를 만드는 설정은 전부 끈다 (helm uninstall 은 PVC를 지우지 않는다).
#     EBS CSI 드라이버도 설치하지 않으므로, 실수로 PVC가 생겨도 EBS 볼륨은 만들어지지 않는다.
#   - 이 모듈은 루트에서 depends_on = [module.eks] 로 호출된다.
#     따라서 apply 시 노드그룹이 뜬 뒤에 설치되고, destroy 시 노드그룹/클러스터보다 먼저 uninstall 된다.
###############################################################################

locals {
  platform_node_selector = { role = "platform" }

  # 차트 버전은 고정한다. apply 할 때마다 같은 결과가 나와야 destroy/apply 사이클이 예측 가능하다.
  chart_versions = {
    k6_operator           = "4.6.0"
    kube_prometheus_stack = "91.8.2"
    cluster_autoscaler    = "9.59.0"
  }

  monitoring_namespace = "monitoring"
  prometheus_fullname  = "kps"

  # kube-prometheus-stack 의 Prometheus Service 이름은 "<fullnameOverride>-prometheus" 다.
  prometheus_service = "${local.prometheus_fullname}-prometheus"
  prometheus_url     = "http://${local.prometheus_service}.${local.monitoring_namespace}.svc.cluster.local:9090"

  cluster_autoscaler_sa = "cluster-autoscaler"
}

###############################################################################
# k6-operator
###############################################################################

resource "helm_release" "k6_operator" {
  name             = "k6-operator"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "k6-operator"
  version          = local.chart_versions.k6_operator
  namespace        = "k6-operator-system"
  create_namespace = true

  # 설치 실패 시 반쯤 설치된 리소스를 남기지 않는다.
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode({
    # 네임스페이스는 helm(create_namespace)이 만든다. 차트가 또 만들면 충돌한다.
    namespace    = { create = false }
    installCRDs  = true
    nodeSelector = local.platform_node_selector
  })]
}

###############################################################################
# kube-prometheus-stack (Prometheus + Grafana)
###############################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = local.chart_versions.kube_prometheus_stack
  namespace        = local.monitoring_namespace
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [templatefile("${path.module}/values/kube-prometheus-stack.yaml.tpl", {
    fullname      = local.prometheus_fullname
    node_selector = yamlencode(local.platform_node_selector)
  })]
}

###############################################################################
# cluster-autoscaler (IAM: EKS Pod Identity)
###############################################################################

module "cluster_autoscaler_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.cluster_name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [var.cluster_name]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = "kube-system"
      service_account = local.cluster_autoscaler_sa
    }
  }

  tags = var.tags
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = local.chart_versions.cluster_autoscaler
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.region

    # EKS 관리형 노드그룹의 ASG에는 k8s.io/cluster-autoscaler/enabled, /<cluster> 태그가 자동으로 붙는다.
    autoDiscovery = { clusterName = var.cluster_name }

    # CA 마이너 버전은 클러스터 Kubernetes 마이너 버전에 맞춘다.
    image = { tag = "v${var.kubernetes_version}.0" }

    rbac = {
      serviceAccount = {
        create = true
        name   = local.cluster_autoscaler_sa
      }
    }

    nodeSelector = local.platform_node_selector

    extraArgs = {
      # loadgen 노드가 SPOT 타입 여러 개일 때 남는 자원이 가장 적은 쪽을 고른다.
      expander = "least-waste"
      # 러너가 끝난 loadgen 노드를 비우는 대기 시간 (기본값 그대로 10분).
      "scale-down-unneeded-time" = "10m"
      # skip-nodes-with-local-storage 는 기본값(true)을 유지한다.
      # Prometheus(emptyDir)가 떠 있는 platform 노드를 CA가 내리지 않게 해서 테스트 중 메트릭 유실을 막는다.
    }
  })]

  depends_on = [module.cluster_autoscaler_pod_identity]
}
