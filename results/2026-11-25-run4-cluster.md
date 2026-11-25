# 2026-11-25 실험 7: Redis Cluster에서 Functions와 EVAL/EVALSHA

## 환경

| 항목 | 값 |
| --- | --- |
| 이미지 | `redis:8.10.2-alpine` (Redis 8.10.2) |
| 구성 | 마스터 3 + 레플리카 3 (`redis-cli --cluster create ... --cluster-replicas 1`), Q5에서 마스터 n7 추가 |
| 네트워크 | 도커 네트워크 `rlab-cluster-net` 10.231.77.0/24, 노드 N = `10.231.77.(10+N)`, `--cluster-announce-ip` |
| 영속성 | 노드마다 `--appendonly yes`, 볼륨 `rlab-cluster-data-N` |
| `cluster-node-timeout` | 15000ms |
| 실행 | `./run-7-cluster-functions.sh --cleanup` 1회. 원본 로그 `raw/2026-11-25-cluster/7-cluster-functions.log` |

처음 구성: 마스터 n1(슬롯 0-5460), n2(5461-10922), n3(10923-16383), 레플리카 n5→n1, n6→n2, n4→n3. 키 `k:3`은 n1, `k:1`은 n2, `k:4`는 n3 슬롯이다.

라이브러리: `clab`(`cluster/clusterlib.lua`, 실행한 노드 ID를 돌려줌), `ratelimit`(`lua/ratelimit-lib.lua`). 노드 표의 "코드 지문"은 라이브러리별 코드를 이름순으로 이어 붙인 sha1 앞 12자리다. 같으면 노드 간 코드가 같다. `da39a3ee5e6b`는 라이브러리가 없는 상태다.

---

## Q1. FUNCTION LOAD는 어디까지 퍼지는가

| 명령 | 응답 / 결과 |
| --- | --- |
| n1에서 `FUNCTION LOAD clab` | `clab`. 다른 노드에서 `FUNCTION LIST`로 보면 **n1과 그 레플리카 n5에만** 있고 n2·n3·n4·n6에는 없다 |
| `redis-cli --cluster call n1 FUNCTION LOAD REPLACE <ratelimit>` (전체 노드) | 마스터 3곳 `ratelimit`, 레플리카 3곳 `READONLY You can't write against a read only replica.`, **종료 코드 0**. 레플리카에는 복제로 들어와 6노드 모두 `ratelimit` 보유 |
| `... FUNCTION LOAD REPLACE <clab> --cluster-only-masters` | 마스터 3곳 `clab`, 에러 없음. 6노드 모두 `clab ratelimit`, 코드 지문 `960ad8a147fe`로 같음 |
| n1에만 `dup_a`(함수 `dup_fn`)를 올린 뒤 `--cluster call ... FUNCTION LOAD <dup_b(함수 dup_fn)> --cluster-only-masters` | n1 `ERR Function dup_fn already exists`, n2·n3 `dup_b`, **종료 코드 0**. 샤드마다 다른 라이브러리가 남았다 |

## Q2. FCALL 라우팅

| 명령 (보낸 노드) | 응답 |
| --- | --- |
| `FCALL hit 1 k:1` (n1, `-c` 없음) | `MOVED 10166 10.231.77.12:6379` |
| `redis-cli -c FCALL hit 1 k:1` (n1) | n2로 따라가 실행, n2 노드 ID 반환 |
| `FCALL hit 1 k:1` / `FCALL_RO cpeek 1 k:1` (레플리카 n6) | 둘 다 `MOVED 10166 ...12` (no-writes 함수도 기본은 마스터로 보냄) |
| `READONLY` 후 `FCALL_RO cpeek 1 k:1` (n6, 같은 연결) | n6에서 실행, n6 노드 ID 반환 |
| `FCALL hit2 2 k:3 k:1` (다른 마스터) / `k:3 k:7` (같은 마스터 다른 슬롯) | 둘 다 `CROSSSLOT Keys in request don't hash to the same slot`. `-c`를 붙여도 같음 |
| `-c FCALL hit2 2 {order:42}:stock {order:42}:coupon` (슬롯 8691) | 실행, n2에서 처리 |
| `FCALL whoami 0` (n1, n2, n3에 `-c`, 레플리카 n5) | 각각 **보낸 노드의 ID**. 키가 없으면 리다이렉트 없이 받은 노드가 실행 |
| `FCALL whoami_rw 0` (레플리카 n5, no-writes 없음) | `READONLY You can't write against a read only replica.` |
| `FCALL write_nokey 0 k:3` (n1, 키를 인자로만 넘김, n1 소유) | 실행 |
| `FCALL write_nokey 0 k:1` (n1, n2 소유) | `ERR Script attempted to access a non local key in a cluster node script: write_nokey, on @user_function:31.` `-c`를 붙여도 같음 (리다이렉트할 키가 없으므로) |
| 슬롯 5239를 n1→n2 이동 중으로 둠, `FCALL cpeek 1 {k:19}:missing` (n1) | `ASK 5239 10.231.77.12:6379`. `-c`면 n2에서 실행 |
| 같은 상태, 키가 있는 `{k:19}:present` | n1에서 실행 |
| 같은 상태, `FCALL hit2 2 {k:19}:present {k:19}:missing` | `TRYAGAIN Multiple keys request during rehashing of slot` |
| 같은 상태, n2에 `ASKING` 없이 `FCALL cpeek 1 {k:19}:missing` | `MOVED 5239 10.231.77.11:6379` |

