# loglens-infra

AWS EKS(ap-northeast-2) 위에서 k6-operator로 k6 러너 파드를 여러 개 띄워
분산 부하 테스트를 수행하는 **재사용 도구**. 고정 설비는 Terraform으로, 테스트는 `run/` 으로 다룬다.

이 도구는 세 가지를 지키도록 설계되어 있다.

1. `terraform apply` 한 번 이후에는 Terraform 코드를 다시 건드리지 않는다.
2. 새 테스트 대상을 추가할 때 할 일은 `run/tests/<이름>/` 디렉터리 하나 만드는 것뿐이다.
3. 안 쓸 때 `destroy`, 다시 쓸 때 `apply` 하는 사이클이 깨끗하게 돈다.

> 무엇이 검증됐고 무엇이 안 됐는지, 측정상 한계와 운영 주의는 **[LIMITATIONS.md](LIMITATIONS.md)** 에 정리했다. 처음 쓰기 전에 읽는다.

---

## 1. 설계 원칙: 고정 설비와 실행 시점 입력을 나눈다

```
┌──────────────── Terraform 소유 ────────────────┐      ┌──── Terraform 밖 (run/) ────┐
│ VPC · EKS · 노드그룹(loadgen/platform)           │      │ k6 스크립트                   │
│ k6-operator · Cluster Autoscaler                │      │ 대상 URL (BASE_URL)           │
│ kube-prometheus-stack (Prometheus, Grafana)     │      │ VU 수 · 실행 시간              │
│   ConfigMap loadtest/harness-config ────────────┼─envFrom─▶ parallelism               │
│     K6_PROMETHEUS_RW_SERVER_URL                 │      │                              │
│     K6_PROMETHEUS_RW_TREND_STATS                │      │                              │
└─────────────────────────────────────────────────┘      └──────────────────────────────┘
```

- 두 영역이 만나는 곳은 `harness-config` ConfigMap 하나뿐이다.
- Prometheus 주소가 바뀌면 Terraform만 고친다. 테스트 대상이 바뀌면 Terraform은 건드리지 않는다.
- 스크립트 내용, 대상 URL, VU 수는 Terraform 변수나 리소스에 절대 넣지 않는다.

### 계약 ConfigMap: `loadtest/harness-config`

`modules/harness` 가 만든다. 모든 TestRun은 `runner.envFrom` 으로 이것을 참조만 한다. 키 이름이 곧 k6 환경변수 이름이다.

| 키 | 값 | 의미 |
|---|---|---|
| `K6_PROMETHEUS_RW_SERVER_URL` | `http://kps-prometheus.monitoring.svc.cluster.local:9090/api/v1/write` | k6가 메트릭을 보낼 곳 (클러스터 내부) |
| `K6_PROMETHEUS_RW_TREND_STATS` | `p(95),p(99),min,max` | Trend 메트릭을 이 통계로 내보낸다. 대시보드 19665가 이 네 가지를 쓴다 |

```bat
kubectl -n loadtest get configmap harness-config -o yaml
```

이름은 `terraform output loadtest_namespace` / `harness_config_name` 으로도 확인할 수 있다.

---

## 2. 러너를 여러 파드로 나누는 이유

머신 한 대에서 부하를 걸면 출발지 IP가 하나뿐이다. 그러면 임시 포트(기본 약 28,000개)와
`TIME_WAIT`(60초)에 묶여 신규 연결 속도에 상한이 생긴다. 이 환경은 러너를 여러 파드로 나눠 그 상한을 넓힌다.
AWS VPC CNI가 파드마다 VPC의 실제 IP를 주므로, 파드 수만큼 출발지 IP와 포트 공간이 늘어난다.
(k6는 기본적으로 연결을 재사용하므로 평소에는 포트가 병목이 되는 일이 드물다.)

이 목적 때문에 러너 파드에는 다음 제약이 항상 걸린다.

| 제약 | 이유 | 반영 위치 |
|---|---|---|
| `securityContext.sysctls`: `net.ipv4.ip_local_port_range = "10240 65535"` | 네트워크 네임스페이스 단위 sysctl이라 노드에서 설정해도 파드에는 적용되지 않는다 | `run/testrun.yaml.tpl` |
| 노드당 러너 파드 1개 (requests를 노드 용량에 가깝게 설정) | conntrack 테이블을 노드 단위로 공유한다 | `run/testrun.yaml.tpl` |
| `nodeSelector: role=loadgen` + toleration `role=loadgen:NoSchedule` | 러너는 loadgen 노드에만 뜬다 | `modules/eks`, `run/testrun.yaml.tpl` |
| SUT는 같은 VPC 안 | 아래 NAT 경고 참고 | 운영 규약 |

`net.ipv4.ip_local_port_range` 는 Kubernetes의 *safe sysctl* 이다. 그래서 kubelet `allowedUnsafeSysctls` 설정은 **하지 않는다**.
`net.ipv4.tcp_tw_reuse` 같은 unsafe sysctl이 필요해지면 그때 loadgen 노드그룹에 추가한다.

---

