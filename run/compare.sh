#!/usr/bin/env bash
# =============================================================================
# 같은 테스트의 결과 파일(run/results/<test>-YYYYMMDD-HHMMSS.txt)들을 한 줄씩 표로 비교한다.
#
#   ./compare.sh port-exhaustion
#
# 열
#   par / vus / ports   --parallelism, --vus, --port-range (결과 파일 머리말)
#   http_reqs           전체 요청 수 (Prometheus 합계, 없으면 러너 요약 합)
#   ok_rps              성공 요청/초. 러너별 (http_reqs 속도 x 성공 비율)의 합 (러너 요약)
#   ok_rps/par          러너 1개당 ok_rps. 선형으로 늘면 이 값이 일정하다
#   addr_err            err_addr_not_avail 합 (EADDRNOTAVAIL, 러너 포트 고갈)
#   timeout             err_timeout 합 (대상 또는 conntrack 포화. 측정 무효 신호)
#   other_err           err_refused + err_reset + err_http_status + err_other 합 (대상 쪽 문제)
#   p95_ok_ms           성공 요청 p95 의 러너 중 최댓값 (ms). 백분위는 합칠 수 없어 최악값을 보인다
#   stage               TestRun 최종 단계
# err_* 열은 port-exhaustion 처럼 그 카운터를 쓰는 테스트에서만 값이 있다 (없으면 -).
#
# 파싱 대상
#   머리말 "key : value" 줄은 run.sh 가 쓰는 형식이라 안정적이다.
#   러너 요약은 k6 종료 요약 텍스트다 (k6 v1.6 형식으로 확인). k6 버전이 바뀌면 형식이 달라질 수 있다.
# =============================================================================
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$RUN_DIR/results"

if [[ $# -ne 1 || "$1" == -h || "$1" == --help ]]; then
  echo "사용법: ./compare.sh <테스트 이름>    (예: ./compare.sh port-exhaustion)" >&2
  exit 1
fi
TEST="$1"

# <test>-YYYYMMDD-HHMMSS.txt 만 (다른 테스트의 접두어가 겹쳐도 섞이지 않게). 이름순 = 시간순.
files=()
for f in "$RESULTS_DIR/$TEST"-*.txt; do
  [[ -f "$f" && "$(basename "$f")" =~ ^${TEST}-[0-9]{8}-[0-9]{6}\.txt$ ]] && files+=("$f")
done
if [[ ${#files[@]} -eq 0 ]]; then
  echo "run/results/ 에 $TEST 결과 파일이 없습니다." >&2
  exit 1
fi

for f in "${files[@]}"; do
  tr -d '\r' < "$f" | awk -v run_id="$(basename "$f" .txt)" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    # k6 시간 표기 -> ms (예: 517.52µs, 1.2ms, 3s, 1m2.5s)
    function to_ms(v,   m, s) {
      if (v ~ /µs$/ || v ~ /us$/) { sub(/(µs|us)$/, "", v); return v / 1000 }
      if (v ~ /ns$/)              { sub(/ns$/, "", v);      return v / 1000000 }
      if (v ~ /ms$/)              { sub(/ms$/, "", v);      return v + 0 }
      if (v ~ /^[0-9.]+m[0-9.]+s$/) { split(v, p, "m"); m = p[1]; s = p[2]; sub(/s$/, "", s); return m * 60000 + s * 1000 }
      if (v ~ /s$/)               { sub(/s$/, "", v);       return v * 1000 }
      return -1
    }
    # 머리말 (run.sh 형식): "key<공백> : value"
    !in_runner && /^[a-z_ ]+ +: / {
      key = trim(substr($0, 1, index($0, ":") - 1)); val = trim(substr($0, index($0, ":") + 1))
      if (key == "parallelism") par = val
      else if (key == "vus") vus = val
      else if (key == "port_range") ports = val
      else if (key == "stage") stage = val
      else if (key == "http_reqs" && val ~ /^[0-9]+$/) h_reqs = val
      else if (key == "failed reqs") { split(val, a, " "); if (a[1] ~ /^[0-9]+$/) h_failed = a[1] }
      next
    }
    /^## runner / { in_runner = 1; runners++; next }
    # 러너 요약 (k6 형식): "name......: value ..."
    in_runner && /^ *http_reqs\.+:/ { split($0, a, ":"); split(trim(a[2]), b, /[ \t]+/); r_reqs = b[1]; r_rate = b[2]; sub(/\/s$/, "", r_rate); s_reqs += r_reqs; have_rate = 1; cur_rate = r_rate; cur_reqs = r_reqs; next }
    in_runner && /^ *http_req_failed\.+:/ {
      # "50.56% 1970 out of 3896"
      split($0, a, ":"); split(trim(a[2]), b, /[ \t]+/); cur_failed = b[2]; s_failed += b[2]; next
    }
    in_runner && /^ *\{ expected_response:true \}/ {
      if (match($0, /p\(95\)=[^ ]+/)) { v = to_ms(substr($0, RSTART + 6, RLENGTH - 6)); if (v > p95) p95 = v; have_p95 = 1 }
      next
    }
    in_runner && /^ *err_[a-z_]+\.+:/ {
      split($0, a, ":"); name = trim(a[1]); gsub(/\.+$/, "", name); split(trim(a[2]), b, /[ \t]+/)
      have_err = 1
      if (name == "err_addr_not_avail") addr += b[1]
      else if (name == "err_timeout") tmo += b[1]
      else other += b[1]
      next
    }
    # 러너 하나의 요약이 끝나는 지점은 따로 없으므로, 러너별 성공 속도는 http_reqs 와 http_req_failed 가 둘 다 나온 뒤 누적한다.
    in_runner && cur_reqs != "" && cur_failed != "" {
      if (cur_reqs > 0) ok_rps += cur_rate * (cur_reqs - cur_failed) / cur_reqs
      cur_reqs = ""; cur_failed = ""
    }
    END {
      if (in_runner && cur_reqs != "" && cur_failed != "" && cur_reqs > 0) ok_rps += cur_rate * (cur_reqs - cur_failed) / cur_reqs
      reqs = (h_reqs != "") ? h_reqs : (runners ? s_reqs : "-")
      printf "%-34s %4s %6s %-12s %10s %9s %10s %9s %8s %9s %9s  %s\n", run_id, (par ? par : "-"), (vus ? vus : "-"), (ports ? ports : "-"),
        reqs,
        (have_rate ? sprintf("%.1f", ok_rps) : "-"),
        (have_rate && par > 0 ? sprintf("%.1f", ok_rps / par) : "-"),
        (have_err ? addr : "-"), (have_err ? tmo : "-"), (have_err ? other : "-"),
        (have_p95 ? sprintf("%.2f", p95) : "-"),
        (stage ? stage : "-")
    }'
done | {
  printf "%-34s %4s %6s %-12s %10s %9s %10s %9s %8s %9s %9s  %s\n" \
    RUN_ID par vus ports http_reqs ok_rps ok_rps/par addr_err timeout other_err p95_ok_ms stage
  cat
}
