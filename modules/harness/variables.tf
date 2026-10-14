variable "prometheus_remote_write_url" {
  description = "k6 가 메트릭을 보낼 Prometheus remote-write 엔드포인트"
  type        = string
}

variable "loadgen_max_size" {
  description = "loadgen 노드그룹 최대 노드 수 = --parallelism 상한. run.sh 가 계약 ConfigMap 에서 읽는다."
  type        = number
}

variable "namespace" {
  description = "TestRun 과 러너 파드가 뜨는 네임스페이스"
  type        = string
  default     = "loadtest"
}

variable "config_map_name" {
  description = "run/ 영역과의 계약 ConfigMap 이름"
  type        = string
  default     = "harness-config"
}