## 3. ⚠️ 경고: NAT Gateway를 거치면 출발지 IP가 다시 하나로 합쳐진다

러너 파드는 프라이빗 서브넷에 있다. VPC 밖(인터넷, 다른 VPC의 퍼블릭 엔드포인트 등)으로 나가는
트래픽은 NAT Gateway를 지나면서 **모든 파드 IP가 NAT의 EIP 하나로 SNAT된다**.

- 출발지 IP가 다시 하나가 된다. 파드를 나눈 의미가 없어진다.
- NAT Gateway 자체에도 목적지(IP:port)당 동시 연결 약 55,000개 제한이 있다.
- 부하 트래픽 전량에 NAT 데이터 처리 요금(GB당)이 붙는다.

**부하 대상(SUT)은 같은 VPC 안에 둔다는 것이 이 도구의 전제다.** VPC Peering이나 Transit Gateway처럼
SNAT 없이 사설 IP로 닿는 곳도 괜찮다. `--target` 에는 내부 DNS, 내부 ALB, 사설 IP를 넣는다.

---

## 4. 디렉터리 구조

```
loglens-infra/
├── main.tf                    # provider 설정, 모듈 조립
├── variables.tf               # 인프라 형상 변수만
├── outputs.tf
├── terraform.tfvars.example
├── README.md
├── LIMITATIONS.md             # 검증 범위, 측정 한계, 운영 주의
├── modules/
│   ├── network/               # VPC, 2 AZ, public/private 서브넷, single NAT
│   ├── eks/                   # EKS, 노드그룹 loadgen(SPOT, 0~10) / platform(ON_DEMAND m6i.large, 2~4)
│   ├── addons/                # helm: k6-operator, kube-prometheus-stack, cluster-autoscaler
│   └── harness/               # namespace loadtest, ConfigMap harness-config
└── run/                       # ← Terraform이 참조하지 않는 영역
    ├── testrun.yaml.tpl       # k6-operator TestRun 템플릿 (envsubst)
    ├── run.sh                 # 실행 진입점
    ├── compare.sh             # 같은 테스트의 결과 파일들을 한 줄씩 표로 비교
    ├── results/               # 실행 결과 요약 (<RUN_ID>.txt)
    └── tests/
        ├── example/main.js    # 테스트 하나 = 디렉터리 하나
        ├── sut-delay/main.js  # loglens-sut /delay 만 (가상 스레드 비교)
        ├── sut-cpu/main.js    # loglens-sut /cpu 만 (CPU 포화)
        ├── sut-mixed/main.js  # loglens-sut 엔드포인트 혼합
        └── port-exhaustion/main.js  # 러너 수 vs 처리량 (출발지 포트 고갈 Before/After)
```

---

## 5. 구축 (apply)

사전 준비: `terraform >= 1.6`, `aws` CLI v2(PATH에 있어야 한다. Terraform이 `aws eks get-token` 으로 클러스터에 인증한다), `kubectl`.
테스트 실행에는 추가로 Git Bash가 필요하다(`envsubst` 포함).

Terraform 명령은 CMD에서 그대로 실행하면 된다.

```bat
:: 자격증명은 코드에 넣지 않는다. 표준 자격증명 체인을 쓴다.
set AWS_PROFILE=<your-profile>

:: 최초 1회
copy terraform.tfvars.example terraform.tfvars
:: → 아래 "EKS API 접근 제한"을 보고 endpoint_public_access_cidrs 를 내 IP 로 바꾼다

terraform init
terraform plan -out tfplan
terraform apply tfplan

:: kubeconfig 연결 (출력된 명령을 그대로 실행)
terraform output -raw kubeconfig_command
aws eks update-kubeconfig --region ap-northeast-2 --name loglens
kubectl get nodes -L role
```

apply가 끝나면 platform 노드 2대만 떠 있다. loadgen 노드는 0대이고, 테스트가 시작되면
Cluster Autoscaler가 필요한 만큼 올린다. apply는 helm 설치까지 포함해 보통 20분 안팎 걸린다.

### ⚠️ EKS API 접근 제한: 내 공인 IP로 좁힌다

기본값 `endpoint_public_access_cidrs = ["0.0.0.0/0"]` 은 EKS API 엔드포인트를 인터넷 전체에 연다.
인증은 여전히 필요하지만 노출 면을 줄이기 위해 **내 공인 IP/32로 좁히는 것을 강력히 권장한다.**

```bat
:: 1) 내 공인 IP 확인 (Windows 10 이상에는 curl 이 기본으로 있다)
curl -s https://checkip.amazonaws.com
```

```hcl
# 2) terraform.tfvars 에 /32 를 붙여 넣는다
endpoint_public_access_cidrs = ["203.0.113.45/32"]
```

공인 IP가 바뀌면(가정용 회선, 카페, VPN 등) `kubectl` 과 `terraform` 이 클러스터에 붙지 못하고 타임아웃 난다.
그때는 이 값만 새 IP로 고치고 `terraform apply` 한다. 이 경우 바뀌는 것은 EKS 설정 하나뿐이다.
**destroy 직전에 IP가 바뀌었다면 반드시 이 값부터 고친다** (8절 참고).

