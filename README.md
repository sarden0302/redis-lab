# Redis 확장 방식 실험실: Lua 스크립트 vs Functions vs Modules

Redis에 로직을 더하는 세 가지 방법을 같은 조건에서 비교하고, 직접 다시 돌려 볼 수 있게 만든 실험 모음입니다.

| 방식 | 명령 | 이 실험에서 보는 것 |
| --- | --- | --- |
| Lua 스크립트 | `EVAL` / `EVALSHA` | 조건부 갱신을 한 번의 왕복으로 원자적으로 처리. 스크립트 캐시는 휘발성 |
| Redis Functions | `FUNCTION LOAD` / `FCALL` | 같은 Lua 로직을 서버에 등록된 라이브러리로. 영속·복제·ACL 차이 |
| 모듈 데이터 타입 | `JSON.*`, `BF.*`, `CF.*` | Redis 8에 기본 포함된 RedisJSON·RedisBloom. 명령만으로 어디까지 되는지 |

첫 측정 결과는 [results/2026-11-25-run1.md](results/2026-11-25-run1.md)에, 실험 5(WATCH vs Lua vs Functions) 결과는 [results/2026-11-25-run2-watch.md](results/2026-11-25-run2-watch.md)에 있습니다.

## 준비물

- Docker Desktop (Windows에서 확인함)
- Git Bash. 스크립트는 bash로 작성했습니다. PowerShell에서 직접 실행하지 않습니다.
- 이미지 `redis:8.10.2-alpine`, 실험 5는 클라이언트용 `python:3.13.7-alpine`도 씁니다. Redis 8 공식 이미지는 alpine 판에도 RedisJSON(`ReJSON`), RedisBloom(`bf`), RediSearch(`search`), RedisTimeSeries(`timeseries`), `vectorset` 모듈이 들어 있고 엔트리포인트가 자동으로 불러옵니다. 별도 이미지가 필요 없습니다.

```bash
docker image inspect redis:8.10.2-alpine >/dev/null || docker pull redis:8.10.2-alpine
docker image inspect python:3.13.7-alpine >/dev/null || docker pull python:3.13.7-alpine
```

## 실행

Git Bash에서 이 폴더로 이동한 뒤 실행합니다.

```bash
cd redis-lab   # git clone https://github.com/sarden0302/redis-lab.git 로 받은 폴더

./run-all.sh              # 실험 1~7을 차례로 실행 (6은 1~5 컨테이너를 지운 뒤, 7은 별도 클러스터)
./run-all.sh --cleanup    # 실행 후 lab 컨테이너·볼륨·네트워크까지 삭제

./run-1-session.sh        # 실험 하나만
./run-2-dedup.sh
./run-3-eval-vs-function.sh
./run-4-busy.sh
./run-5-watch-vs-lua.sh

./cleanup.sh              # 컨테이너 redis-lab(-client), 볼륨 redis-lab-data, 네트워크 redis-lab-net 삭제
```

- 스크립트가 없으면 컨테이너 `redis-lab`(볼륨 `redis-lab-data`, AOF 켬)을 만들고, 있으면 그대로 씁니다. 포트는 열지 않고 `docker exec`로만 접근합니다.
- 각 실험은 시작할 때 lab 컨테이너 안에서 `FLUSHALL`, `FUNCTION FLUSH`, `SCRIPT FLUSH`를 실행하므로 몇 번이든 다시 돌릴 수 있습니다. 다른 컨테이너는 건드리지 않습니다.
- 로그는 `results/raw/<실행 날짜>/`에 실험별 `*.log`(명령과 응답 전체)와 `*-bench.csv`(처리량 요약)로 남습니다. 같은 날 다시 돌리면 덮어씁니다. 보존하려면 `LAB_DATE=2026-11-25-b ./run-all.sh`처럼 폴더 이름을 바꿉니다.

크기를 줄여 빨리 돌려 보려면 환경 변수를 씁니다.

