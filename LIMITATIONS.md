# loglens-infra 한계와 주의사항

2026-10-09 기준. 각 항목의 `왜:` 는 그 한계가 생기는 이유다.

---

## 1. 검증된 것

| 항목 | 왜 중요한가 |
|---|---|
| apply → destroy 사이클 여러 번 반복, 리소스 75개 전부 정리 | 안 쓸 때 지우는 운영이 전제다. 남는 리소스가 있으면 비용이 샌다 |
| 러너 파드가 노드당 1개로 분산 | 출발지 IP와 conntrack 테이블을 노드 단위로 나누는 것이 이 도구의 목적이다 |
| 러너 파드 `ip_local_port_range` = `10240 65535` | 네트워크 네임스페이스 단위 sysctl 이라 노드가 아니라 파드에서 적용돼야 한다 |
| 대상 독립성: nginx, Spring Boot 앱을 `--target` 만 바꿔 테스트 | Terraform 을 건드리지 않고 대상을 바꾼다는 설계 원칙 |
| 결과 수집: `run/results/` 파일과 Grafana 양쪽 | destroy 하면 Prometheus 데이터가 사라지므로 파일이 유일한 기록이다 |
| 클러스터 내부 80, 443, 8080 통신 | EKS 모듈 기본 규칙은 노드 간 1025 이상만 열어 80/443 이 막혀 있었다 |
| Prometheus 질의 경로 (API 서버 서비스 프록시, 노드 SG 9090) | 컨트롤 플레인 → 파드 9090 이 기본 규칙에 없어 결과 합계가 `n/a` 였다 |

---

## 2. 검증되지 않은 것

### 규모
`--parallelism` 은 2, VU 는 800 까지만 써 봤다. 8 이상에서 loadgen 노드가 제때 올라오는지, SPOT 용량이 확보되는지는 모른다.
- 처음 크게 쏠 때는 `2 → 4 → 8` 로 올리고, 단계마다 러너가 모두 Running 이 되는지 확인한다.
- 왜: SPOT 용량은 시점·AZ 마다 다르고, 러너가 노드당 1개라 parallelism = 동시에 확보해야 할 SPOT 노드 수다.

### SPOT 회수
테스트 도중 loadgen 노드가 회수되는 경우를 겪어 본 적이 없다.
- 회수되면 그 러너는 중간에 죽고, k6-operator 는 다시 띄우지 않는다. 그 실행의 합계는 불완전하다.
- 왜: TestRun 은 일회성 Job 이고, SPOT 은 2분 예고 후 회수된다.

### 부하 대상 배치
테스트 대상을 platform 노드그룹(m6i.large, 2 vCPU)에 올리는 것을 전제로 한다. 같은 노드에 Prometheus, Grafana, k6-operator, Cluster Autoscaler 가 떠 있다.
- I/O 대기 측정(`/delay` 류)은 영향이 작다. 왜: 대기 중에는 CPU 를 거의 쓰지 않는다.
- CPU 포화 측정(`/cpu` 류)은 실제 한계보다 낮게 나온다. 왜: 관측 스택과 CPU 를 나눠 쓴다.
- 제대로 재려면 앱 전용 노드그룹을 추가해야 한다 (`modules/eks` 수정 필요).

### 외부 대상
VPC 밖(인터넷 경유) 대상은 테스트해 본 적이 없다.
- NAT Gateway 를 지나면 모든 러너 파드 IP 가 EIP 하나로 SNAT 된다. 왜: 프라이빗 서브넷의 외부 출구가 single NAT 하나다. 출발지 IP 를 나누려고 만든 환경의 의미가 사라진다.
- 외부 대상이 필요하면 VPC Peering 으로 사설 연결을 만든다. 계정이 달라도 되고, CIDR 만 겹치지 않으면 된다 (이 환경은 `10.40.0.0/16`).

### 클러스터에서 아직 돌려 보지 않은 코드
| 항목 | 확인된 범위 |
|---|---|
| `run.sh --env KEY=VALUE` | 입력 검증과 TestRun YAML 렌더링까지 (로컬) |
| `run/tests/sut-delay`, `sut-cpu`, `sut-mixed` | 로컬 k6 로 SUT jar 에 실행까지 |
| `run.sh --debug` | 로컬 가짜 kubectl 로 출력 형식까지 |
| `run/tests/port-exhaustion` | 로컬 Docker(Linux 커널 6.6, nginx 1.27)에서 포트 범위 500개로 EADDRNOTAVAIL 재현, 출발지 IP 1개 → 2개에서 성공 처리량 2.3배 |
| `run.sh --port-range`, `--vus`/`--parallelism` 나눗셈 경고 | 입력 검증과 TestRun YAML 렌더링까지 (로컬) |
| `--parallelism` 상한 검사 (`LOGLENS_LOADGEN_MAX_SIZE`) | `terraform validate` 까지. harness-config 에 키가 생기려면 apply 가 필요하다 |
| `run/compare.sh` | 로컬 Docker k6 요약으로 만든 결과 파일로 파싱까지 |