### Kubernetes 버전

`kubernetes_version`(기본 `1.35`, 표준 지원 2027-03-27까지)이 표준 지원 기간을 벗어나면 컨트롤 플레인 요금이
시간당 $0.10에서 $0.60으로 오른다. 오랜만에 다시 apply할 때는 아래 명령으로 확인하고 `terraform.tfvars` 에서 버전을 올린다.
destroy/apply 사이클이라 업그레이드 절차 없이 새 버전으로 만들어진다. Cluster Autoscaler 이미지도 같은 마이너 버전으로 자동으로 맞춰진다.

```bat
aws eks describe-cluster-versions --region ap-northeast-2 --query "clusterVersions[].[clusterVersion,versionStatus]" --output table
```

### SUT 보안 그룹

러너 파드는 노드 보안 그룹을 달고 나간다. SUT 위치에 따라 두 경우로 나뉜다.

**SUT가 클러스터 안(파드)일 때** — 추가 작업이 필요 없다. `modules/eks` 가 노드 SG에
자기 자신을 소스로 하는 인바운드 규칙을 **TCP 80, 443, 8080** 으로 열어 둔다.
EKS 모듈 기본 규칙은 노드 간 1025-65535 만 허용하므로, 이 규칙이 없으면 다른 노드의 80/443 SUT에
`dial i/o timeout` 이 난다. 이 외의 1024 이하 포트가 필요하면 `modules/eks/main.tf` 의
`node_security_group_additional_rules` 포트 목록에 추가한다. 자기 참조 규칙은 노드 SG와 함께 삭제되므로 destroy 를 막지 않는다.

같은 자리에 **클러스터 SG → 노드 TCP 9090** 규칙도 있다. `run.sh` 가 결과 합계를 API 서버 서비스 프록시로 Prometheus 에 질의하는데,
이 요청은 컨트롤 플레인에서 Prometheus 파드 IP 로 직접 들어온다. 이 규칙이 없으면 결과 파일의 합계가 `n/a` 로 남는다.

**SUT가 클러스터 밖(같은 VPC의 EC2, ALB 등)일 때** — SUT 보안 그룹의 인바운드는 **VPC CIDR(`10.40.0.0/16`)로 허용한다.**
노드 SG(`terraform output node_security_group_id`)를 소스로 참조하는 규칙은 만들지 않는다.
다른 SG가 노드 SG를 참조하고 있으면 destroy 때 노드 SG를 지우지 못해 `DependencyViolation` 으로 멈춘다.

---

## 6. 테스트 실행

`run.sh` 는 **Git Bash** 에서 실행한다. kubectl은 Windows 쪽 것을 그대로 쓰며, 5절에서 연결한 kubeconfig를 공유한다.

```bash
cd /c/Project/load-test-module/loglens-infra/run
./run.sh --help
./run.sh --test example --target http://nginx.sut.svc.cluster.local
./run.sh --test example --target http://nginx.sut.svc.cluster.local --vus 2000 --parallelism 8 --duration 5m
```

### 인자

| 인자 | 필수 | 기본값 | 설명 |
|---|---|---|---|
| `--test <이름>` | ✔ | | `run/tests/<이름>/main.js` 를 실행한다. 소문자/숫자/하이픈, 30자 이내 |
| `--target <URL>` | ✔ | | 부하 대상. 스크립트에 `BASE_URL` 로 전달된다. **VPC 내부 주소**를 쓴다 (3절) |
| `--vus <n>` | | 50 | **전체** VU 수. k6-operator가 러너들에 나눠 준다 (2000 / 8 러너 = 러너당 250) |
| `--parallelism <n>` | | 1 | 러너 파드 수 = loadgen 노드 수. `loadgen_max_size`(기본 10) 이하로 |
| `--duration <기간>` | | 1m | 스크립트에 `DURATION` 으로 전달된다 (예: `30s`, `5m`, `1h30m`) |
| `--port-range <LO-HI>` | | 10240-65535 | 러너의 `net.ipv4.ip_local_port_range`. 포트 고갈을 작은 규모로 재현할 때만 좁힌다 (예: `60000-60999`). 1024~65535, 100개 이상. 결과 파일 `port_range` 줄에 기록된다 |
| `--env KEY=VALUE` | | | 스크립트에 `__ENV.KEY` 로 전달된다. 여러 번 줄 수 있다. 테스트별 파라미터용 (예: `--env DELAY_MS=200`). 결과 파일 `env` 줄에 기록된다. KEY 는 대문자/숫자/밑줄, `BASE_URL`·`VUS`·`DURATION`·`K6_*` 는 금지. 값에 따옴표·백슬래시·`$` 금지 |
| `--debug` | | | 결과 수집 단계의 Prometheus 질의마다 쿼리, `kubectl get --raw` 요청 경로, 종료 코드, 원본 응답, kubectl stderr 를 stderr 로 출력한다. 출력된 `kubectl get --raw '...'` 를 그대로 붙여 넣어 다시 확인할 수 있다 |
| `-h`, `--help` | | | 사용법 |

