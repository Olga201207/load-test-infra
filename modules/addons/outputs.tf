output "monitoring_namespace" {
  description = "Prometheus / Grafana 네임스페이스"
  value       = local.monitoring_namespace
}

output "prometheus_service" {
  description = "Prometheus Service 이름 (ClusterIP, 9090)"
  value       = local.prometheus_service
}

output "prometheus_url" {
  description = "클러스터 내부 Prometheus 주소"
  value       = local.prometheus_url
}

output "prometheus_remote_write_url" {
  description = "k6 remote-write 엔드포인트. harness-config 의 K6_PROMETHEUS_RW_SERVER_URL 로 쓰인다."
  value       = "${local.prometheus_url}/api/v1/write"

  # 릴리스가 설치된 뒤에만 의미가 있는 주소다.
  depends_on = [helm_release.kube_prometheus_stack]
}

output "grafana_service" {
  description = "Grafana Service 이름 (ClusterIP, 80)"
  value       = "grafana"
}
