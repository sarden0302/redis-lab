#!/usr/bin/env bash
# 실험 7. Redis Cluster에서 Functions와 EVAL/EVALSHA 스크립트가 어떻게 동작하는지 본다.
# 마스터 3 + 레플리카 3 클러스터를 새로 만들고, 질문 1~6을 차례로 확인한다. 기능 확인용이라 부하는 거의 없다.
#
#   ./run-7-cluster-functions.sh                 # 클러스터를 새로 만들고 확인. 끝난 뒤 클러스터는 남겨 둔다
#   ./run-7-cluster-functions.sh --cleanup       # 확인 뒤 rlab-cluster-* 컨테이너·볼륨·네트워크를 지운다
#   ./run-7-cluster-functions.sh --cleanup-only  # 지우기만 한다
#
# 이름: 네트워크 rlab-cluster-net(10.231.77.0/24), 컨테이너 rlab-cluster-1..7, 볼륨 rlab-cluster-data-1..7.
# 다른 실험(redis-lab*, rlab-split*)과 commerce-settle* 리소스는 건드리지 않는다. 포트는 열지 않는다.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash가 '/lab/x.lua' 같은 인자를 Windows 경로로 바꾸지 않게 한다.
export MSYS2_ARG_CONV_EXCL='*'

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${LAB_IMAGE:-redis:8.10.2-alpine}"
NET=rlab-cluster-net
SUBNET_PREFIX=10.231.77
NODE_TIMEOUT="${NODE_TIMEOUT:-15000}"
LAB_DATE="${LAB_DATE:-$(date +%Y-%m-%d)-cluster}"
RAW_DIR="$LAB_DIR/results/raw/$LAB_DATE"
ALL_NODES="1 2 3 4 5 6 7"

cname() { echo "rlab-cluster-$1"; }
ipof() { echo "$SUBNET_PREFIX.$((10 + $1))"; }
ip2n() { awk -F. '{print $4 - 10}'; }

cleanup() {
  for n in $ALL_NODES; do
    docker rm -f "$(cname "$n")" >/dev/null 2>&1 || true
    docker volume rm "rlab-cluster-data-$n" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
}

case "${1:-}" in
  --cleanup-only) cleanup; echo "rlab-cluster 리소스를 지웠습니다."; exit 0 ;;
  --cleanup) CLEANUP_AT_END=1 ;;
  "") CLEANUP_AT_END=0 ;;
  *) echo "usage: $0 [--cleanup|--cleanup-only]" >&2; exit 2 ;;
esac

mkdir -p "$RAW_DIR"
LOG="$RAW_DIR/7-cluster-functions.log"
exec > >(tee "$LOG") 2>&1

# ---------- 도우미 ----------
r() { local n="$1"; shift; docker exec "$(cname "$n")" redis-cli "$@" | tr -d '\r'; }
rsh() { local n="$1"; shift; docker exec "$(cname "$n")" sh -c "$*" 2>&1 | tr -d '\r'; }
label() { printf 'n%s %s' "$1" "$(role_of "$1")"; }
section() { printf '\n===== %s =====\n' "$*"; }
# 실행한 명령과 응답을 함께 남긴다. 에러 응답도 그대로 찍는다.
show() { local n="$1"; shift; printf '> [%s] redis-cli %s\n' "$(label "$n")" "$*"; r "$n" "$@" 2>&1 || true; }
showc() { local n="$1"; shift; printf '> [%s] redis-cli -c %s\n' "$(label "$n")" "$*"; r "$n" -c "$@" 2>&1 || true; }
# --cluster call 은 보낸 명령 본문(라이브러리 코드 전체)을 먼저 찍으므로 노드별 응답 줄과 종료 코드만 남긴다.
# ccall <노드> <명령 인자 문자열> [옵션...]: 그 노드를 진입점으로 --cluster call 을 실행한다.
ccall() {
  local n="$1" cmd="$2"; shift 2
  printf '> [%s] redis-cli --cluster call %s:6379 %s %s\n' "$(label "$n")" "$(ipof "$n")" "$cmd" "$*"
  rsh "$n" "redis-cli --cluster call $(ipof "$n"):6379 $cmd $*; echo \"exit=\$?\"" \
    | grep -E '^([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+:[0-9]+: |exit=|Unrecognized)' || true
}
# 컨테이너 안 셸 명령(파일 내용을 인자로 넘길 때). 출력에는 사람이 읽을 명령을 따로 적는다.
showsh() { local n="$1" desc="$2"; shift 2; printf '> [%s] %s\n' "$(label "$n")" "$desc"; rsh "$n" "$@" || true; }

