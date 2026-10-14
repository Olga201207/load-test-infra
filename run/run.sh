#!/usr/bin/env bash
# =============================================================================
# loglens 분산 부하 테스트 실행기 (Git Bash / Linux / macOS)
#
#   ./run.sh --test example --target http://nginx.sut.svc.cluster.local --vus 2000 --parallelism 8
#
# Terraform 과의 접점은 loadtest/harness-config ConfigMap 하나다.
# 이 스크립트는 인프라(노드 수 등)를 건드리지 않는다. loadgen 노드는 Cluster Autoscaler 가 올린다.
# =============================================================================
set -euo pipefail

# Git Bash: kubectl.exe 에 넘기는 "/api/..." 같은 인자를 Windows 경로로 바꾸지 않게 한다.
export MSYS_NO_PATHCONV=1

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$RUN_DIR/tests"
RESULTS_DIR="$RUN_DIR/results"
TEMPLATE="$RUN_DIR/testrun.yaml.tpl"

# 계약 이름 (Terraform output loadtest_namespace / harness_config_name 과 같다)
NAMESPACE="${LOADTEST_NAMESPACE:-loadtest}"
HARNESS_CONFIG="${HARNESS_CONFIG:-harness-config}"

# 러너가 전부 뜰 때까지 기다리는 최대 시간 (loadgen 노드 0 -> N 기동 포함)
SCHEDULE_TIMEOUT_SEC="${SCHEDULE_TIMEOUT_SEC:-900}"
POLL_SEC="${POLL_SEC:-5}"
# Prometheus 질의 1건의 최대 대기 시간 (경로가 막혀 있으면 이 시간 뒤 실패로 처리한다)
PROM_TIMEOUT_SEC="${PROM_TIMEOUT_SEC:-20}"

# ---- 기본값 -----------------------------------------------------------------
TEST=""
TARGET=""
VUS=50
PARALLELISM=1
DURATION="1m"
EXTRA_ENVS=()
PORT_RANGE_ARG="10240-65535"
DEBUG=""

usage() {
  cat <<EOF
사용법: ./run.sh --test <이름> --target <URL> [옵션]

  필수
    --test <이름>          run/tests/<이름>/main.js 를 실행한다
    --target <URL>         부하 대상 (스크립트에 BASE_URL 로 전달). VPC 내부 주소를 쓴다

  선택
    --vus <n>              전체 VU 수. 러너들에 나눠 배분된다        (기본: $VUS)
    --parallelism <n>      러너 파드 수 = loadgen 노드 수             (기본: $PARALLELISM)
    --duration <기간>      스크립트에 DURATION 으로 전달 (예: 30s, 5m) (기본: $DURATION)
    --port-range <LO-HI>   러너의 출발지 포트 범위 ip_local_port_range   (기본: $PORT_RANGE_ARG)
                           포트 고갈을 작은 규모로 재현할 때만 좁힌다 (예: 60000-60999)
    --env KEY=VALUE        스크립트에 __ENV.KEY 로 전달. 여러 번 줄 수 있다 (예: --env DELAY_MS=200)
                           테스트별 파라미터는 run/tests/<이름>/main.js 머리말에 적혀 있다
    --debug               Prometheus 질의의 쿼리, 요청 경로, 원본 응답을 stderr 로 출력
    -h, --help             이 도움말

  예시
    ./run.sh --test example --target http://nginx.sut.svc.cluster.local
    ./run.sh --test example --target http://nginx.sut.svc.cluster.local --vus 2000 --parallelism 8 --duration 5m

  결과
    run/results/<RUN_ID>.txt   러너별 k6 종료 요약 + 전체 요청 수 합계
    Grafana                    Dashboards > k6 > "k6 Prometheus", testid=<RUN_ID>

  사용 가능한 테스트: $(ls -1 "$TESTS_DIR" 2>/dev/null | tr '\n' ' ')
EOF
}

