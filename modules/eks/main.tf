###############################################################################
# modules/eks
#
# EKS 클러스터 + 관리형 노드그룹 2개.
#   loadgen  : k6 러너 전용. SPOT, 평소 0대. Cluster Autoscaler가 0 <-> N 으로 조절한다.
#   platform : k6-operator, Prometheus, Grafana, Cluster Autoscaler. ON_DEMAND, 상시 2대 이상.
#
# CNI는 기본 AWS VPC CNI. 파드마다 VPC 실 IP를 받으므로 러너 파드 수만큼 출발지 IP가 늘어난다.
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  # 로컬 PC(kubectl, terraform)에서 접근한다.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # terraform apply 를 실행한 IAM 주체에게 클러스터 관리자 권한을 준다.
  enable_cluster_creator_admin_permissions = true

  # destroy -> apply 사이클이 깨끗하게 돌도록 부산물이 남는 기능은 끈다.
  #  - 컨트롤 플레인 로그: destroy 도중 EKS가 로그 그룹을 다시 만들어,
  #    다음 apply가 ResourceAlreadyExistsException 으로 실패한다. audit 로그 비용도 크다.
  #  - Secret KMS 암호화: apply 할 때마다 KMS 키가 새로 생기고, destroy 후에도 최소 7일 삭제 대기로 남는다.
  #    이 클러스터에는 보호할 비밀이 사실상 없다 (Grafana admin 비밀번호 정도).
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # 클러스터 안 SUT(러너 -> 다른 노드의 SUT 파드) 통신.
  # 모듈 기본 규칙은 노드 간 1025-65535 만 열어 80/443 이 막힌다 (dial i/o timeout).
  # 8080 은 기본 ephemeral 범위에 들어가지만 SUT 포트임을 드러내려고 명시한다.
  #
  # 소스는 self(노드 SG 자신). VPC CNI 파드는 노드 SG를 그대로 달고 나가므로 이것으로 충분하다.
  # 자기 참조 규칙은 노드 SG와 함께 지워지므로 destroy 를 막지 않는다.
  # (다른 SG가 노드 SG를 참조하는 형태는 DependencyViolation 원인이므로 만들지 않는다. README 5절)
  #
  # 9090: API 서버 서비스 프록시(kubectl get --raw .../services/kps-prometheus:9090/proxy/...)는
  # 컨트롤 플레인 ENI(클러스터 SG)에서 Prometheus 파드 IP 로 직접 붙는다. 모듈 기본 규칙은
  # 클러스터 SG -> 노드를 443/10250/웹훅 포트만 열어, run.sh 의 Prometheus 질의가 timeout 난다.
  # 이 규칙도 노드 SG 안에 있고 같은 모듈의 클러스터 SG 를 참조할 뿐이라 (모듈 기본 443/10250 규칙과 같은 형태)
  # destroy 순서에 영향이 없다.
  node_security_group_additional_rules = merge(
    {
      for port in [80, 443, 8080] : "ingress_self_sut_${port}" => {
        description = "Node to node SUT ${port}"
        type        = "ingress"
        protocol    = "tcp"
        from_port   = port
        to_port     = port
        self        = true
      }
    },
    {
      ingress_cluster_prometheus = {
        description                   = "Cluster API service proxy to Prometheus"
        type                          = "ingress"
        protocol                      = "tcp"
        from_port                     = 9090
        to_port                       = 9090
        source_cluster_security_group = true
      }
    },
  )

  addons = {
    vpc-cni = {
      before_compute = true
    }
    # Cluster Autoscaler의 IAM 권한을 Pod Identity로 주기 위해 필요하다 (4단계).
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    # ------------------------------------------------------------------------
    # loadgen: 러너 파드 전용
    # ------------------------------------------------------------------------
    loadgen = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.loadgen_instance_types
      capacity_type  = "SPOT"
      subnet_ids     = var.private_subnet_ids

      # 안 쓸 때 0대. desired_size 는 Cluster Autoscaler가 움직인다.
      # 이 모듈의 노드그룹 리소스에는 lifecycle.ignore_changes = [scaling_config[0].desired_size]
      # 가 이미 들어 있어, CA가 바꾼 값을 terraform이 되돌리지 않는다.
      min_size     = 0
      desired_size = 0
      max_size     = var.loadgen_max_size

      labels = {
        role = "loadgen"
      }

      taints = {
        loadgen = {
          key    = "role"
          value  = "loadgen"
          effect = "NO_SCHEDULE"
        }
      }

      # ip_local_port_range 는 safe sysctl 이므로 kubelet allowedUnsafeSysctls 설정이 필요 없다.
    }

    # ------------------------------------------------------------------------
    # platform: operator / 관측 스택
    # ------------------------------------------------------------------------
    platform = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.platform_instance_types
      capacity_type  = "ON_DEMAND"
      subnet_ids     = var.private_subnet_ids

      min_size     = 2
      desired_size = 2
      max_size     = 4

      labels = {
        role = "platform"
      }
    }
  }

  tags = var.tags
}

###############################################################################
# Cluster Autoscaler: 0대에서 스케일업하기 위한 ASG 태그
#
# 노드가 0대면 CA는 "이 노드그룹에 노드가 생기면 어떤 label/taint를 갖는지"를
# 실제 노드에서 읽을 수 없다. 관리형 노드그룹은 CA가 eks:DescribeNodegroup 으로도
# 알아낼 수 있지만, 권한이나 버전 차이에 기대지 않도록 ASG에 node-template 태그를 직접 단다.
# (auto-discovery 태그 k8s.io/cluster-autoscaler/enabled, /<cluster> 는 EKS가 자동으로 붙인다.)
###############################################################################

locals {
  loadgen_asg_name = module.eks.eks_managed_node_groups["loadgen"].node_group_autoscaling_group_names[0]

  loadgen_node_template_tags = {
    "k8s.io/cluster-autoscaler/node-template/label/role" = "loadgen"
    "k8s.io/cluster-autoscaler/node-template/taint/role" = "loadgen:NoSchedule"
  }
}

resource "aws_autoscaling_group_tag" "loadgen_node_template" {
  for_each = local.loadgen_node_template_tags

  autoscaling_group_name = local.loadgen_asg_name

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}
