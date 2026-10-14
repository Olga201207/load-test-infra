// port-exhaustion: 러너 파드 수(= 출발지 IP 수)에 따라 처리량이 선형으로 느는지 재는 Before/After 측정.
//
// 측정 설계
//   변수는 --parallelism 하나. 대상, 러너당 VU 수, 실행 시간, 네트워크 경로는 고정한다.
//   noConnectionReuse: 요청마다 새 TCP 연결. 이 측정의 전제다 (재사용하면 포트가 아니라 CPU 가 병목이 된다).
//   한 러너(출발지 IP 1개)가 같은 대상 IP:port 로 지속할 수 있는 성공 연결 속도:
//     출발지 포트 수 / (TIME_WAIT 60초 x f)
//   f = 러너 쪽에 TIME_WAIT 가 남는 연결의 비율. 먼저 끊는 쪽에 TIME_WAIT 가 남는데, nginx 대상이면 연결마다 경쟁이라
//   f 는 1 이 아니다 (로컬 Docker 에서 약 0.2). 실행 중 러너에서 cat /proc/net/sockstat 의 tw 로 확인한다.
//   대상 IP:port 는 Service 의 ClusterIP:port 다 (DNAT 전 주소). nginx 레플리카 수는 이 상한을 바꾸지 않는다.
//
// thresholds 는 일부러 없다. 포트 고갈로 인한 대량 실패가 정상 결과이므로 실행을 실패로 판정하지 않는다.
//
// 실패 원인을 카운터로 나눠 센다 (러너 종료 요약 = 결과 파일에 줄 단위로 남는다)
//   err_addr_not_avail  EADDRNOTAVAIL "cannot assign requested address"  러너 포트 고갈. 측정 대상
//   err_timeout         dial / request timeout                           대상 포화 또는 conntrack 포화 (러너·대상 노드 모두 가능). 측정 무효 신호
//   err_refused         connection refused                               대상 쪽 문제. 측정 무효
//   err_reset           connection reset by peer                         대상 쪽 문제. 측정 무효
//   err_http_status     HTTP 4xx/5xx (연결은 성공)                         대상 쪽 문제. 측정 무효
//   err_other           그 밖                                             원문을 로그로 확인
//
// 로그 폭주 대책 (두 가지)
//   1) 요청에 throw: true 를 준다. k6 는 기본(throw: false)일 때 네트워크 오류마다 "Request Failed" 경고를
//      한 줄씩 찍는다 (로컬 재현: VU 10개, 20초에 1970줄). throw: true 면 경고 대신 예외를 던지므로 그걸 잡아 분류한다.
//      http_reqs / http_req_failed 같은 내장 메트릭은 예외가 나도 그대로 기록된다.
//   2) 원문은 원인별로 VU 당 첫 1건만, 러너당 앞쪽 LOG_VUS 개 VU 만 console.error 로 남긴다.
//      → 러너당 최대 LOG_VUS x 원인 수 줄. 집계는 카운터가 한다.
//
// 파라미터 (run.sh --env KEY=VALUE)
//   ERROR_SLEEP_MS  연결 오류 뒤 쉬는 시간 (ms)  기본 100  범위 0 ~ 10000
//                   EADDRNOTAVAIL 은 즉시 실패해서, 쉬지 않으면 VU 가 헛돌며 러너 CPU 를 다 쓴다
//   TIMEOUT_MS      요청 타임아웃 (ms)          기본 10000 범위 100 ~ 60000
//                   SYN 이 버려지면(conntrack 포화) VU 가 이 시간만큼 묶인다
//   LOG_VUS         원문 로그를 남길 VU 수 (러너당) 기본 3     범위 0 ~ 1000
//
// 예 (축소 모형: 출발지 포트 1000개, 러너당 VU 20 고정, parallelism 만 바꾼다. README "포트 고갈 Before/After"):
//   ./run.sh --test port-exhaustion --target http://nginx.sut.svc.cluster.local --port-range 60000-60999 --duration 3m --parallelism 1 --vus 20
//   ./run.sh --test port-exhaustion --target http://nginx.sut.svc.cluster.local --port-range 60000-60999 --duration 3m --parallelism 2 --vus 40
//   ./run.sh --test port-exhaustion --target http://nginx.sut.svc.cluster.local --port-range 60000-60999 --duration 3m --parallelism 4 --vus 80
//   ./run.sh --test port-exhaustion --target http://nginx.sut.svc.cluster.local --port-range 60000-60999 --duration 3m --parallelism 8 --vus 160
//   ./compare.sh port-exhaustion
// duration 은 TIME_WAIT(60초) 주기를 여러 번 담도록 3분 이상으로 한다.