| 변수 | 기본값 | 뜻 |
| --- | --- | --- |
| `BENCH_N` | 100000 | redis-benchmark 요청 수 (`-n`) |
| `BENCH_C` | 50 | 동시 연결 수 (`-c`) |
| `BENCH_PIPELINES` | `"1 16"` | 파이프라인 깊이 (`-P`) 목록 |
| `SESSION_N` | 10000 | 실험 1 세션 수 |
| `DEDUP_N` / `DEDUP_MISS_N` | 1000000 / 100000 | 실험 2 적재 ID 수 / 거짓 양성 확인용 ID 수 |
| `LAB_DATE` | 오늘 날짜 | 로그 폴더 이름 (실험 5는 `<LAB_DATE>-watch`) |
| `W_DURATION` | 5 | 실험 5 칸 하나(전략 × 경합 × 연결 수)의 측정 시간(초) |
| `W_CONNS` | `"1 8 32"` | 실험 5 동시 연결 수 목록 |
| `W_REPS` | 3 | 실험 5 반복 횟수 |
| `W_HOT_KEYS` | 1 | 실험 5 높은 경합에서 모든 연결이 나눠 쓰는 키 수 |

```bash
BENCH_N=20000 DEDUP_N=100000 ./run-2-dedup.sh
```

## 실험 내용

### 1. 세션 객체 저장과 조건부 갱신 (`run-1-session.sh`)

프로젝트의 `issue-session.lua`처럼 "상태가 ACTIVE이고 인증 버전이 기대값과 같을 때만 쓴다"를 세 가지로 구현합니다. 갱신 내용은 `lastSeenAt` 기록입니다.

| 구현 | 파일 |
| --- | --- |
| Hash + Lua | `lua/session-touch-hash.lua` |
| RedisJSON 문서 + Lua(안에서 `JSON.GET`/`JSON.SET`) | `lua/session-touch-json.lua` |
| RedisJSON 명령만: 필터 경로 `JSON.MERGE key '$[?(@.state=="ACTIVE" && @.authVersion==3)]' '{...}'` | 스크립트 안 명령 1줄 |

- 측정: 코드 줄 수, 세션 1만 개의 `MEMORY USAGE` 합계와 `used_memory` 증가량, 일치·버전 불일치·BLOCKED·키 없음 각각의 응답, redis-benchmark 처리량 (조건 항상 일치, 파이프라인 1/16). 조건 없는 `HSET`/`JSON.SET`을 기준선으로 같이 잽니다.
- `JSON.SET ... NX/XX`, `JSON.NUMINCRBY`가 값 조건을 걸 수 없다는 것도 응답으로 확인합니다.
- 프로젝트는 세션 키와 계정 가드 키를 나눠 두지만, 여기서는 비교를 단순하게 하려고 한 객체에 state·authVersion을 같이 둡니다.

### 2. 중복 요청 감지 (`run-2-dedup.sh`)

요청 ID 100만 개를 Set(`SADD`)과 Bloom filter(`BF.RESERVE 0.001 1000000`, `BF.ADD`)에 넣고 비교합니다. Cuckoo filter(`CF.RESERVE 1000000`, `CF.ADDNX`)도 참고로 같이 넣습니다.

- 측정: 적재 시간(서버 안 Lua 루프), 메모리(`MEMORY USAGE`, `BF.INFO`, `CF.INFO`), 넣지 않은 ID 10만 개로 잰 거짓 양성률, 넣은 ID 조회(거짓 음성 0 확인), 삭제 가능 여부, 추가·조회 처리량.
- 적재는 redis-benchmark가 아니라 `lua/dedup-bulk.lua` 루프로 합니다. 정확히 100만 개의 서로 다른 ID를 넣기 위해서입니다.

### 3. 같은 로직을 EVAL과 FUNCTION으로 (`run-3-eval-vs-function.sh`)

프로젝트의 `rate-limit.lua`(고정 시간창 요청 제한)를 그대로 `lua/rate-limit.lua`로 두고, 같은 로직을 `lua/ratelimit-lib.lua` 라이브러리(`#!lua name=ratelimit`)로 옮겼습니다.

