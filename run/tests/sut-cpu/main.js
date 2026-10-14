// sut-cpu: loglens-sut 의 /cpu 만 호출한다. CPU 포화 지점 찾기용.
//
// 측정 모델: closed model, 생각 시간 0 (기본). VU 하나 = SUT 에 걸린 동시 요청 하나.
//   --vus 를 단계별로 올리면 처리량(http_reqs/s)이 어느 지점에서 더 늘지 않고 지연만 늘어난다. 그 지점이 CPU 포화다.
//   SUT 파드 CPU limit(기본 1코어 x 2)이 상한이다. 가상 스레드 on/off 차이는 거의 없어야 한다.
//
// 파라미터 (run.sh --env KEY=VALUE)
//   CPU_N      /cpu?n= 값 (SHA-256 연쇄 횟수)   기본 50000   범위 1 ~ 1000000
//   THINK_MS   요청 사이 대기 (ms)               기본 0       범위 0 ~ 60000
//
// CPU_N 은 먼저 VU 1개로 짧게 돌려 요청 하나의 지연이 원하는 크기(예: 5~20ms)가 되게 정한 뒤 고정한다.
// (참고: 데스크톱 1코어 기준 n=10000 이 약 0.75ms. 기본 50000 은 수 ms 수준)
//
// 예:
//   ./run.sh --test sut-cpu --target http://loglens-sut.sut.svc.cluster.local:8080 \
//     --vus 20 --parallelism 1 --duration 3m --env CPU_N=50000
//
// 이 부하는 SUT 가 있는 platform 노드의 CPU 를 채운다. 같은 노드의 Prometheus 도 영향을 받으니
// Grafana 에서 platform 노드 CPU 를 같이 본다 (loglens-sut README 6-3).

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

const CPU_N = intEnv('CPU_N', 50000, 1, 1000000);
const THINK_MS = intEnv('THINK_MS', 0, 0, 60000);

const virtualThread = new Rate('sut_virtual_thread');

export const options = {
  scenarios: {
    cpu: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      gracefulStop: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
};

const url = `${BASE_URL}/cpu?n=${CPU_N}`;
const params = { tags: { name: 'GET /cpu', endpoint: 'cpu' } };

export default function () {
  const res = http.get(url, params);
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, { endpoint: 'cpu' });
  if (ok) {
    virtualThread.add(res.json('virtual') === true, { endpoint: 'cpu' });
  }
  if (THINK_MS > 0) {
    sleep(THINK_MS / 1000);
  }
}