## Q3. 스크립트(EVAL/EVALSHA)

| 명령 | 응답 |
| --- | --- |
| n1에서 `SCRIPT LOAD hit.lua` → `SCRIPT EXISTS` 6노드 | n1만 `1`. 레플리카 n5도 `0` (스크립트 캐시는 복제되지 않음) |
| `-c EVALSHA <sha> 1 k:1` (n1에서 보냄 → n2) | `NOSCRIPT No matching script. Please use EVAL.` |
| `EVAL ... 2 k:3 k:7` | `CROSSSLOT Keys in request don't hash to the same slot` |
| `-c EVAL ... 2 {order:42}:stock {order:42}:coupon` | 실행 |

선언 키 `k:3`(n1, 슬롯 2036) 외에 선언하지 않은 키를 건드릴 때 (`cluster/touch-other*.lua`, Function `touch_other`/`touch_other_x`):

| 본문 | 같은 노드 다른 슬롯 `k:7` | 다른 노드 `k:1` |
| --- | --- | --- |
| EVAL, shebang 없음 | **실행됨** | `ERR Script attempted to access a non local key in a cluster node script: <sha>, on @user_script:3.` |
| EVAL, `#!lua` (플래그 없음) | `ERR Script attempted to access keys that do not hash to the same slot script: <sha>, on @user_script:4.` | non local key 에러 |
| EVAL, `#!lua flags=allow-cross-slot-keys` | 실행됨 | non local key 에러 |
| Function, 플래그 없음 | `ERR Script attempted to access keys that do not hash to the same slot script: touch_other, ...` | non local key 에러 |
| Function, `allow-cross-slot-keys` | 실행됨 | non local key 에러 |

| 명령 | 응답 |
| --- | --- |
| `--cluster call n1 SCRIPT LOAD "$(cat touch-other.lua)"` (본문 첫 줄이 `-- ...` 주석) | `Unrecognized option or bad number of args for: '-- shebang 없음: ...`, 종료 코드 1, 어느 노드에도 보내지 않음 |
| `--cluster call n1 SCRIPT LOAD "$(cat hit.lua)"` (첫 줄이 코드) | 6노드 모두 같은 SHA. 레플리카에도 들어감 (`SCRIPT LOAD`는 쓰기 명령이 아님) |
| n2에서 `EVAL <hit-once 본문>` 후 `SCRIPT EXISTS` | `1`. EVAL로 실행한 스크립트는 그 노드 캐시에 남음 |

## Q4. 장애 조치와 재시작

`hit.lua`는 `--cluster call`로 모든 노드에, `hit-once.lua`는 n1에만 올린 상태에서 레플리카 n5에 `CLUSTER FAILOVER`.

| 노드 | 장애 조치 전 역할 / 함수 / `SCRIPT EXISTS hit hit-once` | 장애 조치 뒤 |
| --- | --- | --- |
| n1 | master / clab ratelimit / `1 1` | replica / 같음 / `1 1` |
| n5 | replica / clab ratelimit / `1 0` | master / 같음 / `1 0` |