die() { echo "오류: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
debug() { if [[ -n "$DEBUG" ]]; then echo "[debug] $*" >&2; fi; }

# kubectl.exe 출력의 CR 제거
k() { kubectl "$@" | tr -d '\r'; }

# ---- 인자 파싱 ----------------------------------------------------------------
need_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 에 값이 필요합니다. (./run.sh --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)        need_value "$@"; TEST="$2"; shift 2 ;;
    --target)      need_value "$@"; TARGET="$2"; shift 2 ;;
    --vus)         need_value "$@"; VUS="$2"; shift 2 ;;
    --parallelism) need_value "$@"; PARALLELISM="$2"; shift 2 ;;
    --duration)    need_value "$@"; DURATION="$2"; shift 2 ;;
    --port-range)  need_value "$@"; PORT_RANGE_ARG="$2"; shift 2 ;;
    --env)         need_value "$@"; EXTRA_ENVS+=("$2"); shift 2 ;;
    --debug)       DEBUG=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "알 수 없는 인자: $1 (./run.sh --help)" ;;
  esac
done

missing=()
[[ -n "$TEST" ]]   || missing+=("--test")
[[ -n "$TARGET" ]] || missing+=("--target")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "오류: 필수 인자가 빠졌습니다: ${missing[*]}" >&2
  echo >&2
  usage >&2
  exit 1
fi

