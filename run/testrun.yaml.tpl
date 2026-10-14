# k6-operator TestRun 템플릿. run.sh 가 envsubst 로 치환한다 (치환 대상 변수는 run.sh 에 명시).
#
# 치환 변수
#   RUN_ID           TestRun 이름 = testid 태그          (예: example-20261005-143012)
#   NAMESPACE        loadtest
#   HARNESS_CONFIG   harness-config (Terraform 이 만든 계약 ConfigMap)
#   SCRIPT_CONFIGMAP run/tests/<test>/ 를 담은 ConfigMap
#   TARGET_NAME      target 태그 (테스트 이름)
#   PARALLELISM      러너 파드 수 = loadgen 노드 수
#   BASE_URL, VUS, DURATION  스크립트로 넘기는 실행 시점 입력
#   EXTRA_ENV        --env KEY=VALUE 들을 env 목록 항목(YAML)으로 만든 것. 테스트별 파라미터 (예: DELAY_MS)
#   PORT_RANGE       러너의 net.ipv4.ip_local_port_range ("10240 65535" 형식)
#
# cleanup 은 일부러 지정하지 않는다. 끝난 러너 파드가 남아 있어야 run.sh 가 로그(요약)를 거둘 수 있다.
# 정리는 run.sh 가 TestRun 을 지워서 한다.
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: ${RUN_ID}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: loglens
    loglens/test: ${TARGET_NAME}
spec:
  parallelism: ${PARALLELISM}

  script:
    configMap:
      name: ${SCRIPT_CONFIGMAP}
      file: main.js

  # k6-operator 는 이 문자열을 공백으로 나눠 셸로 실행한다. 괄호나 따옴표가 필요한 값은 env 로 넘긴다.
  # 러너마다 --tag instance_id=<n> 은 operator 가 자동으로 붙인다 (러너별 시계열이 섞이지 않는다).
  arguments: --out experimental-prometheus-rw --tag testid=${RUN_ID} --tag target=${TARGET_NAME}

  # ---------------------------------------------------------------------------
  # initializer: 스크립트를 검사(k6 inspect)하는 1회성 파드.
  # 지정하지 않으면 operator 가 runner 설정을 통째로 복사한다 → loadgen 노드 1대를 통째로 요구하게 된다.
  # 그래서 작게 따로 정의한다. toleration 이 없으므로 loadgen 이 아닌 platform 노드에 뜬다.
  # 스크립트의 options 가 __ENV 를 읽으므로 env 는 runner 와 같게 준다.
  # ---------------------------------------------------------------------------
  initializer:
    envFrom:
      - configMapRef:
          name: ${HARNESS_CONFIG}
    env:
      - name: BASE_URL
        value: "${BASE_URL}"
      - name: VUS
        value: "${VUS}"
      - name: DURATION
        value: "${DURATION}"
      # --env KEY=VALUE (run.sh 가 "      - name: ..." 들여쓰기까지 만들어 넣는다. 없으면 빈 줄)
${EXTRA_ENV}
    resources:
      requests:
        cpu: 100m
        memory: 128Mi

  # ---------------------------------------------------------------------------
  # runner: 실제 부하를 내는 파드. 노드당 1개, loadgen 노드에만.
  # ---------------------------------------------------------------------------
  runner:
    metadata:
      labels:
        loglens/role: k6-runner

    # 계약 ConfigMap (Prometheus remote-write 주소, trend stats)
    envFrom:
      - configMapRef:
          name: ${HARNESS_CONFIG}

    # 실행 시점 입력
    env:
      - name: BASE_URL
        value: "${BASE_URL}"
      - name: VUS
        value: "${VUS}"
      - name: DURATION
        value: "${DURATION}"
      # 러너 로그에 찍히는 종료 요약의 통계 항목 (arguments 로 넘기면 괄호가 셸에서 깨진다)
      - name: K6_SUMMARY_TREND_STATS
        value: "avg,min,med,max,p(95),p(99)"
      # --env KEY=VALUE (테스트별 파라미터. initializer 와 같은 값)
${EXTRA_ENV}

    nodeSelector:
      role: loadgen

    tolerations:
      - key: role
        operator: Equal
        value: loadgen
        effect: NoSchedule

    # 노드당 러너 1개 보장 (인스턴스 타입이 섞여도). conntrack 테이블이 노드 단위라서다.
    # 셀렉터가 TestRun 이름이 아니라 역할 라벨이므로, 동시에 돌린 다른 TestRun 의 러너와도 노드를 공유하지 않는다.
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                loglens/role: k6-runner

    # ip_local_port_range 는 네트워크 네임스페이스 단위 sysctl 이라 파드에서 설정해야 한다.
    # safe sysctl 이므로 kubelet allowedUnsafeSysctls 설정은 필요 없다.
    # 값은 run.sh --port-range (기본 "10240 65535"). 포트 고갈 축소 모형 측정 때만 좁힌다.
    securityContext:
      sysctls:
        - name: net.ipv4.ip_local_port_range
          value: "${PORT_RANGE}"

    # c6i.large (2 vCPU / 4 GiB) 기준. allocatable 은 대략 CPU 1930m / 메모리 3.1GiB 이고
    # DaemonSet(aws-node, kube-proxy 등)이 CPU 약 150m 를 먼저 가져간다.
    # 요청이 노드의 절반을 넘으므로 한 노드에 2개는 들어가지 않는다 (anti-affinity 와 이중 보장).
    # CPU limit 은 두지 않는다 (스로틀링이 측정값을 왜곡한다).
    resources:
      requests:
        cpu: 1500m
        memory: 2Gi
      limits:
        memory: 3Gi