- 처리량: `EVAL`(본문 전송), `EVALSHA`, `FCALL`, 기준선 `INCR`.
- 수명: `SCRIPT FLUSH` 뒤 `EVALSHA`는 `NOSCRIPT`, `FCALL`은 동작. `FLUSHALL`은 함수를 지우지 않음. 컨테이너 재시작 뒤 스크립트 캐시는 비고 함수는 AOF/RDB에서 복원됨.
- ACL: `+evalsha_ro +fcall_ro` 읽기 전용 사용자, `+fcall`만 가진 앱 사용자, 스크립트 안 명령(`incr`)도 호출자 권한으로 검사되는지, `+eval` 사용자가 임의 코드를 보낼 수 있는지.

### 4. 오래 도는 스크립트 (`run-4-busy.sh`)

`busy-reply-threshold`를 1초로 낮추고 무한 루프를 `EVAL`과 `FCALL`로 각각 돌려 `BUSY` 응답과 `SCRIPT KILL`/`FUNCTION KILL`이 어느 쪽에 듣는지 봅니다. 이미 쓰기를 한 스크립트는 `UNKILLABLE`이 되어 `SHUTDOWN NOSAVE`로만 멈출 수 있고, 이때 lab 컨테이너가 한 번 멈췄다가 다시 시작됩니다.

### 5. 같은 조건부 갱신을 WATCH/MULTI/EXEC와 EVALSHA, FCALL로 (`run-5-watch-vs-lua.sh`)

실험 1의 조건부 갱신(state가 ACTIVE이고 authVersion이 기대값일 때만 쓰기)을 클라이언트 낙관적 잠금과 서버 쪽 Lua로 비교합니다. 실험 1 결과에서 "측정하지 않았다"고 남긴 부분입니다.

| 전략 | 흐름 | 파일 |
| --- | --- | --- |
| `watch-multi` | `WATCH`+`HMGET`(왕복 1) → 클라이언트에서 판단 → `MULTI`/`HSET`/`EXEC`(왕복 1). `EXEC`가 nil이면 처음부터 다시, 재시도 10회 뒤 포기 | `client/watch_bench.py` |
| `naive` | 같은 흐름에서 `WATCH`만 뺀 대조군. 잃어버린 갱신이 검사에 실제로 잡히는지 확인용 | 〃 |
| `evalsha` | `EVALSHA` 왕복 1 | `lua/session-touch-count.lua` |
| `fcall` | `FCALL session_touch` 왕복 1 | `lua/session-lib.lua` |

- 잃어버린 갱신을 세려고 실험 1의 `session-touch-hash.lua`에 필드 하나를 더한 `session-touch-count.lua`를 씁니다. `lastSeenAt`과 함께 `touches`에 "읽은 값 + 1"을 씁니다. 칸이 끝나면 `touches` 합계와 클라이언트가 센 성공 수를 비교합니다.
- 서버는 기존 `redis-lab` 컨테이너, 클라이언트는 `redis-lab-client`(`python:3.13.7-alpine`, `--rm`)입니다. 둘은 전용 네트워크 `redis-lab-net`으로만 연결하고 포트는 열지 않습니다. 클라이언트는 표준 라이브러리 asyncio로 쓴 최소 RESP2 클라이언트(`client/resp.py`)이고, 연결 N개를 한 이벤트 루프에서 돌립니다.
- 경합: 낮음은 세션 1만 개 중 무작위 키, 높음은 모든 연결이 키 1개(`W_HOT_KEYS`)를 갱신합니다. 연결 수 1·8·32, 칸마다 5초, 3회 반복합니다.
- 측정: 초당 성공 수, 논리 갱신 하나의 p50/p99 지연(재시도 포함), 갱신당 왕복·보낸 명령 수, 서버 `total_commands_processed` 증가량, `EXEC` 중단(nil)과 포기 수, 잃어버린 갱신 수.
- 단일 호출 기록: 충돌 없는 WATCH 흐름, 다른 연결이 끼어들어 `EXEC`가 nil을 받고 다시 시도하는 흐름, 조건 불일치 시 `UNWATCH`, `EVALSHA`/`FCALL`의 명령과 응답을 로그 앞부분에 남깁니다.
- 결과는 `results/raw/<날짜>-watch/`의 `5-watch-vs-lua.log`와 `5-watch-vs-lua-bench.csv`입니다.

주의할 점:

