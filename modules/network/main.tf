###############################################################################
# modules/network
#
# VPC 1개, AZ 2개.
#   public  서브넷 x2 : NAT Gateway, (필요 시) 외부 ALB
#   private 서브넷 x2 : 노드그룹. VPC CNI가 파드마다 여기서 IP를 할당하므로
#                       러너 파드가 늘어도 IP가 모자라지 않도록 /19로 넉넉히 잡는다.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  # 10.40.0.0/16 기준:
  #   private: 10.40.0.0/19, 10.40.32.0/19   (AZ당 8,190 IP)
  #   public : 10.40.128.0/24, 10.40.129.0/24
  private_subnets = [for i in range(2) : cidrsubnet(var.cidr, 3, i)]
  public_subnets  = [for i in range(2) : cidrsubnet(var.cidr, 8, 128 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # 비용 절감: NAT Gateway 1개. 노드 부팅/이미지 pull/애드온 통신용이다.
  # 부하 트래픽이 NAT를 타면 SNAT로 출발지 IP가 1개로 합쳐지므로
  # SUT는 반드시 이 VPC 안에 둔다 (README 3절).
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # SUT용 ALB를 이 VPC에 만들 때 AWS Load Balancer Controller가 서브넷을 찾도록 태그만 달아둔다.
  # (이 도구 자체는 LoadBalancer Service를 만들지 않는다.)
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}
