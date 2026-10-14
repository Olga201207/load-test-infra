###############################################################################
# modules/harness
#
# Terraform 영역과 run/ 영역의 유일한 접점.
#   namespace  loadtest
#   ConfigMap  loadtest/harness-config  -> 모든 TestRun 이 runner.envFrom 으로 참조만 한다.
#
# 여기에는 "인프라가 정하는 값"만 둔다.
# 테스트 대상 URL, VU 수, 실행 시간, parallelism, 스크립트 내용은 절대 넣지 않는다.
###############################################################################

locals {
  # 대시보드 19665 가 쓰는 통계: p95, p99, min, max
  trend_stats = "p(95),p(99),min,max"
}

resource "kubernetes_namespace" "loadtest" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "loglens"
    }
  }

  # 네임스페이스 삭제는 안의 리소스(TestRun, 러너 파드, run.sh 가 만든 스크립트 ConfigMap)가
  # 모두 정리될 때까지 기다린다. 러너 파드 종료 여유를 둔다.
  timeouts {
    delete = "10m"
  }
}

resource "kubernetes_config_map" "harness_config" {
  metadata {
    name      = var.config_map_name
    namespace = kubernetes_namespace.loadtest.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "loglens"
    }
  }

  # 키 이름이 곧 k6 환경변수 이름이다 (envFrom).
  # LOGLENS_* 는 k6 가 아니라 run.sh 가 읽는 값이다 (러너 환경변수로도 들어가지만 k6 는 무시한다).
  data = {
    K6_PROMETHEUS_RW_SERVER_URL  = var.prometheus_remote_write_url
    K6_PROMETHEUS_RW_TREND_STATS = local.trend_stats
    # run.sh 가 --parallelism 상한 검사에 쓴다 (러너는 노드당 1개).
    LOGLENS_LOADGEN_MAX_SIZE = tostring(var.loadgen_max_size)
  }
}