- Python 클라이언트는 redis-benchmark보다 훨씬 느리고, 연결이 많아도 한 스레드에서 돕니다. 이 실험의 처리량은 대부분 클라이언트 CPU에 묶여 있어 실험 1~4의 수치와 비교하지 않고, 전략끼리만 비교합니다. 왕복 수가 많은 전략은 클라이언트가 할 일도 많아 그만큼 불리합니다.
- 컨테이너 사이 왕복은 Docker Desktop VM 안의 가상 네트워크라 실제 서버 간 네트워크보다 짧습니다. 왕복이 길어지면 WATCH 방식은 지연과 충돌 창이 함께 커집니다.
- WATCH 흐름은 `WATCH`와 `HMGET`을 한 번에 보내는, 이 방식에 가장 유리한 형태입니다. 흔한 클라이언트 라이브러리처럼 따로 보내면 왕복이 하나 더 늡니다.

### 6. 벤치마크 클라이언트 분리 (`run-6-split-client.sh`)

실험 1~3의 처리량 부분만, `redis-benchmark`를 서버와 다른 컨테이너에서 돌려 다시 잽니다. 서버와 클라이언트가 한 컨테이너에서 CPU를 나눠 쓴 1차 측정이 왜곡됐는지 확인하는 용도입니다. 결과는 [results/2026-11-25-run3-split-client.md](results/2026-11-25-run3-split-client.md)에 있습니다.

```bash
./run-6-split-client.sh up            # 네트워크 rlab-split-net, 서버 rlab-split-server, 클라이언트 rlab-split-client 생성
./run-6-split-client.sh run rep1      # 실험 1~3 처리량 1회. 로그: results/raw/2026-11-25-split/rep1.log, rep1-bench.csv
./run-6-split-client.sh down          # 두 컨테이너(익명 /data 볼륨 포함)와 네트워크 삭제
```

- 서버는 1차와 같이 `--appendonly yes`로 띄우고 포트는 열지 않습니다. 클라이언트는 같은 이미지를 `sleep infinity`로 띄워 두고 `docker exec ... redis-benchmark -h rlab-split-server`로 잽니다.
- 명령·키 범위·적재 데이터는 실험 1~3과 같습니다. 정확성·메모리·수명·ACL 확인은 하지 않습니다.
- CPU 제한 기본값은 서버·클라이언트 각각 `--cpus=2`입니다. `SERVER_CPUS`, `CLIENT_CPUS`로 바꾸고 `0`이면 제한하지 않습니다. 값은 `up`과 `run`에 같이 줘야 로그 머리말에 맞게 찍힙니다.
- `lib.sh`는 읽기만 합니다(`rc`, `rc_file`, `BENCH_*` 기본값). 로그 폴더는 `LAB_DATE`(기본 `2026-11-25-split`)로 바꿉니다.
- 다른 벤치마크와 겹치지 않게, 실행 전에 `docker ps`로 다른 lab 컨테이너가 없는지 확인합니다.

### 7. 클러스터에서 Functions와 스크립트 (`run-7-cluster-functions.sh`)

로컬에 마스터 3 + 레플리카 3 Redis Cluster를 만들고, `FUNCTION LOAD`/`FCALL`과 `SCRIPT LOAD`/`EVALSHA`가 클러스터에서 어떻게 퍼지고 라우팅되는지 응답으로 확인합니다. 처리량은 재지 않는 기능 확인 실험이라 부하는 거의 없습니다. 결과는 [results/2026-11-25-run4-cluster.md](results/2026-11-25-run4-cluster.md)에 있습니다.

```bash
./run-7-cluster-functions.sh                 # 클러스터를 새로 만들고 확인. 끝난 뒤 클러스터는 남겨 둔다 (약 1~2분)
./run-7-cluster-functions.sh --cleanup       # 확인 뒤 rlab-cluster-* 컨테이너·볼륨·네트워크를 지운다
./run-7-cluster-functions.sh --cleanup-only  # 지우기만 한다
```