필수 인자가 빠지면 무엇이 빠졌는지 출력하고 종료한다.

### 실행 흐름

```
$ ./run.sh --test example --target http://nginx.sut.svc.cluster.local --vus 200 --parallelism 2
RUN_ID=example-20261005-143012 target=http://nginx.sut.svc.cluster.local vus=200 parallelism=2 duration=1m
[14:30:12] 스크립트 업로드: run/tests/example/
[14:30:13] TestRun 생성: loadtest/example-20261005-143012
[14:30:13] stage: initialization
[14:30:20] 러너 0/2 기동, 2 개 노드 대기 중 (loadgen 노드 0대에서 시작하면 보통 2~3분)
[14:32:41] stage: started
[14:32:45] 러너 로그 (Ctrl+C 로 중단하면 TestRun 과 ConfigMap 을 정리한다)
[pod/example-20261005-143012-1-xxxxx/k6] ...
[14:33:52] http_reqs=11873 failed=0
[14:33:52] 결과 저장: run/results/example-20261005-143012.txt
[14:33:52] Grafana: Dashboards > k6 > k6 Prometheus, testid=example-20261005-143012
[14:33:52] 정리: TestRun example-20261005-143012, ConfigMap example-20261005-143012-script 삭제
```

1. `RUN_ID = <테스트명>-<YYYYMMDD-HHMMSS>` 를 만든다. TestRun 이름이자 Grafana의 `testid` 다.
2. `run/tests/<테스트명>/` 의 **파일 전부**를 ConfigMap `<RUN_ID>-script` 로 올린다 (보조 모듈 import 가능).
3. `testrun.yaml.tpl` 을 envsubst로 치환해 TestRun을 만든다.
4. 러너가 모두 Running이 되면 로그를 tail한다. 러너가 15분 안에 스케줄되지 않으면 원인(이벤트)을 보여 주고 종료한다.
5. 끝나면 결과를 `run/results/<RUN_ID>.txt` 로 저장한다.
6. TestRun과 스크립트 ConfigMap을 지운다. **Ctrl+C, 오류 종료 때도 똑같이 정리한다** (trap).

종료 코드는 0(정상) 또는 1(러너 실패, threshold 미달(k6 exit 99), 스케줄 실패)이다. CI에서도 쓸 수 있다.

### loadgen 노드 스케일업: 첫 실행은 2~3분 기다린다

loadgen 노드그룹은 평소 0대다. 러너 파드가 Pending 상태가 되면 Cluster Autoscaler가
SPOT 노드를 띄운다. **노드 부팅부터 Ready까지 보통 2~3분 걸린다.** 그동안 러너 파드는 Pending이며 이는 정상이다.
테스트가 끝나고 노드가 비면 Cluster Autoscaler가 일정 시간 뒤(기본 10분) 다시 0대로 줄인다.
10분 안에 다시 실행하면 이미 떠 있는 노드를 써서 바로 시작한다.

러너는 노드당 1개다(requests CPU 1500m / 메모리 2Gi + hostname 기준 podAntiAffinity).
initializer 파드는 작게 따로 정의되어 platform 노드에서 돈다. loadgen 노드를 차지하지 않는다.

### 결과 파일: `run/results/<RUN_ID>.txt`

```
# loglens run: example-20261005-143012
test / target / vus / parallelism / duration / port_range / env / started / finished / stage

## 전체 합계 (Prometheus, 모든 러너 합산)
http_reqs    : 11873
failed reqs  : 0   (expected_response=false)
iterations   : 11873

## runner 1 (<pod>) exit=0
  █ THRESHOLDS ...
  █ TOTAL RESULTS ...      ← 이 러너의 k6 종료 요약 그대로 (avg,min,med,max,p(95),p(99))
## runner 2 (<pod>) exit=0
  ...
```

- **요청 수/실패 수/반복 수 합계**는 Prometheus 카운터를 러너 전체로 더한 값이라 정확하다.
- **p95/p99는 러너별 값만 정확하다.** 백분위는 러너끼리 더하거나 평균 낼 수 없다. 전체 지연 분포는 Grafana에서 본다.
- 파일은 보조 기록이다. 주 경로는 Grafana이고, destroy하면 Prometheus 데이터는 사라지므로 남겨 둘 숫자는 이 파일에 남는다.

동작 원리: TestRun에 `cleanup` 을 지정하지 않으므로 끝난 러너 파드는 Completed 상태로 남는다.
`run.sh` 가 그 파드들의 로그에서 k6 종료 요약을 잘라 저장한 뒤 TestRun을 지운다.
Prometheus 질의는 harness-config의 remote-write 주소로 찾아 API 서버 서비스 프록시로 보낸다(port-forward 불필요).

### 새 테스트 대상 추가: 디렉터리 하나

예를 들어 주문 API를 테스트한다면:

