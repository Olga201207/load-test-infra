// sut-delay: loglens-sut 의 /delay 만 호출한다. 가상 스레드 on/off 비교용.
//
// 측정 모델: closed model, 생각 시간 0 (기본).
//   VU 하나 = SUT 에 걸린 동시 요청 하나. 따라서 "SUT 동시 요청 수 = --vus" 로 읽을 수 있다.
//   플랫폼 스레드(기본)는 톰캣 스레드 200 x 파드 수 를 넘는 지점부터 대기열이 생겨 지연이 DELAY_MS 위로 뜬다.
//   가상 스레드는 그 지점이 사라진다. --vus 를 단계별로 바꿔 가며 두 설정을 같은 값으로 비교한다.
//
// 파라미터 (run.sh --env KEY=VALUE)
//   DELAY_MS   /delay?ms= 값            기본 100   범위 0 ~ 30000
//   THINK_MS   요청 사이 대기 (ms)       기본 0     범위 0 ~ 60000
//
// 예:
//   ./run.sh --test sut-delay --target http://loglens-sut.sut.svc.cluster.local:8080 \
//     --vus 800 --parallelism 2 --duration 3m --env DELAY_MS=100
//
// 결과 요약의 sut_virtual_thread 는 응답을 처리한 SUT 스레드가 가상 스레드였던 비율이다 (0% 또는 100% 여야 한다).
// SUT 설정 롤아웃이 끝나기 전에 측정을 시작하면 이 값이 중간으로 나온다.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

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

const DELAY_MS = intEnv('DELAY_MS', 100, 0, 30000);
const THINK_MS = intEnv('THINK_MS', 0, 0, 60000);

const virtualThread = new Rate('sut_virtual_thread');

export const options = {
  scenarios: {
    delay: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      // 종료 시점에 걸려 있는 요청이 끝날 때까지 기다린다 (지연이 길어도 중간에 끊지 않게).
      gracefulStop: `${Math.ceil(DELAY_MS / 1000) + 30}s`,
    },
  },
  thresholds: {
    // 넘지 못하면 러너가 exit 99 로 끝나고 run.sh 도 실패(1)로 끝난다
    http_req_failed: ['rate<0.01'],
  },
};

const url = `${BASE_URL}/delay?ms=${DELAY_MS}`;
const params = { tags: { name: 'GET /delay', endpoint: 'delay' } };

export default function () {
  const res = http.get(url, params);
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, { endpoint: 'delay' });
  if (ok) {
    virtualThread.add(res.json('virtual') === true, { endpoint: 'delay' });
  }
  if (THINK_MS > 0) {
    sleep(THINK_MS / 1000);
  }
}