import http from 'k6/http';
import { sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
const VUS = parseInt(__ENV.VUS || '50');
const DURATION = __ENV.DURATION || '1m';

if (!BASE_URL) {
  throw new Error('BASE_URL 이 없습니다. run.sh --target 으로 넘기세요.');
}

function intEnv(name, def, min, max) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return def;
  if (!/^\d+$/.test(raw)) throw new Error(`${name} 는 0 이상의 정수여야 합니다: ${raw}`);
  const v = parseInt(raw, 10);
  if (v < min || v > max) throw new Error(`${name} 는 ${min} ~ ${max} 이어야 합니다: ${v}`);
  return v;
}

const ERROR_SLEEP_MS = intEnv('ERROR_SLEEP_MS', 100, 0, 10000);
const TIMEOUT_MS = intEnv('TIMEOUT_MS', 10000, 100, 60000);
const LOG_VUS = intEnv('LOG_VUS', 3, 0, 1000);

const counters = {
  addr_not_avail: new Counter('err_addr_not_avail'),
  timeout: new Counter('err_timeout'),
  refused: new Counter('err_refused'),
  reset: new Counter('err_reset'),
  http_status: new Counter('err_http_status'),
  other: new Counter('err_other'),
};

export const options = {
  noConnectionReuse: true,
  // 본문은 읽지 않는다. 러너 CPU/메모리를 포트 이외의 일에 쓰지 않게.
  discardResponseBodies: true,
  scenarios: {
    port: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
};

// throw: true 로 던져진 네트워크 오류를 Go 오류 원문으로 나눈다 (Linux 기준 문구, 로컬 Docker 에서 확인).
//   EADDRNOTAVAIL : "dial tcp ...: connect: cannot assign requested address"  (throw: false 였다면 error_code 1213)
//   refused       : "dial tcp ...: connect: connection refused"               (1212)
//   timeout       : "request timeout" (1050), "dial ...: i/o timeout" (1211)
//   reset         : "connection reset by peer"                                (1220)
function classifyError(message) {
  const msg = message.toLowerCase();
  if (msg.includes('cannot assign requested address')) return 'addr_not_avail';
  if (msg.includes('connection refused')) return 'refused';
  if (msg.includes('timeout') || msg.includes('deadline exceeded')) return 'timeout';
  if (msg.includes('reset by peer')) return 'reset';
  return 'other';
}

// VU 마다 JS 런타임이 따로라서 아래 상태는 VU 별이다.
const logged = {};
let primed = false;

const url = `${BASE_URL}/`;
const params = { tags: { name: 'GET /' }, timeout: `${TIMEOUT_MS}ms`, throw: true };

export default function () {
  // 오류가 한 번도 없던 원인도 요약에 0 으로 찍히게 한다 (결과 비교 때 "없음"과 "0"을 구분하지 않아도 되게).
  if (!primed) {
    for (const c of Object.values(counters)) c.add(0);
    primed = true;
  }

  let cause = null;
  let detail = '';
  try {
    const res = http.get(url, params);
    // throw: true 는 HTTP 4xx/5xx 에는 던지지 않는다. 연결은 됐으니 포트 문제가 아니다.
    if (res.status >= 400) {
      cause = 'http_status';
      detail = `status=${res.status}`;
    }
  } catch (e) {
    detail = String(e);
    cause = classifyError(detail);
  }
  if (cause === null) return;

  counters[cause].add(1);

  if (!logged[cause] && exec.vu.idInInstance <= LOG_VUS) {
    logged[cause] = true;
    console.error(`[port-exhaustion] first ${cause} on vu=${exec.vu.idInInstance}: ${detail}`);
  }

  if (cause !== 'http_status' && ERROR_SLEEP_MS > 0) {
    sleep(ERROR_SLEEP_MS / 1000);
  }
}
