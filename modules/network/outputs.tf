output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR"
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "사용 중인 AZ 목록"
  value       = local.azs
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID (노드그룹용)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID (NAT, ALB용)"
  value       = module.vpc.public_subnets
}

output "nat_public_ips" {
  description = "NAT Gateway EIP. 부하 트래픽이 이 IP로 SUT에 찍히면 VPC 밖으로 나가고 있다는 뜻이다."
  value       = module.vpc.nat_public_ips
}
