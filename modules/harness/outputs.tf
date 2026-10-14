output "namespace" {
  description = "loadtest 네임스페이스 이름"
  value       = kubernetes_namespace.loadtest.metadata[0].name
}

output "config_map_name" {
  description = "harness-config ConfigMap 이름"
  value       = kubernetes_config_map.harness_config.metadata[0].name
}