| 명령 | 응답 |
| --- | --- |
| 새 마스터 n5 `INFO stats` | `sync_full:0`, `sync_partial_ok:1` (옛 마스터 n1이 부분 동기화로 붙음) |
| `-c FCALL hit 1 k:3` | 새 마스터 n5가 실행 |
| `-c EVALSHA <hit> 1 k:3` | 실행 (n5에도 미리 올려 둠) |
| `-c EVALSHA <hit-once> 1 k:3` | `NOSCRIPT No matching script. Please use EVAL.` |
| n5 `docker kill` 후 `docker start` (AOF 켬) | 로그 `DB loaded from append only file`, 역할 master 유지(node-timeout 안에 돌아옴), 함수 `clab ratelimit` 지문 동일, `SCRIPT EXISTS` `0 0` |
| 재시작 뒤 `-c FCALL hit 1 k:3` / `-c EVALSHA <hit> 1 k:3` | 실행 / `NOSCRIPT No matching script. Please use EVAL.` |

## Q5. 노드 추가와 슬롯 이동

| 명령 | 응답 / 결과 |
| --- | --- |
| n7에 `only7`을 올린 채 `--cluster add-node n7 n2` | `>>> New node already contains functions and can not be added to the cluster. Use FUNCTION FLUSH and try again.` n7은 합류하지 않음(`cluster_known_nodes:1`) |
| n7 `FUNCTION FLUSH` 후 다시 `add-node` | `>>> Getting functions from cluster` → `Send FUNCTION LIST ... verify there is no functions` → `Send FUNCTION RESTORE` → `[OK] New node added correctly.` n7에 `clab ratelimit`, 지문 다른 노드와 동일 |
| n7 `FUNCTION FLUSH` 뒤 예전 방식으로 슬롯 5969 이동 (`SETSLOT IMPORTING/MIGRATING`, `MIGRATE ... KEYS k:6`, 모든 마스터에 `SETSLOT NODE`) | 키는 n7로 옮겨짐(`GET k:6` → `legacy`). n7 라이브러리 없음. `-c FCALL hit 1 k:6` → `ERR Function not found` |
| n7에 `only7`만 둔 채 `--cluster reshard --cluster-from n2 --cluster-to n7 --cluster-slots 200 --cluster-yes` | `Waiting for migration task <id> to complete.` n7 `CLUSTER MIGRATION STATUS ALL`: `slots=5461-5660 operation=import state=completed`. 그 뒤 n7 라이브러리 `clab only7 ratelimit`. `-c FCALL hit 1 k:11`(옮겨진 키) 실행 |
| n7의 `clab`을 내용이 다른 판(`clab_v2_only`만 등록)으로 `REPLACE` 후 10슬롯 더 reshard | n7 `clab`이 원본(n2) 판으로 돌아감(지문이 이전과 동일), `FCALL clab_v2_only 0` → `ERR Function not found`, `only7`은 남음 |
| n3에서 `redis-cli -D "" --raw FUNCTION DUMP > file` | 1634 B |
| n7에 같은 라이브러리가 있는 채 `redis-cli -X dump_tag FUNCTION RESTORE dump_tag < file` | `ERR Library ratelimit already exists` (기본 정책 APPEND) |
| 같은 명령 + `REPLACE` | `OK` |
| n7 `FUNCTION FLUSH` → `-c FCALL hit 1 k:11` → 빈 n7에 `RESTORE` → 다시 `FCALL` | `ERR Function not found` → `OK` → 실행 |

## Q6. 한 마스터의 FUNCTION DELETE / FLUSH

마스터 n2, n3, n5, n7 상태에서:

| 명령 | 결과 |
| --- | --- |
| n3 `FUNCTION DELETE ratelimit` | n3과 레플리카 n4만 `clab`. 다른 샤드는 그대로 |
| n5 `FUNCTION FLUSH` | n5와 레플리카 n1만 비어 있음. 다른 샤드는 그대로 |
| `-c FCALL rate_limit 1 k:1 5 60000` (n2 슬롯) | `1`, `60000` |
| `-c FCALL rate_limit 1 k:4 5 60000` (n3 슬롯) | `ERR Function not found` |
| `-c FCALL hit 1 k:3` (n5 슬롯) | `ERR Function not found` |
| `--cluster call ... FUNCTION LOAD REPLACE ... --cluster-only-masters` 두 라이브러리 | 마스터 4곳 모두 성공, 7노드 지문 동일 |

