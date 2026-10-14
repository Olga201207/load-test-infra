variable "name" {
  description = "EKS 클러스터 이름"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes 버전. 표준 지원이 끝난 버전은 확장 지원 요금(컨트롤 플레인 시간당 약 6배)이 붙는다."
  type        = string
}

variable "endpoint_public_access_cidrs" {
  description = "EKS API 퍼블릭 엔드포인트에 접근 가능한 CIDR"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "노드그룹과 컨트롤 플레인 ENI를 둘 프라이빗 서브넷"
  type        = list(string)
}

variable "loadgen_instance_types" {
  description = "loadgen(SPOT) 인스턴스 타입. 러너 파드 requests 가 노드 크기에 맞춰져 있으므로 vCPU/메모리가 같은 타입끼리만 섞는다."
  type        = list(string)
}

variable "loadgen_max_size" {
  description = "loadgen 노드 최대 수 = 동시에 띄울 수 있는 러너 파드 최대 수 (노드당 1개)"
  type        = number
}

variable "platform_instance_types" {
  description = "platform(ON_DEMAND) 인스턴스 타입"
  type        = list(string)
}

variable "tags" {
  description = "추가 태그"
  type        = map(string)
  default     = {}
}
