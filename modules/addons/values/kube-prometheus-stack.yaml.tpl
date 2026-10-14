# kube-prometheus-stack values
#
# 원칙: ClusterIP 만, PVC 없음, platform 노드에만.
# (예외: node-exporter DaemonSet 은 모든 노드에 뜬다. loadgen 노드의 CPU/네트워크/conntrack 을 보려면 필요하다.)

fullnameOverride: ${fullname}

# --- 이 도구에 필요 없는 구성요소 -------------------------------------------
alertmanager:
  enabled: false

# 기본 알림 규칙은 끈다 (Alertmanager 가 없다).
defaultRules:
  create: false

# EKS 에서는 컨트롤 플레인 구성요소를 스크레이프할 수 없다.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false

# --- Prometheus ------------------------------------------------------------
prometheus:
  service:
    type: ClusterIP
  thanosServiceExternal:
    enabled: false          # 켜면 LoadBalancer 가 생긴다.
  prometheusSpec:
    # k6 --out experimental-prometheus-rw 를 받기 위한 remote-write receiver.
    # 이 필드가 Prometheus 에 --web.enable-remote-write-receiver 인자를 추가한다.
    enableRemoteWriteReceiver: true

    # 스토리지: emptyDir (storageSpec 비움). PVC/EBS 를 만들지 않는다. destroy 하면 데이터도 사라진다.
    storageSpec: {}
    # emptyDir 은 노드 루트 디스크(20GiB)를 쓰므로 크기로 상한을 건다.
    retention: 7d
    retentionSize: 6GB

    nodeSelector:
      ${indent(6, node_selector)}

    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        memory: 4Gi

# --- Grafana ---------------------------------------------------------------
grafana:
  fullnameOverride: grafana

  # adminPassword 를 비우면 차트가 무작위 비밀번호를 만들어 Secret "grafana" 에 저장한다.
  # (kube-prometheus-stack 기본값은 잘 알려진 "prom-operator" 다.)
  adminPassword: ""

  service:
    type: ClusterIP
  persistence:
    enabled: false
  nodeSelector:
    ${indent(4, node_selector)}

  # k6 공식 대시보드(ID 19665, "k6 Prometheus")를 기동 시 grafana.com 에서 받아 프로비저닝한다.
  # 원본의 데이터소스 자리표시자 $${DS_PROMETHEUS} 를 kube-prometheus-stack 기본 데이터소스 uid 로 바꾼다.
  dashboardProviders:
    k6-dashboardprovider.yaml:
      apiVersion: 1
      providers:
        - name: k6
          orgId: 1
          folder: k6
          type: file
          disableDeletion: true
          editable: true
          options:
            path: /var/lib/grafana/dashboards/k6
  dashboards:
    k6:
      k6-prometheus:
        gnetId: 19665
        revision: 3
        datasource:
          - name: DS_PROMETHEUS
            value: prometheus

# --- Operator / exporters --------------------------------------------------
prometheusOperator:
  nodeSelector:
    ${indent(4, node_selector)}
  admissionWebhooks:
    patch:
      nodeSelector:
        ${indent(8, node_selector)}

kube-state-metrics:
  nodeSelector:
    ${indent(4, node_selector)}