---

## 사실 정리

- `FUNCTION LOAD`는 받은 마스터와 그 레플리카에만 있다. 다른 샤드에는 퍼지지 않는다. `DELETE`/`FLUSH`도 그 샤드 안에서만 효과가 있다.
- 함수가 없는 샤드의 키로 `FCALL`하면 `ERR Function not found`다. 같은 함수 이름이 샤드에 따라 되기도 하고 안 되기도 한다.
- `--cluster call`은 노드마다 따로 보내고, 일부 노드가 에러를 내도 종료 코드가 0이다. 레플리카를 포함하면 `FUNCTION LOAD`는 레플리카에서 `READONLY`로 실패한다(복제로는 들어온다).
- 함수 이름은 한 노드 안에서 라이브러리가 달라도 겹칠 수 없다(`ERR Function ... already exists`).
- 키가 1개 이상이면 `FCALL`/`EVALSHA`는 일반 명령처럼 MOVED/ASK/TRYAGAIN/CROSSSLOT 규칙을 따른다. 키가 0개면 받은 노드가 실행하며, 그 노드에 없는 키에 쓰면 non local key 에러가 난다.
- shebang이 없는 EVAL 스크립트는 같은 노드의 다른 슬롯 키에 접근할 수 있다. shebang이 있는 스크립트와 Function은 `allow-cross-slot-keys` 없이는 거부된다. 어느 경우든 다른 노드 키는 거부된다.
- 스크립트 캐시는 노드마다 따로다. 레플리카로 복제되지 않고, 재시작하면 비며, 장애 조치 뒤 새 마스터에는 그 노드가 스스로 가진 캐시만 있다.
- 함수는 AOF를 켠 마스터를 SIGKILL 후 시작해도 남았다.
- `--cluster add-node`는 기존 노드의 함수를 새 노드에 `FUNCTION RESTORE`하고, 새 노드에 함수가 이미 있으면 추가를 거부한다.
- Redis 8.10.2의 `--cluster reshard`는 원자적 슬롯 이동(`CLUSTER MIGRATION`, 8.4+)으로 동작했고, 대상 노드에 원본 노드의 라이브러리를 넣었다. 같은 이름의 라이브러리는 원본 판으로 덮였고, 대상에만 있는 라이브러리는 남았다. `SETSLOT` + `MIGRATE`로 옮긴 예전 방식에서는 함수가 따라가지 않았다.

## 문서와 비교

| 항목 | 문서 | 관찰 |
| --- | --- | --- |
| 클러스터 전 노드 로드 | functions-intro: 클러스터가 자동으로 하지 않으며 `redis-cli --cluster-only-masters --cluster call host:port FUNCTION LOAD ...` 사용 | 일치 |
| 레플리카 복제 | "replicated from master to replicas" | 일치 |
| `add-node` 함수 전파 | "automatically takes care to propagate the loaded functions" | 일치. 새 노드에 함수가 있으면 거부한다는 점은 문서에 없음 |
| 슬롯 이동 시 함수 | `CLUSTER MIGRATION`, functions-intro 모두 언급 없음 | reshard(ASM)는 함수를 덮어 넣음, 예전 MIGRATE 방식은 안 넣음. 문서에 없는 동작 |
| shebang과 교차 슬롯 | eval-intro: shebang 없는 스크립트는 다른 슬롯 키 접근 가능, `#!`가 있으면 불가 | 일치 (다만 다른 노드 키는 shebang 없이도 거부) |
| `allow-cross-slot-keys` | 여러 슬롯 접근 허용, 선언 키는 한 슬롯이어야 함 | 일치. 다른 노드 키는 여전히 거부 |
| 스크립트 캐시 휘발 | 재시작, 장애 조치, `SCRIPT FLUSH`로 비워질 수 있음 | 재시작 시 비워짐 확인. 장애 조치는 캐시를 지우지 않았고, 새 마스터가 원래 가진 캐시만 남음 |
| `--cluster call` 실패 처리 | 문서에 없음 | 노드별 에러가 있어도 종료 코드 0, `--`로 시작하는 인자는 옵션으로 해석해 거부 |

## 해석

