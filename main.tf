###############################################################################
# loglens-infra — 루트 모듈
#
# 이 루트가 소유하는 것은 "고정 설비"뿐이다.
#   VPC, EKS, 노드그룹, k6-operator, Prometheus, Grafana, harness-config ConfigMap
#
# 테스트 스크립트 / 대상 URL / VU 수 / 실행 시간 / parallelism 은
# 절대 이 트리에 들어오지 않는다. 그것들은 run/ 에서 실행 시점에 주입된다.
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  # 상태 파일은 우선 local backend.
  # S3 backend 전환 방법은 README.md "상태 파일(backend)" 절 참고.
}

provider "aws" {
  region = var.region

  # 자격증명은 코드에 넣지 않는다.
  # AWS_PROFILE / AWS_ACCESS_KEY_ID 등 표준 자격증명 체인을 사용한다.

  default_tags {
    tags = local.tags
  }
}

# kubernetes / helm provider 인증은 exec 플러그인(aws eks get-token)으로 한다.
# data "aws_eks_cluster_auth" 토큰은 15분이면 만료돼 긴 apply/destroy 중간에 끊기므로 쓰지 않는다.
# Windows에서도 PATH의 aws.exe 를 찾는다. --region 을 명시해 로컬 aws 기본 리전 설정에 의존하지 않는다.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

# helm provider 3.x: kubernetes / exec 가 블록이 아니라 객체 속성이다.
provider "helm" {
  # 로컬 PC의 helm 설정(repositories.yaml, 캐시)에 영향받지 않도록 전용 경로를 쓴다.
  # (로컬 repositories.yaml 에 캐시가 깨진 repo 가 있으면 "no cached repo found" 로 plan 이 실패한다.)
  repository_config_path = "${path.root}/.terraform/helm/repositories.yaml"
  repository_cache       = "${path.root}/.terraform/helm/cache"

  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

locals {
  name = var.project_name

  tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

module "network" {
  source = "./modules/network"

  name = local.name
  cidr = var.vpc_cidr
  tags = local.tags
}

module "eks" {
  source = "./modules/eks"

  name                         = local.name
  kubernetes_version           = var.kubernetes_version
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  loadgen_instance_types  = var.loadgen_instance_types
  loadgen_max_size        = var.loadgen_max_size
  platform_instance_types = var.platform_instance_types

  tags = local.tags
}

module "addons" {
  source = "./modules/addons"

  cluster_name       = module.eks.cluster_name
  kubernetes_version = module.eks.kubernetes_version
  region             = var.region
  tags               = local.tags

  # provider 설정이 참조하는 것은 클러스터 엔드포인트뿐이라, 이것만으로는 노드그룹과의 순서가 보장되지 않는다.
  # 모듈 전체 의존성을 걸어 둔다.
  #   apply  : 노드그룹이 뜬 뒤 helm 설치 (wait=true 가 파드 Ready 를 기다릴 수 있도록)
  #   destroy: helm uninstall 이 노드그룹/클러스터 삭제보다 먼저 끝난다
  depends_on = [module.eks]
}

module "harness" {
  source = "./modules/harness"

  prometheus_remote_write_url = module.addons.prometheus_remote_write_url
  loadgen_max_size            = var.loadgen_max_size

  # apply  : Prometheus(와 k6-operator)가 뜬 뒤에 만든다
  # destroy: addons 보다 먼저 지운다. 네임스페이스를 지울 때 k6-operator 가 아직 살아 있어야
  #          남은 TestRun 이 정상적으로 정리된다.
  depends_on = [module.addons]
}
