#!/usr/bin/env bash
# 실험 6. 벤치마크 클라이언트를 별도 컨테이너로 분리해 실험 1~3 처리량만 다시 잰다.
# 1차 측정(서버·클라이언트가 한 컨테이너)의 숫자가 CPU 공유로 왜곡됐는지 확인한다.
# 사용:
#   ./run-6-split-client.sh up            # 네트워크·서버·클라이언트 컨테이너 생성
#   ./run-6-split-client.sh run <이름>    # 실험 1~3 처리량 1회 (로그: results/raw/2026-11-25-split/<이름>.log)
#   ./run-6-split-client.sh down          # 컨테이너·네트워크 삭제
# 이름·CPU 제한은 환경 변수로 바꿀 수 있다. lib.sh는 읽기만 한다(rc, rc_file, MSYS 설정).
export LAB_CONTAINER="${SPLIT_SERVER:-rlab-split-server}"
export LAB_DATE="${LAB_DATE:-2026-11-25-split}"
source "$(dirname "$0")/lib.sh"

SPLIT_NET="${SPLIT_NET:-rlab-split-net}"
SPLIT_CLIENT="${SPLIT_CLIENT:-rlab-split-client}"
SERVER_CPUS="${SERVER_CPUS:-2}"
CLIENT_CPUS="${CLIENT_CPUS:-2}"

up() {
  docker network inspect "$SPLIT_NET" >/dev/null 2>&1 || docker network create "$SPLIT_NET" >/dev/null
  # 1차와 같게 AOF를 켠다. 볼륨 대신 이미지의 익명 /data 볼륨을 쓰고 down에서 같이 지운다. 포트는 열지 않는다.
  docker run -d --name "$LAB_CONTAINER" --network "$SPLIT_NET" --cpus="$SERVER_CPUS" "$LAB_IMAGE" \
    redis-server --appendonly yes >/dev/null
  docker run -d --name "$SPLIT_CLIENT" --network "$SPLIT_NET" --cpus="$CLIENT_CPUS" "$LAB_IMAGE" \
    sleep infinity >/dev/null
  wait_ready
}

down() {
  docker rm -f -v "$LAB_CONTAINER" "$SPLIT_CLIENT" >/dev/null 2>&1 || true
  docker network rm "$SPLIT_NET" >/dev/null 2>&1 || true
}

# bench <실험> <라벨> <pipeline> <-r 범위> <명령...> : 클라이언트 컨테이너에서 서버로 접속해 잰다.
bench() {
  local exp="$1" label="$2" pipe="$3" range="$4"; shift 4
  local out line
  out="$(docker exec "$SPLIT_CLIENT" redis-benchmark -h "$LAB_CONTAINER" -n "$BENCH_N" -c "$BENCH_C" -P "$pipe" -r "$range" --csv "$@")"
  printf '> redis-benchmark -h %s -n %s -c %s -P %s -r %s %s\n%s\n' "$LAB_CONTAINER" "$BENCH_N" "$BENCH_C" "$pipe" "$range" "$*" "$out"
  line="$(printf '%s\n' "$out" | tail -n 1 | awk -F, '{gsub(/"/,""); print $(NF-6)","$(NF-3)","$(NF-1)}')"
  echo "$exp,$label,$pipe,$line" >> "$SUMMARY"
}

