variable "cluster_name" {
  description = "EKS 클러스터 이름 (Cluster Autoscaler auto-discovery, Pod Identity 연결 대상)"
  type        = string
}

variable "kubernetes_version" {
  description = "클러스터 Kubernetes 마이너 버전 (예: 1.35). Cluster Autoscaler 이미지 태그를 여기에 맞춘다."
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
}

variable "tags" {
  description = "추가 태그 (IAM 리소스)"
  type        = map(string)
  default     = {}
}
