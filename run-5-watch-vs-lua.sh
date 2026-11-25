#!/usr/bin/env bash
# 실험 5. 같은 조건부 갱신: 클라이언트 낙관적 잠금(WATCH/MULTI/EXEC) vs EVALSHA vs FCALL
# 서버(redis-lab)와 클라이언트(redis-lab-client, Python 표준 라이브러리만)를 전용 네트워크의 다른 컨테이너로 돌린다.
# 포트는 열지 않는다. 클라이언트 컨테이너는 --rm으로 끝나면 사라지고, 네트워크는 cleanup.sh가 지운다.
source "$(dirname "$0")/lib.sh"
LAB_NET="${LAB_NET:-redis-lab-net}"
CLIENT_IMAGE="${CLIENT_IMAGE:-python:3.13.7-alpine}"
CLIENT_CONTAINER="${LAB_CONTAINER}-client"
W_DURATION="${W_DURATION:-5}"     # 칸 하나(전략 x 경합 x 연결 수)를 몇 초 돌릴지
W_CONNS="${W_CONNS:-1 8 32}"      # 동시 연결 수 목록
W_REPS="${W_REPS:-3}"             # 반복 횟수
W_HOT_KEYS="${W_HOT_KEYS:-1}"     # 높은 경합에서 모든 연결이 나눠 쓰는 키 수
RAW_DIR="$LAB_DIR/results/raw/${LAB_DATE}-watch"
mkdir -p "$RAW_DIR"

ensure_lab
docker network inspect "$LAB_NET" >/dev/null 2>&1 || docker network create "$LAB_NET" >/dev/null
if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$LAB_CONTAINER" | grep -q "\"$LAB_NET\""; then
  docker network connect "$LAB_NET" "$LAB_CONTAINER"
fi
start_log 5-watch-vs-lua
echo "client=$CLIENT_IMAGE network=$LAB_NET duration=${W_DURATION}s conns=[$W_CONNS] reps=$W_REPS hot_keys=$W_HOT_KEYS"
reset_lab
rc INFO server | tr -d '\r' | grep -E '^redis_version:'

# Docker Desktop(Windows)는 -v에 Windows 경로가 필요하다.
winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
client() {
  docker rm -f "$CLIENT_CONTAINER" >/dev/null 2>&1 || true
  docker run --rm --name "$CLIENT_CONTAINER" --network "$LAB_NET" -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$(winpath "$LAB_DIR"):/lab:ro" -v "$(winpath "$RAW_DIR"):/out" \
    "$CLIENT_IMAGE" python -u /lab/client/watch_bench.py --host "$LAB_CONTAINER" "$@"
}

section "단일 호출 기록 (명령과 응답)"
client transcript

section "측정 (rep,strategy,contention,conns,...)"
# shellcheck disable=SC2086
client bench --duration "$W_DURATION" --conns $W_CONNS --reps "$W_REPS" --hot-keys "$W_HOT_KEYS" \
  --out "/out/$(basename "$SUMMARY")"
echo "CSV: $SUMMARY"