```bash
mkdir run/tests/order-api
cp run/tests/example/main.js run/tests/order-api/main.js
# main.js 의 요청 부분만 바꾼다
./run.sh --test order-api --target http://order-api.internal:8080 --vus 500 --parallelism 4 --duration 10m
```

```js
// run/tests/order-api/main.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;            // --target
const VUS = parseInt(__ENV.VUS || '50');    // --vus
const DURATION = __ENV.DURATION || '1m';    // --duration

export const options = {
  scenarios: { default: { executor: 'constant-vus', vus: VUS, duration: DURATION } },
  thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<500'] },
};

export default function () {
  // 상대 경로만. 호스트 하드코딩 금지.
  const list = http.get(`${BASE_URL}/api/orders?limit=20`, { tags: { name: 'GET /api/orders' } });
  check(list, { 'list 200': (r) => r.status === 200 });

  const created = http.post(`${BASE_URL}/api/orders`, JSON.stringify({ sku: 'A-1', qty: 1 }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'POST /api/orders' } });
  check(created, { 'create 201': (r) => r.status === 201 });

  sleep(1);
}
```

규약은 하나다. **호스트를 하드코딩하지 않는다.** `BASE_URL`, `VUS`, `DURATION` 을 `__ENV` 에서 읽는다.
테스트별 파라미터(지연 시간, 본문 크기 등)도 `__ENV` 에서 기본값과 함께 읽고, 실행할 때 `--env KEY=VALUE` 로 바꾼다.
받는 파라미터는 `main.js` 머리말에 적어 둔다.
URL에 ID가 들어가는 엔드포인트는 `tags: { name: ... }` 로 묶어 두면 Grafana에서 엔드포인트별로 깔끔하게 보인다.
같은 디렉터리에 `lib.js` 같은 보조 파일을 두고 `import ... from './lib.js'` 해도 된다 (디렉터리 전체가 올라간다, 합계 1MiB 이내).
Terraform은 건드리지 않는다.

입력 검사 중 측정을 망치는 실수 두 가지:
- `--parallelism` 이 loadgen 최대 노드 수(`loadgen_max_size`)를 넘으면 시작 전에 거부한다. 상한은 harness-config 의 `LOGLENS_LOADGEN_MAX_SIZE` 에서 읽는다
  (이 키가 없는 클러스터에서는 확인을 건너뛰고 안내만 한다. 넘으면 기존처럼 러너가 스케줄되지 않아 15분 뒤 실패한다).
- `--vus` 가 `--parallelism` 으로 나누어떨어지지 않으면 경고한다 (러너당 VU 가 달라진다). 실행은 계속한다.

### 결과 비교: `compare.sh`

```bash
./compare.sh port-exhaustion
```

`run/results/<테스트>-YYYYMMDD-HHMMSS.txt` 를 시간순으로 읽어 한 줄씩 출력한다.

```
RUN_ID                              par    vus ports         http_reqs    ok_rps ok_rps/par  addr_err  timeout other_err p95_ok_ms  stage
port-exhaustion-20261010-120000       1     10 60000-60499        5254      76.2       76.2      2960        0         0      0.54  finished
port-exhaustion-20261010-121000       2     20 60000-60499       11194     176.1       88.0      5900        0         0      0.74  finished
```
(로컬 Docker 축소 모형 실행 결과로 만든 예시)

- `ok_rps` 는 러너별 (요청 속도 x 성공 비율)의 합, `ok_rps/par` 는 러너 1개당 값이다. 선형이면 `ok_rps/par` 가 일정하다.
- `addr_err` / `timeout` / `other_err` 는 `err_*` 카운터를 쓰는 테스트(port-exhaustion)에서만 값이 있다.
- `p95_ok_ms` 는 성공 요청 p95 의 러너 중 최댓값이다 (백분위는 합칠 수 없다).
- 머리말은 run.sh 형식이라 안정적이고, 러너 요약은 k6 종료 요약 텍스트(k6 v1.6 확인)를 읽는다. k6 버전이 바뀌면 열이 `-` 로 나올 수 있다.

### 무엇을 바꾸고 무엇을 안 바꾸나

| 상황 | 바꾸는 것 | 안 바꾸는 것 |
|---|---|---|
| 대상 URL 변경 | `--target` | Terraform 전부 |
| 부하 크기(VU, 파드 수, 시간) 변경 | `--vus`, `--parallelism`, `--duration` | Terraform 전부 |
| 테스트 파라미터 변경 (지연 ms, 본문 kb 등) | `--env KEY=VALUE` | 스크립트, Terraform 전부 |
| 새 시나리오 추가 | `run/tests/<new>/main.js` | Terraform 전부 |
| Prometheus 주소나 메트릭 설정 변경 | `modules/harness` | 테스트 스크립트, run.sh |
| 노드 타입이나 최대 노드 수 변경 | `terraform.tfvars` | 테스트 스크립트, run.sh |

### 연습용 부하 대상(SUT) 띄우기