- 실행할 때마다 이전 `rlab-cluster-*` 리소스를 지우고 새로 만듭니다. 다른 실험의 `redis-lab` 컨테이너와는 이름·네트워크가 겹치지 않습니다.
- 리소스: 네트워크 `rlab-cluster-net`(`10.231.77.0/24`, 노드 N은 `10.231.77.(10+N)`), 컨테이너 `rlab-cluster-1`~`7`, 볼륨 `rlab-cluster-data-1`~`7`. 포트는 열지 않고 `docker exec`로만 접근합니다. 노드는 `--cluster-announce-ip`로 자기 IP를 알리고 AOF를 켭니다.
- `cluster/*.lua`와 `lua/ratelimit-lib.lua`를 각 컨테이너의 `/lab/`에 복사해 씁니다. `cluster/clusterlib.lua`(라이브러리 `clab`)는 실행한 노드 ID를 같이 돌려줘 어느 노드에서 실행됐는지 보이게 합니다.
- 로그는 `results/raw/<날짜>-cluster/7-cluster-functions.log` 하나에 명령과 응답이 모두 남습니다. 노드 표의 "코드 지문"은 라이브러리 이름순으로 `FUNCTION LIST LIBRARYNAME <lib> WITHCODE` 출력을 이어 붙인 sha1 앞 12자리라, 같으면 노드 간 함수 코드가 같습니다.
- `NODE_TIMEOUT`(기본 15000ms) 안에 Q4-b의 강제 종료 노드가 돌아와야 자동 장애 조치 없이 진행됩니다.

| 단계 | 확인 내용 |
| --- | --- |
| Q1 | 마스터 한 곳 `FUNCTION LOAD`가 다른 마스터·레플리카에 보이는지, `--cluster call`(전체/`--cluster-only-masters`)로 올리기, 일부 노드만 실패할 때 |
| Q2 | `FCALL` 라우팅: MOVED와 `-c`, CROSSSLOT, 해시 태그, 키 0개 호출, 레플리카, 슬롯 이동 중 ASK/TRYAGAIN |
| Q3 | `SCRIPT LOAD` 범위와 `EVALSHA` NOSCRIPT, `EVAL` CROSSSLOT, 선언하지 않은 키 접근(shebang 유무, `allow-cross-slot-keys`), `--cluster call SCRIPT LOAD` |
| Q4 | `CLUSTER FAILOVER` 뒤 함수·스크립트 캐시, AOF를 켠 마스터를 `docker kill` 후 시작 |
| Q5 | `--cluster add-node`의 함수 복사, 예전 방식 슬롯 이동(SETSLOT+MIGRATE)과 `--cluster reshard`(원자적 슬롯 이동)의 함수 전달 차이, `FUNCTION DUMP`/`RESTORE` |
| Q6 | 한 마스터의 `FUNCTION DELETE`/`FUNCTION FLUSH`가 다른 샤드에 영향이 있는지, 복구 |

## 해석할 때 주의

- 로컬 단일 노드, Windows의 Docker Desktop(WSL2 VM) 위 컨테이너 한 개입니다. redis-benchmark도 같은 컨테이너 안에서 돌아 서버와 CPU를 나눠 씁니다. 네트워크 왕복이 거의 없어서 왕복 횟수 차이는 실제 서비스보다 작게 보입니다.
- 처리량은 실행할 때마다 수 % ~ 수십 % 흔들립니다. 특히 파이프라인 1은 Docker Desktop 스케줄링의 영향을 크게 받습니다. 순위가 뒤집히지 않는 큰 차이만 해석하고, 절대값은 다른 환경으로 일반화하지 않습니다.
- `MEMORY USAGE`는 추정치이고 모듈 타입은 모듈이 보고한 값입니다. `used_memory` 증가량에는 키 공간 dict 확장 같은 공통 비용이 섞입니다.
- 버전: Redis 8.10.2, 모듈 버전은 `MODULE LIST` 기준 bf/timeseries/search 81001, ReJSON 81000.

## 파일

```text
lib.sh                     공통 함수 (컨테이너 준비, 로그, 벤치마크 요약)
client/                    실험 5 Python 클라이언트 (resp.py 최소 RESP2 클라이언트, watch_bench.py 전략과 측정)
run-all.sh, run-*.sh       실험 실행
cleanup.sh                 컨테이너·볼륨·네트워크 삭제
lua/                       실험에 쓰는 Lua 스크립트와 Function 라이브러리
results/<날짜>-runN.md     정리한 결과
results/raw/<날짜>/        원본 로그
```
