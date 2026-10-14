###############################################################################
# 루트 변수 — 인프라 형상만 다룬다.
# 테스트 대상, VU 수, 스크립트 등 "실행 시점 입력"은 여기에 추가하지 않는다.
###############################################################################

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 접두사로 쓰이는 프로젝트 이름"
  type        = string
  default     = "loglens"
}

variable "vpc_cidr" {
  description = "VPC CIDR (/16). private /19 x2, public /24 x2 로 나뉜다."
  type        = string
  default     = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes 버전. 표준 지원 기간이 지난 버전은 확장 지원 요금이 붙으므로 재구축 시 확인한다."
  type        = string
  default     = "1.35"
}

variable "endpoint_public_access_cidrs" {
  description = "EKS API 엔드포인트에 접근할 수 있는 CIDR. 기본값은 전체 공개. 내 공인 IP/32 로 좁히는 것을 강력히 권장 (README 5절)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "loadgen_instance_types" {
  description = "loadgen(SPOT) 인스턴스 타입. vCPU/메모리가 같은 타입끼리만 섞는다 (러너 requests 가 노드 크기 기준)."
  type        = list(string)
  default     = ["c6i.large"]
}

variable "loadgen_max_size" {
  description = "loadgen 노드 최대 수 = parallelism 상한 (노드당 러너 1개)"
  type        = number
  default     = 10
}

variable "platform_instance_types" {
  description = "platform(ON_DEMAND) 인스턴스 타입"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "tags" {
  description = "모든 AWS 리소스에 추가로 붙일 태그"
  type        = map(string)
  default     = {}
}