가장 간단한 방법은 클러스터 안에 nginx를 띄우는 것이다. ClusterIP Service로 노출하므로 트래픽이 VPC 밖으로 나가지 않고(NAT 미경유)
ELB도 생기지 않는다. 파드는 taint가 없는 platform 노드에 뜬다. loadgen 노드에는 taint가 있어 뜨지 않는다. 아래 명령은 Git Bash와 CMD 어디서든 그대로 동작한다.

```bash
kubectl create namespace sut
kubectl -n sut create deployment nginx --image=nginx:1.27 --replicas=2
kubectl -n sut expose deployment nginx --port=80
kubectl -n sut rollout status deployment/nginx

./run.sh --test example --target http://nginx.sut.svc.cluster.local --vus 100 --parallelism 2 --duration 1m

kubectl delete namespace sut      # 다 쓰면 지운다
```

nginx가 Prometheus와 같은 platform 노드에서 돌기 때문에 큰 부하를 걸면 관측 스택도 같이 영향을 받는다. 동작 확인용으로만 쓴다.

### 포트 고갈 Before/After: `port-exhaustion`

러너 수(= 출발지 IP 수)만 1 → 2 → 4 → 8 로 바꿔 성공 처리량이 선형으로 느는지 잰다. `noConnectionReuse` 로 요청마다 새 연결을 맺는다.

```bash
T=http://nginx.sut.svc.cluster.local
# 축소 모형 (권장): 출발지 포트를 1000개로 좁혀 포트가 유일한 병목이 되게 한다. 러너당 VU 20 고정.
./run.sh --test port-exhaustion --target $T --port-range 60000-60999 --duration 3m --parallelism 1 --vus 20
./run.sh --test port-exhaustion --target $T --port-range 60000-60999 --duration 3m --parallelism 2 --vus 40
./run.sh --test port-exhaustion --target $T --port-range 60000-60999 --duration 3m --parallelism 4 --vus 80
./run.sh --test port-exhaustion --target $T --port-range 60000-60999 --duration 3m --parallelism 8 --vus 160
./compare.sh port-exhaustion
```

- 러너 하나가 같은 대상(IP:port)에 지속할 수 있는 성공 연결 속도 ≈ `포트 수 / (60초 x f)`.
  60초는 TIME_WAIT 유지 시간, `f` 는 러너(클라이언트) 쪽에 TIME_WAIT 가 남는 연결의 비율이다.
  누가 먼저 끊느냐는 연결마다 경쟁이라 `f` 는 1 이 아니다 (로컬 Docker + nginx 에서 약 0.2).
- 기본 포트 범위(55296개)에서는 이 상한이 러너당 수천 conn/s 가 되어, 포트보다 노드 conntrack(연결당 약 120초 유지)과 대상이 먼저 찬다.
  그래서 포트 범위를 좁힌 축소 모형으로 잰다. 메커니즘(출발지 IP 당 포트 상한)은 같고, 다른 병목이 끼지 않는다.
- 유효한 측정의 조건: 모든 실행에서 `addr_err > 0` (포트 상한에 실제로 닿음), `timeout = 0`, `other_err = 0`.
  `timeout` 은 대상 포화일 수도, 러너·대상 노드의 conntrack 포화일 수도 있다 (SYN 이 버려짐).
- 실패 원인 카운터(`err_*`)와 로그 대책은 `tests/port-exhaustion/main.js` 머리말에 있다.

### 샘플 SUT(loglens-sut) 테스트: `sut-delay` / `sut-cpu` / `sut-mixed`

부하 특성을 조절할 수 있는 샘플 앱 `loglens-sut`(별도 디렉터리, 배포는 그 README 6절)용 테스트 3개.
비교 측정에서 변수가 섞이지 않도록 용도별로 나눴다.

| 테스트 | 호출 | 용도 | 파라미터 (`--env`, 기본값) |
|---|---|---|---|
| `sut-delay` | `/delay` 만 | 가상 스레드 on/off 비교, 스레드 풀 포화 | `DELAY_MS=100`, `THINK_MS=0` |
| `sut-cpu` | `/cpu` 만 | CPU 포화 지점 | `CPU_N=50000`, `THINK_MS=0` |
| `sut-mixed` | 비율대로 섞음 | 현실적 시나리오 | `MIX=echo:40,delay:30,cpu:20,payload:10`, `DELAY_MS=50`, `CPU_N=5000`, `PAYLOAD_KB=20`, `THINK_MS=500` |

```bash
T=http://loglens-sut.sut.svc.cluster.local:8080

# 가상 스레드 비교: SUT 설정만 바꾸고 같은 명령을 두 번 (loglens-sut README 6-2)
./run.sh --test sut-delay --target $T --vus 800 --parallelism 2 --duration 3m --env DELAY_MS=100

# CPU 포화: --vus 를 단계별로 올린다
./run.sh --test sut-cpu --target $T --vus 4  --parallelism 1 --duration 2m
./run.sh --test sut-cpu --target $T --vus 16 --parallelism 1 --duration 2m

# 섞은 시나리오
./run.sh --test sut-mixed --target $T --vus 300 --parallelism 2 --duration 5m --env MIX=echo:50,delay:30,cpu:20 --env THINK_MS=200
```

