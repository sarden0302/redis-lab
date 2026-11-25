# 실험 스크립트 공통 함수. 각 run-*.sh가 source 한다.
# 포트를 열지 않고 docker exec로만 접근한다. commerce-settle* 컨테이너·볼륨은 건드리지 않는다.

set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash가 '/data', '$.path' 같은 인자를 Windows 경로로 바꾸지 않게 한다.
export MSYS2_ARG_CONV_EXCL='*'

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_CONTAINER="${LAB_CONTAINER:-redis-lab}"
LAB_IMAGE="${LAB_IMAGE:-redis:8.10.2-alpine}"
LAB_VOLUME="${LAB_VOLUME:-redis-lab-data}"
LAB_DATE="${LAB_DATE:-$(date +%Y-%m-%d)}"
RAW_DIR="$LAB_DIR/results/raw/$LAB_DATE"
mkdir -p "$RAW_DIR"

# 벤치마크 기본값. 환경 변수로 바꿀 수 있다 (예: BENCH_N=20000 ./run-1-session.sh).
BENCH_N="${BENCH_N:-100000}"
BENCH_C="${BENCH_C:-50}"
BENCH_PIPELINES="${BENCH_PIPELINES:-1 16}"

rc() { docker exec "$LAB_CONTAINER" redis-cli "$@"; }
# 파일 내용을 마지막 인자로 넘긴다 (SCRIPT LOAD, FUNCTION LOAD REPLACE 등).
rc_file() { local f="$1"; shift; docker exec -i "$LAB_CONTAINER" redis-cli -x "$@" < "$f"; }

section() { printf '\n===== %s =====\n' "$*"; }
show() { printf '> %s\n' "$*"; rc "$@"; }   # 실행한 명령과 응답을 함께 로그에 남긴다.

wait_ready() {
  for _ in $(seq 1 50); do
    if [ "$(docker exec "$LAB_CONTAINER" redis-cli PING 2>/dev/null)" = "PONG" ]; then return 0; fi
    sleep 0.2
  done
  echo "redis-lab not ready" >&2; return 1
}

# AOF를 켠 전용 컨테이너를 준비한다. RDB 기본 save 규칙도 그대로 둔다.
ensure_lab() {
  docker volume inspect "$LAB_VOLUME" >/dev/null 2>&1 || docker volume create "$LAB_VOLUME" >/dev/null
  local status
  status="$(docker inspect -f '{{.State.Status}}' "$LAB_CONTAINER" 2>/dev/null || true)"
  case "$status" in
    running) ;;
    "") docker run -d --name "$LAB_CONTAINER" -v "$LAB_VOLUME:/data" "$LAB_IMAGE" \
          redis-server --appendonly yes >/dev/null ;;
    *) docker start "$LAB_CONTAINER" >/dev/null ;;
  esac
  wait_ready
}

# 측정 전 데이터를 비운다. 함수 라이브러리는 FLUSHALL로 지워지지 않으므로 따로 지운다.
reset_lab() {
  rc FLUSHALL >/dev/null
  rc FUNCTION FLUSH >/dev/null
  rc SCRIPT FLUSH >/dev/null
}

# bench <라벨> <pipeline> <-r 범위> <명령...>
# 결과 한 줄을 $SUMMARY(csv)에 추가한다: label,pipeline,rps,p50_ms,p99_ms
bench() {
  local label="$1" pipe="$2" range="$3"; shift 3
  local out line
  out="$(docker exec "$LAB_CONTAINER" redis-benchmark -n "$BENCH_N" -c "$BENCH_C" -P "$pipe" -r "$range" --csv "$@")"
  printf '> redis-benchmark -n %s -c %s -P %s -r %s %s\n%s\n' "$BENCH_N" "$BENCH_C" "$pipe" "$range" "$*" "$out"
  line="$(printf '%s\n' "$out" | tail -n 1 | awk -F, '{gsub(/"/,""); print $(NF-6)","$(NF-3)","$(NF-1)}')"
  [ -f "$SUMMARY" ] || echo "label,pipeline,rps,p50_ms,p99_ms" > "$SUMMARY"
  echo "$label,$pipe,$line" >> "$SUMMARY"
}

used_memory() { rc INFO memory | tr -d '\r' | awk -F: '/^used_memory:/{print $2}'; }

start_log() {
  LOG="$RAW_DIR/$1.log"
  SUMMARY="$RAW_DIR/$1-bench.csv"
  rm -f "$SUMMARY"   # bench를 처음 부를 때 헤더와 함께 만든다.
  exec > >(tee "$LOG") 2>&1
  echo "# $1  $(date '+%Y-%m-%d %H:%M:%S')  image=$LAB_IMAGE  n=$BENCH_N c=$BENCH_C"
}
