// 예제 테스트. 새 테스트는 이 디렉터리를 복사해 run/tests/<이름>/main.js 로 만든다.
//
// 규약: 호스트를 하드코딩하지 않는다. 대상과 규모는 실행 시점에 run.sh 가 넘긴다.
//   BASE_URL  --target
//   VUS       --vus        (전체 VU 수. k6-operator 가 러너들에 나눠 준다)
//   DURATION  --duration
// 엔드포인트는 BASE_URL 기준 상대 경로로만 쓴다.
// 연결 재사용(keep-alive)은 k6 기본값 그대로 둔다.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const VUS = parseInt(__ENV.VUS || '50');
const DURATION = __ENV.DURATION || '1m';

if (!BASE_URL) {
  throw new Error('BASE_URL 이 없습니다. run.sh --target 으로 넘기세요.');
}

export const options = {
  scenarios: {
    default: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    // 넘지 못하면 러너가 exit 99 로 끝나고 run.sh 도 실패(1)로 끝난다
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/`, { tags: { name: 'GET /' } });
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
  sleep(1);
}