- `sut-delay`, `sut-cpu` 는 생각 시간 0 의 closed model 이다. **VU 수 = SUT 에 걸린 동시 요청 수**로 읽는다.
- 요청마다 `name`(예: `GET /delay`)과 `endpoint`(예: `delay`) 태그를 단다. Grafana k6 대시보드의 요청별 표는 `name` 으로 나뉘고,
  상단 ad hoc 필터에 `endpoint` 를 걸면 엔드포인트 하나만 볼 수 있다.
- 러너 요약(결과 파일)의 `sut_virtual_thread` 는 응답을 처리한 SUT 스레드가 가상 스레드였던 비율이다. **0% 또는 100% 여야 한다.**
  중간 값이면 SUT 설정 롤아웃 도중에 측정한 것이다. 이 값이 결과 파일에 남으므로 그 실행이 어느 설정이었는지의 기록도 된다.
- `sut-mixed` 의 러너 요약에는 엔드포인트별 지연(`{ endpoint:delay }` 등)이 따로 찍힌다.

### Git Bash 주의사항

- `run.sh`, `testrun.yaml.tpl` 은 LF 줄바꿈이어야 한다. `.gitattributes` 가 git 체크아웃 시 LF로 고정한다.
  편집기에서 CRLF로 저장했다면 `$'\r': command not found` 가 난다. 편집기 줄바꿈을 LF로 바꾸거나 `sed -i 's/\r$//' run.sh` 로 고친다.
- `run.sh` 는 `MSYS_NO_PATHCONV=1` 을 켜서 kubectl.exe 인자가 Windows 경로로 바뀌지 않게 한다. 직접 손볼 필요는 없다.

---

## 7. Grafana / Prometheus 접속

외부 노출(LoadBalancer)은 하지 않는다. 둘 다 ClusterIP이며 `kubectl port-forward` 로 접속한다.
port-forward는 창을 띄워 둔 동안만 유지되므로 각각 별도 CMD 창에서 실행한다.

```bat
:: Grafana → http://localhost:3000  (사용자: admin)
kubectl -n monitoring port-forward svc/grafana 3000:80
```

```bat
:: Prometheus → http://localhost:9090
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
```

```bat
:: Grafana admin 비밀번호 (apply 할 때마다 무작위로 새로 생성된다)
kubectl -n monitoring get secret grafana -o go-template="{{index .data \"admin-password\" | base64decode}}"
```

같은 명령은 `terraform output grafana_port_forward_command` / `prometheus_port_forward_command` 로도 볼 수 있다.

### k6 대시보드

k6 공식 대시보드(ID `19665`, "k6 Prometheus")는 Grafana가 기동할 때 grafana.com에서 자동으로 받아
**Dashboards → k6** 폴더에 넣어 둔다. destroy/apply 후에도 import할 필요가 없다.
대시보드 상단의 `testid` 변수로 실행을 고른다. `run.sh` 가 매 실행마다 `testid=<RUN_ID>` 와
`target=<테스트명>` 태그를 붙인다.

다른 Grafana에 수동으로 넣어야 할 때는 **Dashboards → New → Import** 에서 ID `19665` 를 입력하고
데이터 소스로 Prometheus를 고른다.

---

## 8. 정리 (destroy)

### 이 도구가 만드는 것 중 destroy를 막을 수 있는 것은 없도록 해 두었다

| 흔한 실패 원인 | 이 도구의 처리 |
|---|---|
| Helm이 만든 LoadBalancer Service의 ELB가 남아 VPC 삭제 실패 | Service는 전부 ClusterIP라 ELB가 생기지 않는다 |
| Helm uninstall이 PVC를 남겨 EBS 볼륨이 남음 | PVC를 만드는 설정은 전부 끔. EBS CSI 드라이버도 설치하지 않아 PVC가 생겨도 EBS가 만들어지지 않는다 |
| 컨트롤 플레인 로그 그룹이 destroy 중 다시 생겨 다음 apply 실패 | 컨트롤 플레인 로그를 끔 |
| KMS 키가 삭제 대기로 쌓임 | Secret KMS 암호화를 끔 |
| 노드그룹이 먼저 지워져 helm uninstall이 꼬임 | addons 모듈이 `depends_on = [module.eks]` 라 helm uninstall이 노드그룹/클러스터 삭제보다 먼저 끝난다 |

### 절차

```bat
:: 0) 공인 IP가 바뀌었다면 endpoint_public_access_cidrs 부터 고치고 apply (5절)
::    클러스터 API에 못 붙으면 helm uninstall 단계에서 destroy 가 멈춘다

:: 1) 실행 중인 테스트 정리
kubectl delete testruns --all -n loadtest

:: 2) 내가 직접 만든 것 정리 (아래 "직접 만든 것" 참고)

:: 3) destroy
terraform destroy
```

### 직접 만든 것은 destroy 전에 지운다

Terraform은 자기가 만든 것만 지운다. 아래는 **이 도구 밖에서 만든 것** 중 destroy를 막는 것들이다.