copy_lab_files() {
  local n="$1" f
  rsh "$n" 'mkdir -p /lab' >/dev/null
  for f in "$LAB_DIR"/cluster/*.lua "$LAB_DIR/lua/ratelimit-lib.lua"; do
    docker exec -i "$(cname "$n")" sh -c "cat > /lab/$(basename "$f")" < "$f"
  done
}

start_node() {
  local n="$1"
  docker volume create "rlab-cluster-data-$n" >/dev/null
  docker run -d --name "$(cname "$n")" --network "$NET" --ip "$(ipof "$n")" \
    -v "rlab-cluster-data-$n:/data" "$IMAGE" \
    redis-server --cluster-enabled yes --cluster-config-file nodes.conf \
      --cluster-node-timeout "$NODE_TIMEOUT" --cluster-announce-ip "$(ipof "$n")" \
      --appendonly yes >/dev/null
  wait_ping "$n"
  copy_lab_files "$n"
}

wait_ping() {
  for _ in $(seq 1 100); do
    [ "$(r "$1" PING 2>/dev/null)" = "PONG" ] && return 0
    sleep 0.2
  done
  echo "n$1 not ready" >&2; return 1
}

# 지정한 노드들이 모두 cluster_state:ok 가 될 때까지 기다린다.
wait_cluster_ok() {
  local n ok
  for _ in $(seq 1 150); do
    ok=1
    for n in "$@"; do
      r "$n" CLUSTER INFO 2>/dev/null | grep -q '^cluster_state:ok' || ok=0
    done
    [ "$ok" = 1 ] && return 0
    sleep 0.2
  done
  echo "cluster not ok" >&2; return 1
}

# CLUSTER NODES를 한 번 읽어 노드 역할과 키→슬롯→소유 마스터 표를 갱신한다.
QN=1   # 토폴로지를 물어볼 노드
refresh_topology() {
  CN="$(r "$QN" CLUSTER NODES)"
  KEYMAP="$(awk 'NR==FNR {
      if ($3 ~ /master/ && $3 !~ /fail/) {
        split($2, b, ":"); n = b[1]; sub(/.*\./, "", n); n = n - 10
        for (i = 9; i <= NF; i++) {
          if ($i ~ /^\[/) continue
          c = split($i, a, "-"); lo = a[1]; hi = (c == 2 ? a[2] : a[1])
          R[++m] = lo " " hi " " n
        }
      }
      next
    }
    { for (j = 1; j <= m; j++) { split(R[j], x, " "); if ($2 >= x[1] + 0 && $2 <= x[2] + 0) { print $1, $2, x[3]; break } } }' \
    <(printf '%s\n' "$CN") <(printf '%s\n' "$KEYTAB"))"
}
role_of() { printf '%s\n' "$CN" | awk -v ip="$(ipof "$1")" 'index($2, ip ":") == 1 { print ($3 ~ /master/ ? "master" : "replica"); f = 1 } END { if (!f) print "-" }'; }
id_of() { r "$1" CLUSTER MYID; }
masters() { printf '%s\n' "$CN" | awk '$3 ~ /master/ && $3 !~ /fail/ && NF >= 9 { split($2, b, ":"); print b[1] }' | ip2n | sort -n | tr '\n' ' '; }
replica_of() { local mid; mid="$(id_of "$1")"; printf '%s\n' "$CN" | awk -v m="$mid" '$4 == m { split($2, b, ":"); print b[1] }' | ip2n | head -1; }
slot_of() { printf '%s\n' "$KEYMAP" | awk -v k="$1" '$1 == k { print $2 }'; }
owner_of_key() { printf '%s\n' "$KEYMAP" | awk -v k="$1" '$1 == k { print $3 }'; }
# key_on <노드> [제외할 슬롯] [건너뛸 개수]: 그 마스터가 가진 슬롯의 키 하나
key_on() { printf '%s\n' "$KEYMAP" | awk -v n="$1" -v ex="${2:--1}" -v skip="${3:-0}" '$3 == n && $2 != ex { if (skip-- <= 0) { print $1; exit } }'; }

# 노드별 라이브러리 목록 표. 지문은 라이브러리별 코드(library_code)만 뽑아 라이브러리 이름순으로 이어 붙인 sha1 앞 12자리.
# FUNCTION LIST 의 라이브러리·함수 순서는 노드마다 달라서 출력을 그대로 해시하면 코드가 같아도 값이 다르다.
libs_of() { r "$1" FUNCTION LIST | awk 'p == "library_name" { print } { p = $0 }' | sort | tr '\n' ' '; }
libs_digest() {
  r "$1" FUNCTION LIST WITHCODE \
    | awk '$0 == "library_name" { getline; name = $0; incode = 0; next } $0 == "library_code" { incode = 1; next } incode { print name "\t" $0 }' \
    | sort -s -t "$(printf '\t')" -k1,1 | sha1sum | cut -c1-12
}
libs_table() {
  local n
  printf '| node | role | libraries | 코드 지문 |\n'
  for n in $ALL_NODES; do
    docker inspect "$(cname "$n")" >/dev/null 2>&1 || continue
    printf '| n%s | %s | %s | %s |\n' "$n" "$(role_of "$n")" "$(libs_of "$n")" \
      "$(libs_digest "$n")"
  done
}
scripts_table() {
  local n
  printf '| node | role | SCRIPT EXISTS %s |\n' "$*"
  for n in $ALL_NODES; do
    docker inspect "$(cname "$n")" >/dev/null 2>&1 || continue
    printf '| n%s | %s | %s |\n' "$n" "$(role_of "$n")" "$(r "$n" SCRIPT EXISTS "$@" | tr '\n' ' ')"
  done
}

# ---------- 준비 ----------
echo "# 7-cluster-functions  $(date '+%Y-%m-%d %H:%M:%S')  image=$IMAGE  node-timeout=${NODE_TIMEOUT}ms"
section "준비: 이전 rlab-cluster 리소스를 지우고 마스터 3 + 레플리카 3 클러스터 생성"
cleanup
docker network create --subnet "$SUBNET_PREFIX.0/24" "$NET" >/dev/null
for n in 1 2 3 4 5 6; do start_node "$n"; done
CREATE_ARGS=""
for n in 1 2 3 4 5 6; do CREATE_ARGS="$CREATE_ARGS $(ipof "$n"):6379"; done
echo "> redis-cli --cluster create$CREATE_ARGS --cluster-replicas 1 --cluster-yes"
docker exec "$(cname 1)" redis-cli --cluster create $CREATE_ARGS --cluster-replicas 1 --cluster-yes | tr -d '\r' | grep -vE '^\.*$'
wait_cluster_ok 1 2 3 4 5 6
r 1 INFO server | grep -E '^redis_version'

# 키 k:1..k:400의 슬롯을 한 번에 구한다 (컨테이너 안 루프라 가볍다).
KEYTAB="$(rsh 1 'for i in $(seq 1 400); do echo "k:$i $(redis-cli CLUSTER KEYSLOT k:$i)"; done')"
refresh_topology
printf '%s\n' "$CN" | sort -k2
read -r M1 M2 M3 <<< "$(masters)"
R1="$(replica_of "$M1")"; R2="$(replica_of "$M2")"; R3="$(replica_of "$M3")"
echo "masters: n$M1 n$M2 n$M3 / replicas: n$R1(of n$M1) n$R2(of n$M2) n$R3(of n$M3)"

K1="$(key_on "$M1")"; K2="$(key_on "$M2")"; K3="$(key_on "$M3")"
echo "keys: $K1(slot $(slot_of "$K1"), n$M1) $K2(slot $(slot_of "$K2"), n$M2) $K3(slot $(slot_of "$K3"), n$M3)"

# ---------- 질문 1 ----------
section "Q1-a. 마스터 한 곳(n$M1)에만 FUNCTION LOAD"
showsh "$M1" 'redis-cli FUNCTION LOAD "$(cat /lab/clusterlib.lua)"' 'redis-cli FUNCTION LOAD "$(cat /lab/clusterlib.lua)"'
show "$M1" WAIT 1 2000
libs_table

section "Q1-b. redis-cli --cluster call 로 모든 노드(레플리카 포함)에 FUNCTION LOAD"
ccall "$M1" 'FUNCTION LOAD REPLACE "$(cat /lab/ratelimit-lib.lua)"'
show "$M1" WAIT 1 2000
libs_table

section "Q1-c. --cluster-only-masters 로 모든 마스터에 FUNCTION LOAD (문서 권장 방식)"
ccall "$M1" 'FUNCTION LOAD REPLACE "$(cat /lab/clusterlib.lua)"' --cluster-only-masters
for m in $M1 $M2 $M3; do r "$m" WAIT 1 2000 >/dev/null; done
libs_table

section "Q1-d. --cluster call 은 노드마다 따로 실행된다: 일부만 실패해도 나머지는 반영"
echo "n$M1 에만 dup_a(함수 dup_fn)를 올려 두고, 같은 함수 이름을 쓰는 dup_b 를 모든 마스터에 올린다"
showsh "$M1" 'redis-cli FUNCTION LOAD "$(cat /lab/dup-a.lua)"' 'redis-cli FUNCTION LOAD "$(cat /lab/dup-a.lua)"'
ccall "$M1" 'FUNCTION LOAD "$(cat /lab/dup-b.lua)"' --cluster-only-masters
for m in $M1 $M2 $M3; do r "$m" WAIT 1 2000 >/dev/null; done
libs_table
echo "-- 정리"
ccall "$M1" 'FUNCTION DELETE dup_a' --cluster-only-masters
ccall "$M1" 'FUNCTION DELETE dup_b' --cluster-only-masters
for m in $M1 $M2 $M3; do r "$m" WAIT 1 2000 >/dev/null; done
libs_table

# ---------- 질문 2 ----------
section "Q2-a. FCALL 키 1개: 슬롯 주인이 아닌 노드로 보내면 MOVED, -c 면 따라감"
show "$M1" FCALL hit 1 "$K2"
showc "$M1" FCALL hit 1 "$K2"
show "$R2" FCALL hit 1 "$K2"
show "$R2" FCALL_RO cpeek 1 "$K2"
showsh "$R2" "redis-cli (같은 연결에서 READONLY 후) FCALL_RO cpeek 1 $K2" "printf 'READONLY\nFCALL_RO cpeek 1 $K2\n' | redis-cli"

section "Q2-b. 서로 다른 슬롯의 키 2개 → CROSSSLOT"
K1B="$(key_on "$M1" "$(slot_of "$K1")")"
echo "같은 마스터 n$M1의 다른 슬롯 키: $K1(slot $(slot_of "$K1")), $K1B(slot $(slot_of "$K1B"))"
show "$M1" FCALL hit2 2 "$K1" "$K2"
showc "$M1" FCALL hit2 2 "$K1" "$K2"
show "$M1" FCALL hit2 2 "$K1" "$K1B"

section "Q2-c. 해시 태그로 같은 슬롯에 모으면 동작"
r "$M1" CLUSTER KEYSLOT "{order:42}:stock" | sed 's/^/slot {order:42}:stock = /'
r "$M1" CLUSTER KEYSLOT "{order:42}:coupon" | sed 's/^/slot {order:42}:coupon = /'
showc "$M1" FCALL hit2 2 "{order:42}:stock" "{order:42}:coupon"

section "Q2-d. 키 0개: 보낸 노드에서 그대로 실행"
for n in $M1 $M2 $M3 $R1; do echo "n$n id=$(id_of "$n")"; done
show "$M1" FCALL whoami 0
show "$M2" FCALL whoami 0
showc "$M3" FCALL whoami 0
show "$R1" FCALL whoami 0
show "$R1" FCALL whoami_rw 0
echo "-- 키 0개로 선언하고 함수 안에서 키를 쓰면: 그 노드 소유 슬롯이면 동작, 아니면 에러"
show "$M1" FCALL write_nokey 0 "$K1"
show "$M1" FCALL write_nokey 0 "$K2"
showc "$M1" FCALL write_nokey 0 "$K2"

section "Q2-e. 슬롯 이동 중(MIGRATING/IMPORTING): ASK와 TRYAGAIN"
KA="$(key_on "$M1" -1 5)"; SA="$(slot_of "$KA")"
echo "슬롯 $SA(키 $KA, n$M1 소유)를 n$M2로 옮기는 중인 상태를 손으로 만든다"
show "$M1" SET "{$KA}:present" 1
show "$M2" CLUSTER SETSLOT "$SA" IMPORTING "$(id_of "$M1")"
show "$M1" CLUSTER SETSLOT "$SA" MIGRATING "$(id_of "$M2")"
show "$M1" FCALL cpeek 1 "{$KA}:missing"
showc "$M1" FCALL cpeek 1 "{$KA}:missing"
show "$M1" FCALL cpeek 1 "{$KA}:present"
show "$M1" FCALL hit2 2 "{$KA}:present" "{$KA}:missing"
show "$M2" FCALL cpeek 1 "{$KA}:missing"
echo "-- 되돌림"
show "$M1" CLUSTER SETSLOT "$SA" STABLE
show "$M2" CLUSTER SETSLOT "$SA" STABLE
show "$M1" DEL "{$KA}:present"

# ---------- 질문 3 ----------
section "Q3-a. SCRIPT LOAD는 보낸 노드에만 (복제 안 됨)"
SHA="$(rsh "$M1" 'redis-cli SCRIPT LOAD "$(cat /lab/hit.lua)"')"
echo "> [$(label "$M1")] redis-cli SCRIPT LOAD \"\$(cat /lab/hit.lua)\"  → $SHA"
scripts_table "$SHA"
show "$M1" EVALSHA "$SHA" 1 "$K1"
show "$M1" EVALSHA "$SHA" 1 "$K2"
showc "$M1" EVALSHA "$SHA" 1 "$K2"

section "Q3-b. EVAL 키 슬롯 규칙: CROSSSLOT, 해시 태그"
show "$M1" EVAL "return {redis.call('INCR', KEYS[1]), redis.call('INCR', KEYS[2])}" 2 "$K1" "$K1B"
showc "$M1" EVAL "return {redis.call('INCR', KEYS[1]), redis.call('INCR', KEYS[2])}" 2 "{order:42}:stock" "{order:42}:coupon"

section "Q3-c. 선언하지 않은 키 건드리기 (선언 키 $K1 은 n$M1)"
echo "같은 노드 다른 슬롯 키: $K1B(slot $(slot_of "$K1B")) / 다른 노드 키: $K2(slot $(slot_of "$K2"), n$M2)"
for f in touch-other touch-other-shebang touch-other-xslot; do
  showsh "$M1" "EVAL \"\$(cat /lab/$f.lua)\" 1 $K1 $K1B   # 같은 노드, 다른 슬롯" \
    "redis-cli EVAL \"\$(cat /lab/$f.lua)\" 1 $K1 $K1B"
  showsh "$M1" "EVAL \"\$(cat /lab/$f.lua)\" 1 $K1 $K2    # 다른 노드" \
    "redis-cli EVAL \"\$(cat /lab/$f.lua)\" 1 $K1 $K2"
done
echo "-- 같은 확인을 Function으로 (touch_other: 플래그 없음, touch_other_x: allow-cross-slot-keys)"
show "$M1" FCALL touch_other 1 "$K1" "$K1B"
show "$M1" FCALL touch_other 1 "$K1" "$K2"
show "$M1" FCALL touch_other_x 1 "$K1" "$K1B"
show "$M1" FCALL touch_other_x 1 "$K1" "$K2"

section "Q3-d. 스크립트를 모든 노드에 올리기: --cluster call SCRIPT LOAD (레플리카 포함)"
echo "-- 본문이 '--' 주석으로 시작하면 redis-cli 가 옵션으로 읽어 거부한다 (touch-other.lua 첫 줄이 주석)"
ccall "$M1" 'SCRIPT LOAD "$(cat /lab/touch-other.lua)"'
echo "-- hit.lua 는 첫 줄이 코드라 통과한다"
ccall "$M1" 'SCRIPT LOAD "$(cat /lab/hit.lua)"'
SHA_ONCE="$(rsh "$M1" 'redis-cli SCRIPT LOAD "$(cat /lab/hit-once.lua)"')"
echo "hit-once.lua 는 n$M1 에만 올림 → $SHA_ONCE"
scripts_table "$SHA" "$SHA_ONCE"
showc "$M1" EVALSHA "$SHA" 1 "$K2"
echo "-- NOSCRIPT 뒤 EVAL로 보내면 그 노드 캐시에 남는다(클라이언트 라이브러리의 EVALSHA→EVAL 대체와 같은 흐름)"
show "$M2" EVAL "$(cat "$LAB_DIR/cluster/hit-once.lua")" 1 "$K2"
show "$M2" SCRIPT EXISTS "$SHA_ONCE"
show "$M2" SCRIPT FLUSH
rsh "$M2" 'redis-cli SCRIPT LOAD "$(cat /lab/hit.lua)"' >/dev/null   # 다음 단계 비교를 위해 hit.lua 만 다시 올려 둔다

# ---------- 질문 4 ----------
section "Q4-a. 수동 장애 조치: 레플리카 n$R1 에서 CLUSTER FAILOVER"
show "$M1" FCALL hit 1 "$K1"
show "$M1" WAIT 1 2000
echo "장애 조치 전"
libs_table
scripts_table "$SHA" "$SHA_ONCE"
show "$R1" CLUSTER FAILOVER
for _ in $(seq 1 100); do [ "$(r "$R1" ROLE | head -1)" = "master" ] && break; sleep 0.2; done
wait_cluster_ok 1 2 3 4 5 6
sleep 1
refresh_topology
echo "장애 조치 뒤: n$R1 role=$(role_of "$R1"), n$M1 role=$(role_of "$M1")"
libs_table
scripts_table "$SHA" "$SHA_ONCE"
echo "-- 옛 마스터 n$M1 이 새 마스터에 다시 붙은 방식 (새 마스터 쪽 INFO stats: full=전체 동기화 횟수, partial_ok=부분 동기화 성공 횟수)"
r "$M1" INFO replication | grep -E '^(role|master_host|master_link_status)'
r "$R1" INFO stats | grep -E '^sync_(full|partial_ok)' | sed 's/^/n'"$R1"' /'
showc "$M1" FCALL hit 1 "$K1"
showc "$M1" EVALSHA "$SHA" 1 "$K1"
showc "$M1" EVALSHA "$SHA_ONCE" 1 "$K1"

section "Q4-b. 새 마스터 n$R1 강제 종료 후 시작 (AOF 켬, SIGKILL이라 종료 시 저장 없음)"
show "$R1" CONFIG GET appendonly
show "$R1" CONFIG GET cluster-node-timeout
QN="$M2"
echo "> docker kill $(cname "$R1") && docker start $(cname "$R1")"
docker kill "$(cname "$R1")" >/dev/null
docker start "$(cname "$R1")" >/dev/null
wait_ping "$R1"
wait_cluster_ok 1 2 3 4 5 6
refresh_topology
echo "시작 뒤 n$R1 role=$(role_of "$R1") (node-timeout 안에 돌아와 장애 조치가 일어나지 않았는지 확인)"
docker logs "$(cname "$R1")" 2>&1 | tr -d '\r' | grep -E 'DB loaded from|Done loading RDB' | tail -3
libs_table
scripts_table "$SHA" "$SHA_ONCE"
showc "$M2" FCALL hit 1 "$K1"
showc "$M2" EVALSHA "$SHA" 1 "$K1"
QN=1

# ---------- 질문 5 ----------
section "Q5-a. 새 노드 n7 추가: --cluster add-node"
start_node 7
echo "-- 먼저 n7 에 라이브러리가 있는 채로 add-node"
showsh 7 'redis-cli FUNCTION LOAD "$(cat /lab/only7.lua)"' 'redis-cli FUNCTION LOAD "$(cat /lab/only7.lua)"'
echo "> redis-cli --cluster add-node $(ipof 7):6379 $(ipof "$M2"):6379"
docker exec "$(cname "$M2")" redis-cli --cluster add-node "$(ipof 7):6379" "$(ipof "$M2"):6379" 2>&1 | tr -d '\r' | grep -E '^(>>>|\[ERR\]|\[OK\]|\*\*\*)' || true
echo "n7 cluster_known_nodes: $(r 7 CLUSTER INFO | awk -F: '/^cluster_known_nodes/{print $2}')"
echo "-- 비운 뒤 다시 add-node"
show 7 FUNCTION FLUSH
echo "> redis-cli --cluster add-node $(ipof 7):6379 $(ipof "$M2"):6379"
docker exec "$(cname "$M2")" redis-cli --cluster add-node "$(ipof 7):6379" "$(ipof "$M2"):6379" 2>&1 | tr -d '\r' | grep -E '^(>>>|\[ERR\]|\[OK\]|\*\*\*)' || true
wait_cluster_ok 1 2 3 4 5 6 7
refresh_topology
libs_table

section "Q5-b. 예전 방식 슬롯 이동(SETSLOT + MIGRATE): 함수는 따라가지 않는다"
SRC="$M2"
show 7 FUNCTION FLUSH
KL="$(key_on "$SRC" -1 3)"; SL="$(slot_of "$KL")"
echo "슬롯 $SL(키 $KL)을 n$SRC → n7 로 손으로 옮긴다"
show "$SRC" SET "$KL" legacy
show 7 CLUSTER SETSLOT "$SL" IMPORTING "$(id_of "$SRC")"
show "$SRC" CLUSTER SETSLOT "$SL" MIGRATING "$(id_of 7)"
show "$SRC" MIGRATE "$(ipof 7)" 6379 "" 0 5000 KEYS "$KL"
for m in 7 $(masters); do r "$m" CLUSTER SETSLOT "$SL" NODE "$(id_of 7)" >/dev/null; done
echo "> 모든 마스터에 CLUSTER SETSLOT $SL NODE <n7 id>"
wait_cluster_ok 1 2 3 4 5 6 7
refresh_topology
echo "키 $KL 소유: n$(owner_of_key "$KL")"
libs_table
showc "$SRC" GET "$KL"
showc "$SRC" FCALL hit 1 "$KL"

section "Q5-c. redis-cli --cluster reshard (Redis 8.4+ 원자적 슬롯 이동 ASM): 함수가 따라가는가"
echo "-- n7 에는 only7 만 있고 clab/ratelimit 은 없는 상태에서 시작"
showsh 7 'redis-cli FUNCTION LOAD "$(cat /lab/only7.lua)"' 'redis-cli FUNCTION LOAD "$(cat /lab/only7.lua)"'
libs_table
echo "옮기기 전 n$SRC 의 키 몇 개에 FCALL hit (n$SRC 소유 슬롯 앞쪽부터)"
MOVE_KEYS="$(printf '%s\n' "$KEYMAP" | awk -v n="$SRC" '$3 == n' | sort -k2 -n | head -6 | awk '{print $1}' | tr '\n' ' ')"
for k in $MOVE_KEYS; do printf '%s slot %s → ' "$k" "$(slot_of "$k")"; r "$SRC" -c FCALL hit 1 "$k" | head -1; done
echo "> redis-cli --cluster reshard $(ipof "$SRC"):6379 --cluster-from <n$SRC id> --cluster-to <n7 id> --cluster-slots 200 --cluster-yes"
docker exec "$(cname "$SRC")" redis-cli --cluster reshard "$(ipof "$SRC"):6379" \
  --cluster-from "$(id_of "$SRC")" --cluster-to "$(id_of 7)" --cluster-slots 200 --cluster-yes \
  | tr -d '\r' | grep -E '^(Moving [0-9]+ slots|Waiting for migration task)' || true
wait_cluster_ok 1 2 3 4 5 6 7
refresh_topology
echo "-- n7 쪽 이동 작업 기록 (CLUSTER MIGRATION STATUS ALL 의 operation/state)"
r 7 CLUSTER MIGRATION STATUS ALL | awk 'p == "operation" || p == "state" || p == "slots" { printf "%s=%s ", p, $0 } p == "write_pause_ms" { print "" } { p = $0 }'
docker logs "$(cname 7)" 2>&1 | tr -d '\r' | grep -E 'Import task .* (started|completed)' | tail -2
libs_table
MOVED_KEY=""
for k in $MOVE_KEYS; do [ "$(owner_of_key "$k")" = 7 ] && { MOVED_KEY="$k"; break; }; done
echo "n7 로 옮겨진 키: $MOVED_KEY (slot $(slot_of "$MOVED_KEY"))"
showc "$SRC" GET "$MOVED_KEY"
showc "$SRC" FCALL hit 1 "$MOVED_KEY"
echo "-- n7 의 clab 을 내용이 다른 판으로 바꾼 뒤 슬롯을 더 옮기면"
showsh 7 'redis-cli FUNCTION LOAD REPLACE "$(cat /lab/clab-v2.lua)"' 'redis-cli FUNCTION LOAD REPLACE "$(cat /lab/clab-v2.lua)"'
show 7 FCALL clab_v2_only 0
docker exec "$(cname "$SRC")" redis-cli --cluster reshard "$(ipof "$SRC"):6379" \
  --cluster-from "$(id_of "$SRC")" --cluster-to "$(id_of 7)" --cluster-slots 10 --cluster-yes \
  | tr -d '\r' | grep -E '^(Moving [0-9]+ slots|Waiting for migration task)' || true
wait_cluster_ok 1 2 3 4 5 6 7
refresh_topology
libs_table
show 7 FCALL clab_v2_only 0
show 7 FUNCTION DELETE only7

section "Q5-d. FUNCTION DUMP / FUNCTION RESTORE 로 복사"
echo "> [n7] redis-cli -h $(ipof "$M3") -D \"\" --raw FUNCTION DUMP > /tmp/functions.dump"
rsh 7 "redis-cli -h $(ipof "$M3") -D '' --raw FUNCTION DUMP > /tmp/functions.dump; wc -c < /tmp/functions.dump | sed 's/^/dump bytes: /'"
echo "-- 같은 이름 라이브러리가 이미 있으면 기본 정책(APPEND)은 거부, REPLACE 는 덮어씀"
showsh 7 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag < /tmp/functions.dump' 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag < /tmp/functions.dump'
showsh 7 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag REPLACE < /tmp/functions.dump' 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag REPLACE < /tmp/functions.dump'
echo "-- 빈 노드에 RESTORE"
show 7 FUNCTION FLUSH
showc "$SRC" FCALL hit 1 "$MOVED_KEY"
showsh 7 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag < /tmp/functions.dump' 'redis-cli -X dump_tag FUNCTION RESTORE dump_tag < /tmp/functions.dump'
libs_table
showc "$SRC" FCALL hit 1 "$MOVED_KEY"

# ---------- 질문 6 ----------
section "Q6. 한 마스터에서 FUNCTION DELETE / FUNCTION FLUSH"
NOW_MASTERS="$(masters)"
read -r A B C D <<< "$NOW_MASTERS"
echo "현재 마스터: $NOW_MASTERS"
show "$B" FUNCTION DELETE ratelimit
show "$C" FUNCTION FLUSH
for m in $NOW_MASTERS; do r "$m" WAIT 1 2000 >/dev/null; done
libs_table
KB="$(key_on "$B")"; KC="$(key_on "$C")"; KA2="$(key_on "$A")"
showc "$A" FCALL rate_limit 1 "$KA2" 5 60000
showc "$A" FCALL rate_limit 1 "$KB" 5 60000
showc "$A" FCALL hit 1 "$KC"
echo "-- 복구: 두 라이브러리를 모든 마스터에 다시 올린다"
for f in clusterlib.lua ratelimit-lib.lua; do
  ccall "$A" "FUNCTION LOAD REPLACE \"\$(cat /lab/$f)\"" --cluster-only-masters
done
for m in $NOW_MASTERS; do r "$m" WAIT 1 2000 >/dev/null; done
libs_table

section "마무리"
docker exec "$(cname 1)" redis-cli --cluster check "$(ipof 1):6379" | tr -d '\r' | grep -E '^\[|keys|slots' | head -12
echo "로그: $LOG"
if [ "$CLEANUP_AT_END" = 1 ]; then cleanup; echo "rlab-cluster 리소스를 지웠습니다."; fi
