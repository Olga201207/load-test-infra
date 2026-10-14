// sut-mixed: loglens-sut 의 엔드포인트를 비율대로 섞은 현실적 시나리오.
//
// 반복마다 MIX 비율에 따라 엔드포인트 하나를 골라 호출하고 THINK_MS 만큼 쉰다.
// 변수가 섞여 있으므로 비교 측정(가상 스레드, CPU 포화)에는 sut-delay / sut-cpu 를 쓴다.
// 이 시나리오는 "섞였을 때 어떻게 되나"를 보는 용도다. 엔드포인트별 지연은 Grafana 에서 name / endpoint 로 나눠 본다.
//
// 파라미터 (run.sh --env KEY=VALUE)
//   MIX         엔드포인트:가중치 목록      기본 echo:40,delay:30,cpu:20,payload:10
//               엔드포인트는 echo, delay, cpu, payload. 가중치는 0 이상의 정수 (0 이면 호출하지 않는다)
//   DELAY_MS    /delay?ms=                 기본 50     범위 0 ~ 30000
//   CPU_N       /cpu?n=                    기본 5000   범위 1 ~ 1000000
//   PAYLOAD_KB  /payload?kb=               기본 20     범위 0 ~ 10240
//   THINK_MS    요청 사이 대기 (ms)         기본 500    범위 0 ~ 60000
//
// 예:
//   ./run.sh --test sut-mixed --target http://loglens-sut.sut.svc.cluster.local:8080 \
//     --vus 300 --parallelism 2 --duration 5m --env MIX=echo:50,delay:30,cpu:20 --env THINK_MS=200

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

const DELAY_MS = intEnv('DELAY_MS', 50, 0, 30000);
const CPU_N = intEnv('CPU_N', 5000, 1, 1000000);
const PAYLOAD_KB = intEnv('PAYLOAD_KB', 20, 0, 10240);
const THINK_MS = intEnv('THINK_MS', 500, 0, 60000);

// 엔드포인트 정의. json 이 true 인 것만 응답의 virtual 필드를 읽는다.
// payload 는 본문을 버린다 (responseType: none). 큰 본문을 VU 마다 메모리에 들고 있지 않게.
const ENDPOINTS = {
  echo: { url: `${BASE_URL}/echo`, name: 'GET /echo', json: true },
  delay: { url: `${BASE_URL}/delay?ms=${DELAY_MS}`, name: 'GET /delay', json: true },
  cpu: { url: `${BASE_URL}/cpu?n=${CPU_N}`, name: 'GET /cpu', json: true },
  payload: { url: `${BASE_URL}/payload?kb=${PAYLOAD_KB}`, name: 'GET /payload', json: false, responseType: 'none' },
};

function parseMix(raw) {
  const mix = [];
  for (const part of raw.split(',')) {
    const m = /^([a-z]+):(\d+)$/.exec(part.trim());
    if (!m || !ENDPOINTS[m[1]]) {
      throw new Error(`MIX 항목이 잘못됐습니다: "${part}" (형식 endpoint:weight, endpoint 는 ${Object.keys(ENDPOINTS).join('/')})`);
    }
    if (mix.some((e) => e.endpoint === m[1])) throw new Error(`MIX 에 ${m[1]} 가 두 번 있습니다.`);
    const weight = parseInt(m[2], 10);
    if (weight > 0) mix.push({ endpoint: m[1], weight });
  }
  if (mix.length === 0) throw new Error(`MIX 의 가중치 합이 0 입니다: ${raw}`);
  return mix;
}

const MIX = parseMix(__ENV.MIX || 'echo:40,delay:30,cpu:20,payload:10');
const TOTAL_WEIGHT = MIX.reduce((s, e) => s + e.weight, 0);

const virtualThread = new Rate('sut_virtual_thread');

// 엔드포인트별 지연이 러너 종료 요약(결과 파일)에도 따로 찍히도록 서브메트릭 threshold 를 건다.
// 조건(max>=0)은 항상 참이다. 판정이 아니라 요약 출력용이다.
const perEndpoint = {};
for (const e of MIX) {
  perEndpoint[`http_req_duration{endpoint:${e.endpoint}}`] = ['max>=0'];
}

export const options = {
  scenarios: {
    mixed: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      gracefulStop: `${Math.ceil(DELAY_MS / 1000) + 30}s`,
    },
  },
  thresholds: Object.assign(
    {
      http_req_failed: ['rate<0.01'],
    },
    perEndpoint,
  ),
};

function pick() {
  let r = Math.random() * TOTAL_WEIGHT;
  for (const e of MIX) {
    r -= e.weight;
    if (r < 0) return e.endpoint;
  }
  return MIX[MIX.length - 1].endpoint;
}

export default function () {
  const endpoint = pick();
  const def = ENDPOINTS[endpoint];
  const params = { tags: { name: def.name, endpoint } };
  if (def.responseType) params.responseType = def.responseType;

  const res = http.get(def.url, params);
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, { endpoint });
  if (ok && def.json) {
    virtualThread.add(res.json('virtual') === true, { endpoint });
  }
  if (THINK_MS > 0) {
    sleep(THINK_MS / 1000);
  }
}