- **VPC 안에 둔 SUT**(EC2, ALB, RDS, ECS 등): 서브넷/VPC 삭제를 막는다. SUT를 먼저 내리거나 다른 VPC에 두고 Peering으로 연결한다.
- **노드 SG를 참조하는 SG 규칙**: 노드 SG 삭제를 막는다 (5절 "SUT 보안 그룹").
- **클러스터에 직접 만든 `type: LoadBalancer` Service나 Ingress**: EKS가 ELB를 만든다. `kubectl delete` 로 먼저 지운다.

```bat
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

### destroy가 VPC/서브넷/SG에서 멈췄을 때

VPC 안에 무엇이 남아 있는지 ENI로 찾는다. `<vpc-id>` 는 `terraform output vpc_id` 로 확인한다.

```bat
aws ec2 describe-network-interfaces --region ap-northeast-2 --filters Name=vpc-id,Values=<vpc-id> --query "NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Description]" --output table
```

- Description이 `ELB ...` 이면 남은 로드밸런서가 있다. EC2 콘솔의 로드밸런서 목록에서 지운다.
- Description이 `aws-K8S-...` 이고 Status가 `available` 이면 VPC CNI가 놓친 ENI다. 지워도 된다.
  ```bat
  aws ec2 delete-network-interface --region ap-northeast-2 --network-interface-id <eni-id>
  ```
- SG 삭제가 막히면 그 SG를 참조하는 다른 SG를 찾는다.
  ```bat
  aws ec2 describe-security-groups --region ap-northeast-2 --filters Name=ip-permission.group-id,Values=<sg-id> --query "SecurityGroups[].[GroupId,GroupName]" --output table
  ```

정리한 뒤 `terraform destroy` 를 다시 실행하면 남은 것부터 이어서 지운다.

### 클러스터에 아예 접속할 수 없을 때 (최후 수단)

클러스터 API에 접근할 수 없어 helm uninstall이 계속 실패하면, 클러스터 안의 리소스는 state에서 빼고 destroy한다.
클러스터가 지워지면 그 안의 리소스도 같이 사라지므로 AWS 쪽에 남는 것은 없다.

```bat
terraform state list | findstr /R "helm_release kubernetes_"
terraform state rm module.harness module.addons.helm_release.k6_operator module.addons.helm_release.kube_prometheus_stack module.addons.helm_release.cluster_autoscaler
terraform destroy
```

`module.harness` 에는 클러스터 안의 리소스(네임스페이스, ConfigMap)만 있어 모듈째 뺀다.
`module.addons` 는 Cluster Autoscaler의 IAM 역할 같은 AWS 리소스도 갖고 있으므로 helm_release 만 골라서 뺀다.

---

## 9. 💰 비용 주의사항

금액은 ap-northeast-2 기준 대략치이며 시점에 따라 달라진다.

| 항목 | 과금 | 비고 |
|---|---|---|
| **EKS 컨트롤 플레인** | 시간당 약 $0.10 (월 약 $73) | 노드가 0대여도 **클러스터가 있는 한 계속 과금된다** |
| NAT Gateway | 시간당 요금 + GB당 데이터 처리 | single NAT 1개. SUT가 VPC 안에 있으면 부하 트래픽은 NAT를 타지 않는다 |
| platform 노드그룹 | m6i.large ON_DEMAND 2대 상시 | Prometheus, Grafana, operator가 여기 뜬다 |
| loadgen 노드그룹 | SPOT, 평소 0대 | 테스트 중에만 과금된다 |
| ELB | 없음 | LoadBalancer Service를 만들지 않는다 |
| EBS | 없음 (노드 루트 디스크만) | Prometheus는 emptyDir. PVC를 만들지 않는다 |
| CloudWatch Logs / KMS | 없음 | 컨트롤 플레인 로그와 Secret 암호화를 껐다 |

**안 쓸 때는 `terraform destroy` 를 권장한다.** 테스트 자산(`run/tests`)과 결과(`run/results`)는
로컬에 있고 Terraform 상태와 무관하다. destroy할 때 사라지는 것은 Prometheus에 쌓인 메트릭뿐이다.

---

## 10. 상태 파일(backend)

지금은 **local backend**(`terraform.tfstate`, `.gitignore` 처리됨)를 쓴다. 팀이 함께 쓰게 되면 S3로 옮긴다.

1. 상태 저장용 S3 버킷을 따로 만든다(버저닝과 암호화 권장). 이 버킷은 이 스택으로 관리하지 않는다.
2. `main.tf` 의 `terraform {}` 블록에 다음을 추가한다.

   ```hcl
   backend "s3" {
     bucket       = "<state-bucket>"
     key          = "loglens-infra/terraform.tfstate"
     region       = "ap-northeast-2"
     encrypt      = true
     use_lockfile = true   # Terraform >= 1.10: S3 네이티브 락 (DynamoDB 불필요)
   }
   ```

3. `terraform init -migrate-state` 로 로컬 상태를 옮긴다.
4. 옮겨진 것을 확인한 뒤 로컬 `terraform.tfstate*` 를 지운다.