# ---- 입력 검증 ----------------------------------------------------------------
[[ "$TEST" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] \
  || die "--test 는 소문자/숫자/하이픈, 30자 이내여야 합니다 (Kubernetes 이름에 쓰인다): $TEST"
[[ -f "$TESTS_DIR/$TEST/main.js" ]] \
  || die "run/tests/$TEST/main.js 가 없습니다. 사용 가능: $(ls -1 "$TESTS_DIR" | tr '\n' ' ')"
# 값이 YAML 의 "..." 안에 들어가므로 공백, 따옴표, 백슬래시는 받지 않는다
url_re='^https?://[^[:space:]"\\]+$'
[[ "$TARGET" =~ $url_re ]] \
  || die "--target 은 http:// 또는 https:// 로 시작하는 URL 이어야 합니다: $TARGET"
[[ "$VUS" =~ ^[1-9][0-9]*$ ]]         || die "--vus 는 양의 정수여야 합니다: $VUS"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || die "--parallelism 은 양의 정수여야 합니다: $PARALLELISM"
[[ "$DURATION" =~ ^[0-9]+(ms|s|m|h)([0-9]+(ms|s|m|h))*$ ]] \
  || die "--duration 형식이 잘못됐습니다 (예: 30s, 5m, 1h30m): $DURATION"
(( VUS >= PARALLELISM )) || die "--vus($VUS) 는 --parallelism($PARALLELISM) 이상이어야 합니다 (러너마다 VU 가 1개 이상 필요)."
# 거부하지 않고 경고만 한다. 나머지는 k6 가 일부 러너에 1개씩 더 준다. parallelism 비교 측정에서는 러너당 VU 가 같아야 공정하다.
if (( VUS % PARALLELISM != 0 )); then
  log "경고: --vus($VUS) 가 --parallelism($PARALLELISM) 으로 나누어떨어지지 않습니다. 러너당 VU 가 $((VUS / PARALLELISM)) 또는 $((VUS / PARALLELISM + 1)) 로 달라집니다." >&2
fi

[[ "$PORT_RANGE_ARG" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] \
  || die "--port-range 형식은 LO-HI 입니다 (예: 60000-60999): $PORT_RANGE_ARG"
port_lo=$((10#${BASH_REMATCH[1]})); port_hi=$((10#${BASH_REMATCH[2]}))
(( port_lo >= 1024 && port_hi <= 65535 && port_hi - port_lo + 1 >= 100 )) \
  || die "--port-range 는 1024~65535 안에서 100개 이상이어야 합니다: $PORT_RANGE_ARG"
PORT_RANGE="$port_lo $port_hi"

# --env: TestRun env 목록 항목(YAML)으로 만든다. 템플릿의 ${EXTRA_ENV} 자리에 들어간다.
# 값은 YAML "..." 안에 들어가고 쿠버네티스가 $(VAR) 를 치환하므로 따옴표, 백슬래시, $ 는 받지 않는다.
EXTRA_ENV=""
ENV_SUMMARY=""
declare -A seen_env=()
env_bad_re='["\$[:cntrl:]]'
for kv in "${EXTRA_ENVS[@]}"; do
  [[ "$kv" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] \
    || die "--env 는 KEY=VALUE 형식이어야 합니다 (KEY 는 대문자/숫자/밑줄): $kv"
  key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
  case "$key" in
    BASE_URL|VUS|DURATION) die "--env $key 는 쓸 수 없습니다. 전용 인자(--target, --vus, --duration)를 쓰세요." ;;
    K6_*) die "--env $key 는 쓸 수 없습니다. K6_* 는 harness-config 와 템플릿이 정한다." ;;
  esac
  [[ -z "${seen_env[$key]:-}" ]] || die "--env $key 가 두 번 지정됐습니다."
  seen_env[$key]=1
  if [[ "$val" =~ $env_bad_re ]]; then
    die "--env $key 값에 따옴표, 백슬래시, \$, 제어 문자는 쓸 수 없습니다: $val"
  fi
  EXTRA_ENV+="      - name: $key"$'\n'"        value: \"$val\""$'\n'
  ENV_SUMMARY+="$key=$val "
done
EXTRA_ENV="${EXTRA_ENV%$'\n'}"
ENV_SUMMARY="${ENV_SUMMARY% }"

command -v kubectl  >/dev/null || die "kubectl 이 PATH 에 없습니다."
command -v envsubst >/dev/null || die "envsubst 가 없습니다 (Git Bash 에 포함되어 있다)."

# ---- 사전 점검: 계약 ConfigMap ----------------------------------------------
RW_URL="$(k get configmap "$HARNESS_CONFIG" -n "$NAMESPACE" \
  -o jsonpath='{.data.K6_PROMETHEUS_RW_SERVER_URL}' 2>/dev/null)" \
  || die "$NAMESPACE/$HARNESS_CONFIG 를 읽을 수 없습니다. terraform apply 와 kubeconfig(aws eks update-kubeconfig)를 확인하세요."

# 러너는 노드당 1개라 parallelism 이 loadgen 최대 노드 수를 넘으면 남는 러너는 스케줄되지 않는다.
# (거르지 않으면 SCHEDULE_TIMEOUT_SEC 동안 기다린 뒤에야 실패한다.) 상한은 Terraform 이 계약 ConfigMap 에 넣어 둔다.
LOADGEN_MAX="$(k get configmap "$HARNESS_CONFIG" -n "$NAMESPACE" \
  -o jsonpath='{.data.LOGLENS_LOADGEN_MAX_SIZE}' 2>/dev/null || true)"
if [[ "$LOADGEN_MAX" =~ ^[0-9]+$ ]]; then
  (( PARALLELISM <= LOADGEN_MAX )) \
    || die "--parallelism($PARALLELISM) 이 loadgen 최대 노드 수($LOADGEN_MAX, terraform loadgen_max_size)를 넘습니다. 러너는 노드당 1개입니다."
else
  log "참고: $HARNESS_CONFIG 에 LOGLENS_LOADGEN_MAX_SIZE 가 없어 parallelism 상한을 확인하지 않습니다 (terraform apply 하면 생깁니다)." >&2
fi

# ---- 실행 식별자 --------------------------------------------------------------
RUN_ID="${TEST}-$(date +%Y%m%d-%H%M%S)"
SCRIPT_CONFIGMAP="${RUN_ID}-script"
TARGET_NAME="$TEST"
RESULT_FILE="$RESULTS_DIR/$RUN_ID.txt"
SELECTOR_RUNNER="k6_cr=$RUN_ID,runner=true"

# ---- 정리 (정상 종료, 오류, Ctrl+C 모두) --------------------------------------
LOG_PID=""
CLEANED=""
ERR_FILE=""
cleanup() {
  [[ -n "$CLEANED" ]] && return
  CLEANED=1
  [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null || true
  [[ -n "$ERR_FILE" ]] && rm -f "$ERR_FILE"
  # stderr 로 낸다. 결과 파일을 쓰는 도중 종료되면 stdout 이 결과 파일로 리다이렉트된 상태다.
  log "정리: TestRun $RUN_ID, ConfigMap $SCRIPT_CONFIGMAP 삭제" >&2
  kubectl delete testrun "$RUN_ID" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete configmap "$SCRIPT_CONFIGMAP" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
on_interrupt() {
  echo
  log "중단 요청을 받았습니다."
  exit 130   # EXIT trap 에서 cleanup
}
trap cleanup EXIT
trap on_interrupt INT TERM

# ---- 시작 ---------------------------------------------------------------------
echo "RUN_ID=$RUN_ID target=$TARGET vus=$VUS parallelism=$PARALLELISM duration=$DURATION port_range=$PORT_RANGE_ARG${ENV_SUMMARY:+ env: $ENV_SUMMARY}"
START_EPOCH=$(date +%s)
START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S %z')

# 1) 스크립트 ConfigMap: 테스트 디렉터리의 파일 전부 (main.js 가 import 하는 보조 모듈 포함)
log "스크립트 업로드: run/tests/$TEST/"
( cd "$TESTS_DIR/$TEST" && \
  kubectl create configmap "$SCRIPT_CONFIGMAP" -n "$NAMESPACE" --from-file=. \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null )

# 2) TestRun 생성 (치환 변수를 명시해 템플릿의 다른 $ 표현은 건드리지 않는다)
export RUN_ID NAMESPACE HARNESS_CONFIG SCRIPT_CONFIGMAP TARGET_NAME PARALLELISM BASE_URL="$TARGET" VUS DURATION EXTRA_ENV PORT_RANGE
envsubst '${RUN_ID} ${NAMESPACE} ${HARNESS_CONFIG} ${SCRIPT_CONFIGMAP} ${TARGET_NAME} ${PARALLELISM} ${BASE_URL} ${VUS} ${DURATION} ${EXTRA_ENV} ${PORT_RANGE}' \
  < "$TEMPLATE" | kubectl apply -f - >/dev/null
log "TestRun 생성: $NAMESPACE/$RUN_ID"

# 3) 진행 감시 + 러너 로그 tail
runner_phases() {
  # 일시적인 API 오류로 스크립트가 끝나지 않도록 실패는 빈 결과로 취급한다 (set -e)
  k get pods -n "$NAMESPACE" -l "$SELECTOR_RUNNER" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true
}
count_phase() { grep -c "^$1\$" <<<"$2" || true; }

last_stage=""
last_msg=""
STAGE=""
while true; do
  STAGE="$(k get testrun "$RUN_ID" -n "$NAMESPACE" -o jsonpath='{.status.stage}' 2>/dev/null || true)"
  if [[ "$STAGE" != "$last_stage" && -n "$STAGE" ]]; then
    log "stage: $STAGE"
    last_stage="$STAGE"
  fi

  phases="$(runner_phases)"
  total=$(grep -c . <<<"$phases" || true)
  pending=$(count_phase Pending "$phases")
  running=$(count_phase Running "$phases")
  done_n=$(( $(count_phase Succeeded "$phases") + $(count_phase Failed "$phases") ))

  # 러너 대기 상황 안내 (loadgen 노드 기동)
  if (( pending > 0 )); then
    msg="러너 $((total - pending))/$PARALLELISM 기동, $pending 개 노드 대기 중 (loadgen 노드 0대에서 시작하면 보통 2~3분)"
    [[ "$msg" != "$last_msg" ]] && { log "$msg"; last_msg="$msg"; }
    if (( $(date +%s) - START_EPOCH > SCHEDULE_TIMEOUT_SEC )); then
      log "러너가 ${SCHEDULE_TIMEOUT_SEC}초 안에 스케줄되지 않았습니다. 최근 이벤트:"
      pod="$(k get pods -n "$NAMESPACE" -l "$SELECTOR_RUNNER" --field-selector=status.phase=Pending -o name | head -n1)"
      [[ -n "$pod" ]] && kubectl describe -n "$NAMESPACE" "$pod" | tr -d '\r' | sed -n '/^Events:/,$p' | tail -n 10
      echo "힌트: --parallelism 이 loadgen 최대 노드 수(terraform loadgen_max_size)를 넘지 않는지, SPOT 용량이 있는지 확인하세요." >&2
      exit 1
    fi
  fi

  # 러너가 모두 Running 이 되면 로그 tail 시작 (한 번만)
  if [[ -z "$LOG_PID" ]] && (( total == PARALLELISM && pending == 0 && running > 0 )); then
    log "러너 로그 (Ctrl+C 로 중단하면 TestRun 과 ConfigMap 을 정리한다)"
    # 파이프 없이 kubectl 을 직접 백그라운드로 둔다. 그래야 $! 가 kubectl 이고 kill 로 확실히 멈춘다.
    kubectl logs -f -n "$NAMESPACE" -l "$SELECTOR_RUNNER" --prefix \
      --max-log-requests="$PARALLELISM" 2>/dev/null &
    LOG_PID=$!
  fi

  # 종료 판정: operator stage, 또는 러너 파드가 전부 끝남
  [[ "$STAGE" == "finished" || "$STAGE" == "error" ]] && break
  (( total == PARALLELISM && done_n == PARALLELISM )) && break

  sleep "$POLL_SEC"
done

# 로그 tail 이 남은 출력을 내보낼 시간을 조금 준다
sleep 2
[[ -n "$LOG_PID" ]] && { kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; LOG_PID=""; }
END_EPOCH=$(date +%s)
END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S %z')
# 러너가 먼저 끝나 루프를 나온 경우 operator 가 stage 를 갱신했을 수 있으므로 한 번 더 읽는다
STAGE="$(k get testrun "$RUN_ID" -n "$NAMESPACE" -o jsonpath='{.status.stage}' 2>/dev/null || echo "$STAGE")"

# 초기화 단계에서 실패한 경우 (스크립트 문법 오류 등): initializer 로그를 보여 준다
if [[ "$STAGE" == "error" && -z "$(runner_phases)" ]]; then
  log "TestRun 이 error 단계로 끝났습니다. initializer 로그:"
  kubectl logs -n "$NAMESPACE" "job/${RUN_ID}-initializer" --tail=50 2>&1 | tr -d '\r' || true
fi

# 4) 결과 수집 ------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"

# k6 종료 요약 부분만 잘라낸다. k6 v1 은 "THRESHOLDS"/"TOTAL RESULTS" 블록으로 시작한다.
# 형식이 다르면(구버전 등) 마지막 80줄을 남긴다.
extract_summary() {
  awk '
    { lines[NR] = $0 }
    !start && /(THRESHOLDS|TOTAL RESULTS)/ { start = NR }
    END {
      if (!start) start = (NR > 80 ? NR - 79 : 1)
      for (i = start; i <= NR; i++) print lines[i]
    }'
}

# Prometheus 질의: 주소는 harness-config 의 remote-write URL 에서 얻는다 (계약 외 정보에 의존하지 않는다).
# 클러스터 API 서버의 서비스 프록시를 쓰므로 port-forward 가 필요 없다.
urlencode() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v c '%%%02X' "'$c"; out+="$c" ;; esac
  done
  printf '%s' "$out"
}
PROM_PROXY=""
if [[ "$RW_URL" =~ ^https?://([^.:/]+)\.([^.:/]+)(\.svc[^:/]*)?:([0-9]+)/ ]]; then
  PROM_PROXY="/api/v1/namespaces/${BASH_REMATCH[2]}/services/${BASH_REMATCH[1]}:${BASH_REMATCH[4]}/proxy"
fi
ERR_FILE="$(mktemp)"

# 질의 1건. 성공하면 값을 출력한다 (성공했지만 결과가 비었으면 0 = 해당 시계열 없음).
# 경로 오류, timeout, Prometheus 오류 응답은 return 1 → 호출부에서 n/a 로 표시한다.
# 시점(time)은 실행 종료 시각으로 고정한다. 질의가 늦어져도 범위가 테스트 구간을 벗어나지 않는다.
prom_scalar() {
  local q="$1" path resp rc=0
  if [[ -z "$PROM_PROXY" ]]; then
    debug "remote-write URL 에서 Prometheus 서비스를 알아낼 수 없음: $RW_URL"
    return 1
  fi
  path="$PROM_PROXY/api/v1/query?query=$(urlencode "$q")&time=$END_EPOCH"
  debug "query : $q"
  debug "url   : kubectl get --raw '$path'"
  resp="$(kubectl get --raw "$path" --request-timeout="${PROM_TIMEOUT_SEC}s" 2>"$ERR_FILE" | tr -d '\r')" || rc=$?
  debug "exit  : $rc"
  debug "body  : $resp"
  if [[ -s "$ERR_FILE" ]]; then debug "stderr: $(tr -d '\r' <"$ERR_FILE")"; fi
  (( rc == 0 )) || return 1
  [[ "$resp" == *'"status":"success"'* ]] || return 1
  if [[ "$resp" == *'"result":[]'* ]]; then echo 0; return 0; fi
  sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p' <<<"$resp"
}
RANGE="$(( END_EPOCH - START_EPOCH + 60 ))s"
SEL="testid=\"$RUN_ID\""
log "Prometheus 질의 (질의당 최대 ${PROM_TIMEOUT_SEC}초)"
TOTAL_REQS="$(prom_scalar "sum(max_over_time(k6_http_reqs_total{$SEL}[$RANGE]))" || true)"
FAILED_REQS="$(prom_scalar "sum(max_over_time(k6_http_reqs_total{$SEL,expected_response=\"false\"}[$RANGE]))" || true)"
TOTAL_ITERS="$(prom_scalar "sum(max_over_time(k6_iterations_total{$SEL}[$RANGE]))" || true)"
if [[ -z "$TOTAL_REQS" || -z "$FAILED_REQS" || -z "$TOTAL_ITERS" ]]; then
  log "Prometheus 질의 일부가 실패했습니다 (n/a). --debug 로 다시 실행하면 요청 경로와 원본 응답을 볼 수 있습니다." >&2
fi

EXIT_CODE=0
{
  echo "# loglens run: $RUN_ID"
  echo
  echo "test         : $TEST"
  echo "target       : $TARGET"
  echo "vus          : $VUS"
  echo "parallelism  : $PARALLELISM"
  echo "duration     : $DURATION"
  echo "port_range   : $PORT_RANGE_ARG"
  echo "env          : ${ENV_SUMMARY:-(없음)}"
  echo "started      : $START_HUMAN"
  echo "finished     : $END_HUMAN"
  echo "stage        : ${STAGE:-unknown}"
  echo
  echo "## 전체 합계 (Prometheus, 모든 러너 합산)"
  echo "http_reqs    : ${TOTAL_REQS:-n/a}"
  echo "failed reqs  : ${FAILED_REQS:-n/a}   (expected_response=false)"
  echo "iterations   : ${TOTAL_ITERS:-n/a}"
  echo
  echo "지연 시간 백분위(p95/p99)는 러너별로만 정확하다. 러너를 합친 값은 Grafana 에서 본다:"
  echo "  Dashboards > k6 > k6 Prometheus, testid = $RUN_ID"
  echo

  # Failed(exit 99 등) 파드도 state.terminated.exitCode 가 그대로 읽힌다. 컨테이너 상태가 없는 파드는 빈 값.
  # 실패하면 스크립트를 끝내지 않고 kubectl 의 오류 메시지를 결과 파일에 남긴다.
  pods="$(k get pods -n "$NAMESPACE" -l "$SELECTOR_RUNNER" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}' \
    2>"$ERR_FILE" | sort)" \
    || echo "(러너 파드 목록을 읽지 못했습니다: $(tr -d '\r' <"$ERR_FILE"))"
  [[ -n "$pods" ]] || echo "(러너 파드가 없습니다. selector: $SELECTOR_RUNNER)"
  i=0
  while read -r pod code; do
    [[ -n "$pod" ]] || continue
    i=$((i + 1))
    echo "## runner $i ($pod) exit=${code:-?}"
    echo
    kubectl logs -n "$NAMESPACE" "$pod" 2>&1 | tr -d '\r' | extract_summary
    echo
  done <<<"$pods"
} > "$RESULT_FILE"

# 러너 종료 코드: 0 정상, 99 threshold 미달, 그 밖은 오류
codes="$(k get pods -n "$NAMESPACE" -l "$SELECTOR_RUNNER" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}')"
if grep -qv '^0$' <<<"$codes" || [[ "$STAGE" == "error" ]]; then
  EXIT_CODE=1
  grep -q '^99$' <<<"$codes" && log "일부 러너에서 threshold 를 넘지 못했습니다 (exit 99)."
fi

log "http_reqs=${TOTAL_REQS:-n/a} failed=${FAILED_REQS:-n/a}"
log "결과 저장: run/results/$RUN_ID.txt"
log "Grafana: Dashboards > k6 > k6 Prometheus, testid=$RUN_ID"

# 5) 정리는 EXIT trap 의 cleanup 이 한다
exit "$EXIT_CODE"