run() {
  local name="$1"
  LOG="$RAW_DIR/$name.log"; SUMMARY="$RAW_DIR/$name-bench.csv"
  echo "exp,label,pipeline,rps,p50_ms,p99_ms" > "$SUMMARY"
  exec > >(tee "$LOG") 2>&1
  echo "# split-client $name  $(date '+%Y-%m-%d %H:%M:%S')  image=$LAB_IMAGE  n=$BENCH_N c=$BENCH_C"
  echo "# server=$LAB_CONTAINER cpus=$SERVER_CPUS  client=$SPLIT_CLIENT cpus=$CLIENT_CPUS  network=$SPLIT_NET"
  echo "# 실행 중인 컨테이너:"; docker ps --format '#   {{.Names}}'

  # 실험 1: 세션 1만 개 (Hash, JSON, 감싼 JSON)
  local N="${SESSION_N:-10000}" FILTER='$[?(@.state=="ACTIVE" && @.authVersion==3)]' NOW=1764000999000
  section "실험 1 준비"
  reset_lab
  local SHA_H SHA_J SEED
  SHA_H="$(rc_file "$LAB_DIR/lua/session-touch-hash.lua" SCRIPT LOAD | tr -d '\r')"
  SHA_J="$(rc_file "$LAB_DIR/lua/session-touch-json.lua" SCRIPT LOAD | tr -d '\r')"
  SEED="$(rc_file "$LAB_DIR/lua/seed-sessions.lua" SCRIPT LOAD | tr -d '\r')"
  for kind in hash json jsonw; do rc EVALSHA "$SEED" 0 "$N" "$kind" >/dev/null; done
  rc DBSIZE
  section "실험 1 처리량"
  for P in $BENCH_PIPELINES; do
    bench 1 hash-lua "$P" "$N" EVALSHA "$SHA_H" 1 lab:sess:h:__rand_int__ 3 "$NOW"
    bench 1 json-lua "$P" "$N" EVALSHA "$SHA_J" 1 lab:sess:j:__rand_int__ 3 "$NOW"
    bench 1 json-filter-merge "$P" "$N" JSON.MERGE lab:sess:jw:__rand_int__ "$FILTER" "{\"lastSeenAt\":$NOW}"
    bench 1 base-hset "$P" "$N" HSET lab:sess:h:__rand_int__ lastSeenAt "$NOW"
    bench 1 base-json-set "$P" "$N" JSON.SET lab:sess:j:__rand_int__ '$.lastSeenAt' "$NOW"
  done

  # 실험 2: 요청 ID 100만 개를 Set·Bloom·Cuckoo에 적재
  local DN="${DEDUP_N:-1000000}" BULK
  section "실험 2 준비"
  reset_lab
  BULK="$(rc_file "$LAB_DIR/lua/dedup-bulk.lua" SCRIPT LOAD | tr -d '\r')"
  rc BF.RESERVE lab:dup:bf 0.001 "$DN" >/dev/null
  rc CF.RESERVE lab:dup:cf "$DN" >/dev/null
  for kind in set bf cf; do rc EVALSHA "$BULK" 1 "lab:dup:$kind" "$kind" add req- "$DN" >/dev/null; done
  rc BF.RESERVE lab:dup:bench:bf 0.001 "$DN" >/dev/null
  rc SCARD lab:dup:set
  section "실험 2 처리량"
  for P in $BENCH_PIPELINES; do
    bench 2 sadd "$P" "$DN" SADD lab:dup:bench:set req-__rand_int__
    bench 2 bf.add "$P" "$DN" BF.ADD lab:dup:bench:bf req-__rand_int__
    bench 2 sismember "$P" "$DN" SISMEMBER lab:dup:set req-__rand_int__
    bench 2 bf.exists "$P" "$DN" BF.EXISTS lab:dup:bf req-__rand_int__
    bench 2 cf.exists "$P" "$DN" CF.EXISTS lab:dup:cf req-__rand_int__
  done

  # 실험 3: 같은 요청 제한 로직 EVAL / EVALSHA / FCALL
  local WINDOW=60000 SHA BODY
  section "실험 3 준비"
  reset_lab
  SHA="$(rc_file "$LAB_DIR/lua/rate-limit.lua" SCRIPT LOAD | tr -d '\r')"
  rc_file "$LAB_DIR/lua/ratelimit-lib.lua" FUNCTION LOAD REPLACE >/dev/null
  BODY="$(grep -vE '^\s*--' "$LAB_DIR/lua/rate-limit.lua" | tr '\n' ' ')"
  echo "EVAL 본문 크기: ${#BODY}바이트"
  section "실험 3 처리량"
  for P in $BENCH_PIPELINES; do
    bench 3 eval-body "$P" 100000 EVAL "$BODY" 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
    bench 3 evalsha "$P" 100000 EVALSHA "$SHA" 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
    bench 3 fcall "$P" 100000 FCALL rate_limit 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
    bench 3 base-incr "$P" 100000 INCR lab:rl:b:__rand_int__
  done

  section "요약 (exp,label,pipeline,rps,p50_ms,p99_ms)"
  cat "$SUMMARY"
}

case "${1:-}" in
  up) up ;;
  run) run "${2:?run <이름>}" ;;
  down) down ;;
  *) echo "사용: $0 up | run <이름> | down" >&2; exit 2 ;;
esac