- Functions는 "서버에 등록되고 영속·복제된다"는 장점이 샤드 경계에서 끝난다. 클러스터에서는 라이브러리 버전이 샤드마다 어긋날 수 있고, 어긋나면 키 슬롯에 따라 `Function not found`나 다른 판의 로직이 실행된다. EVALSHA의 NOSCRIPT 문제를 "배포 시 샤드 일관성" 문제로 바꾼 셈이다.
- 대신 장애 조치·재시작에는 Functions가 확실히 강하다. 스크립트는 레플리카까지 미리 올려 두지 않으면 장애 조치 직후 NOSCRIPT가 나고, 재시작하면 어차피 비므로 클라이언트의 EVALSHA→EVAL 대체가 필수다.
- reshard가 함수를 덮어쓰는 동작은 편리하지만, 대상 노드에 먼저 새 판을 올리고 슬롯을 옮기는 순서라면 새 판이 원본의 옛 판으로 되돌아간다. 라이브러리를 바꾸는 배포와 리샤딩을 동시에 하지 않는 편이 안전하다고 본다.
- 키 0개 `FCALL`은 클라이언트가 고른 노드에서 실행되므로 클러스터 클라이언트는 키 없는 호출을 임의 노드로 보낼 수 있다. 키를 다루는 함수는 반드시 키를 선언해야 한다.

## 운영 시 해야 할 일

1. 라이브러리 배포는 `redis-cli --cluster call <아무 노드> FUNCTION LOAD REPLACE "<코드>" --cluster-only-masters`로 하고, 종료 코드가 아니라 **노드별 응답 줄을 모두 확인**한다.
2. 배포 뒤 모든 노드(레플리카 포함)의 `FUNCTION LIST WITHCODE`를 비교해 같은지 검증한다(이 실험의 코드 지문처럼 라이브러리·함수 순서와 무관하게 비교).
3. 함수 이름은 라이브러리가 달라도 노드 안에서 유일해야 한다. 이름 충돌이 일부 샤드에서만 나면 배포가 반쯤 적용된다.
4. 노드 추가 런북: 새 노드는 빈 상태로 `--cluster add-node`(함수 자동 복사) → 지문 확인 → 슬롯 이동. 손으로 `CLUSTER MEET`하거나 예전 `MIGRATE` 방식 도구로 옮기면 `FUNCTION DUMP`/`RESTORE`(또는 `--cluster call` 재배포)로 직접 넣는다.
5. 리샤딩과 라이브러리 교체를 같은 시간대에 하지 않는다. 했다면 끝난 뒤 다시 전 마스터에 `LOAD REPLACE`하고 지문을 확인한다.
6. EVALSHA를 계속 쓴다면 클라이언트가 NOSCRIPT를 받으면 EVAL로 대체하게 하고, `--cluster call SCRIPT LOAD`(레플리카 포함)로 미리 올리는 것은 최적화로만 본다. 본문이 `--` 주석으로 시작하면 `--cluster call`이 거부하므로 첫 줄을 코드로 둔다.
7. 다중 키 로직은 해시 태그로 한 슬롯에 모으고 모든 키를 선언한다. `allow-cross-slot-keys`는 같은 노드의 다른 슬롯만 허용하므로 리샤딩 뒤 깨질 수 있다.

## 한계

- 로컬 Docker Desktop 한 대 위 7개 컨테이너, 1회 실행이다. 네트워크 분할, 자동 장애 조치(node-timeout 초과), 레플리카 승격 중 부분/전체 동기화 차이는 따로 만들지 않았다. Q4의 장애 조치는 수동 `CLUSTER FAILOVER` 한 번이고 부분 동기화로 붙은 경우만 봤다.
- reshard의 함수 전달은 Redis 8.10.2의 `redis-cli`가 원자적 슬롯 이동을 쓴 경우에서만 확인했다. 다른 버전, 다른 관리 도구(오퍼레이터, 관리형 서비스)는 다를 수 있다. 문서에 없는 동작이라 버전이 바뀌면 다시 확인해야 한다.
- 원자적 슬롯 이동이 함수를 어떤 방식으로 넣는지(스냅샷 RDB의 함수 섹션으로 보임)는 노드 로그와 결과로만 추정했고 소스는 확인하지 않았다.
- 클라이언트 라이브러리(예: Lettuce, Jedis)의 클러스터 라우팅은 시험하지 않았다. 키 0개 `FCALL`을 어느 노드로 보내는지는 클라이언트마다 다를 수 있다.