왜: 위 검증 이후에 추가된 코드다. 첫 실행 때 결과 파일의 `env` 줄과 `sut_virtual_thread` 값을 확인한다.

### 결과 파일의 러너 요약 누락 (원인 미확정)
2026-10-08 실행 한 건에서 결과 파일에 `## runner ...` 절이 빠지고 정리 로그가 섞였다.
- 러너 파드 목록 조회 실패로 스크립트가 끝난 것으로 보지만, 그때의 kubectl 오류가 남지 않아 확정하지 못했다.
- 지금은 조회가 실패해도 계속 진행하고 오류 메시지를 결과 파일에 남긴다. 재발하면 그 메시지가 원인이다.
- 왜: Failed 상태 파드는 원인이 아니다 (jsonpath 가 exit 99 를 정상으로 읽는 것을 확인했다).

### 실행 환경
`run.sh` 는 Windows Git Bash 에서만 돌려 봤다. 스크립트 머리말에는 Linux / macOS 도 적혀 있지만 확인하지 않았다.
- 왜: `MSYS_NO_PATHCONV`, kubectl 출력의 CR 제거 등 Git Bash 대응 코드가 들어 있다.

---

## 3. 측정상 한계

| 한계 | 왜 |
|---|---|
| 결과 파일의 p95/p99 는 러너별 값만 정확하다. 전체 분포는 Grafana 에서 본다 | 백분위는 러너끼리 더하거나 평균 낼 수 없다 |
| 포화 구간의 지연은 실제보다 작게 나온다 (`constant-vus` closed model) | 응답이 느려지면 VU 가 다음 요청을 늦게 보내 부하가 스스로 줄어든다. 도착률을 고정하려면 `constant-arrival-rate` 로 바꾼다 |
| 러너가 먼저 포화되면 SUT 가 아니라 러너의 한계를 잰 것이다 | 러너는 c6i.large(2 vCPU) 1대당 1개다. Grafana 에서 loadgen 노드 CPU 를 같이 본다 |
| 러너 1개가 같은 대상(IP:port)에 동시에 열 수 있는 연결은 약 55,000 개다 | 출발지 포트 범위가 10240~65535 다 |
| SUT 파드 간 부하가 고르지 않을 수 있다 | ClusterIP 는 새 연결에서만 파드를 고르고, keep-alive 연결은 끝까지 같은 파드에 붙는다 (loglens-sut 는 keep-alive 무제한) |
| Prometheus 데이터는 destroy 나 Prometheus 파드 재시작 때 사라진다. 보존은 7일 / 6GB | 저장소가 emptyDir 이다 (EBS 를 만들지 않아 destroy 가 깨끗하다) |

---

## 4. 운영상 주의

| 주의 | 왜 |
|---|---|
| 안 쓸 때는 반드시 `terraform destroy`. 켜 두면 하루 약 10 USD | EKS 컨트롤 플레인, platform 노드 2대, NAT Gateway 가 노드 0대여도 과금된다 |
| `loglens-ecr` 은 별도 스택이며 destroy 대상이 아니다 | 이미지는 롤백 대상이라 유지한다. 상태가 분리되어 있고 `prevent_destroy` 가 걸려 있다 |
| 부하 대상은 반드시 같은 VPC 안에 둔다 | 2절 "외부 대상" |
| 비교 측정에서는 측정 조건을 응답에 담아 결과 파일에 남긴다 | 예: loglens-sut `/delay` 응답의 `virtual` 을 k6 Rate 메트릭(`sut_virtual_thread`)으로 집계한다. 설정이 실제로 적용됐는지, 롤아웃 도중에 측정하지 않았는지가 결과 파일만으로 확인된다. 응답에 담기지 않는 조건(예: `SERVER_TOMCAT_THREADS_MAX`)은 `--env` 로 메모를 남긴다 |
| 테스트가 끝난 뒤에도 loadgen 노드는 약 10분 더 과금된다 | Cluster Autoscaler 의 `scale-down-unneeded-time` 이 10분이다 |
| `endpoint_public_access_cidrs` 를 내 공인 IP/32 로 좁힌다 | 기본값이 `0.0.0.0/0` 이다 (README 5절) |
| `terraform.tfstate` 를 잃지 않는다 | local backend 다. 잃으면 destroy 할 수 없어 콘솔에서 수동으로 정리해야 한다 (README 10절) |
| NAT Gateway 가 있는 AZ 가 장애면 노드가 이미지를 받지 못한다 | 비용 때문에 single NAT 다 |
| 재구축 전에 Kubernetes 버전의 표준 지원 기간을 확인한다 | 표준 지원이 끝난 버전은 확장 지원 요금(컨트롤 플레인 약 6배)이 붙는다 |
