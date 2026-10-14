output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "클러스터 CA (base64)"
  value       = module.eks.cluster_certificate_authority_data
}

output "kubernetes_version" {
  description = "클러스터 Kubernetes 버전"
  value       = module.eks.cluster_version
}

output "node_security_group_id" {
  description = "노드 공유 보안 그룹 (조회용). 다른 SG 규칙에서 참조하면 destroy 시 삭제가 막힌다."
  value       = module.eks.node_security_group_id
}

output "loadgen_asg_name" {
  description = "loadgen 노드그룹의 ASG 이름"
  value       = local.loadgen_asg_name
}
