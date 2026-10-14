###############################################################################
# 루트 출력
###############################################################################

output "region" {
  description = "AWS 리전"
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID. SUT는 이 VPC 안에 둔다."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID"
  value       = module.network.private_subnet_ids
}

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "kubernetes_version" {
  description = "EKS Kubernetes 버전"
  value       = module.eks.kubernetes_version
}

output "kubeconfig_command" {
  description = "kubeconfig 갱신 명령 (apply 직후 1회)"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "node_security_group_id" {
  description = "노드 보안 그룹 (조회용). SUT SG 규칙의 소스로 참조하지 말 것 - destroy 가 막힌다. SUT 는 VPC CIDR 로 허용한다."
  value       = module.eks.node_security_group_id
}

output "loadgen_asg_name" {
  description = "loadgen ASG 이름 (스케일 상태 확인용)"
  value       = module.eks.loadgen_asg_name
}

output "prometheus_remote_write_url" {
  description = "k6 remote-write 엔드포인트 (클러스터 내부)"
  value       = module.addons.prometheus_remote_write_url
}

output "grafana_port_forward_command" {
  description = "Grafana 접속 (http://localhost:3000)"
  value       = "kubectl -n ${module.addons.monitoring_namespace} port-forward svc/${module.addons.grafana_service} 3000:80"
}

output "prometheus_port_forward_command" {
  description = "Prometheus 접속 (http://localhost:9090)"
  value       = "kubectl -n ${module.addons.monitoring_namespace} port-forward svc/${module.addons.prometheus_service} 9090:9090"
}

output "loadtest_namespace" {
  description = "TestRun / 러너 파드 네임스페이스 (run/ 에서 사용)"
  value       = module.harness.namespace
}

output "harness_config_name" {
  description = "run/ 영역과의 계약 ConfigMap 이름 (TestRun runner.envFrom 에서 참조)"
  value       = module.harness.config_map_name
}

output "nat_public_ips" {
  description = "NAT EIP. SUT 로그에 이 IP가 찍히면 부하가 VPC 밖으로 나가 SNAT되고 있다는 뜻이다."
  value       = module.network.nat_public_ips
}
