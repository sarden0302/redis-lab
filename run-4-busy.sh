#!/usr/bin/env bash
# 실험 4. 오래 도는 스크립트: BUSY 응답과 SCRIPT KILL / FUNCTION KILL / SHUTDOWN NOSAVE
# 주의: 마지막 단계에서 SHUTDOWN NOSAVE로 lab 컨테이너가 한 번 멈췄다가 다시 시작된다.
source "$(dirname "$0")/lib.sh"
WAIT="${BUSY_WAIT:-1.5}"   # busy-reply-threshold(1초)보다 길게 기다린다.

ensure_lab
start_log 4-busy
reset_lab
rc_file "$LAB_DIR/lua/busy-lib.lua" FUNCTION LOAD REPLACE >/dev/null
show CONFIG SET busy-reply-threshold 1000

# 백그라운드로 긴 호출을 보내고, 끝나면 그 연결이 받은 응답을 보여 준다.
BG_OUT="$(mktemp)"
start_bg() { printf '> [백그라운드] %s\n' "$*"; ( rc "$@" > "$BG_OUT" 2>&1 || true ) & BG_PID=$!; sleep "$WAIT"; }
end_bg() { wait "$BG_PID" || true; echo "[백그라운드 응답] $(tr -d '\r' < "$BG_OUT")"; }

section "EVAL 무한 루프"
start_bg EVAL "local i = 0 while true do i = i + 1 end" 0
show PING
show FUNCTION KILL
show SCRIPT KILL
end_bg
show PING

section "FCALL 무한 루프 (함수)"
start_bg FCALL spin 0
show PING
show SCRIPT KILL
show FUNCTION KILL
end_bg
show PING

section "쓰기 뒤 무한 루프: 죽일 수 없다"
start_bg EVAL "redis.call('SET', KEYS[1], 'partial') while true do end" 1 lab:busy:w
show PING
show SCRIPT KILL
show GET lab:busy:w
echo "> SHUTDOWN NOSAVE (BUSY 중에도 허용되는 몇 안 되는 명령)"
rc SHUTDOWN NOSAVE || true
end_bg
echo "> docker start $LAB_CONTAINER"
docker start "$LAB_CONTAINER" >/dev/null
wait_ready
echo "재시작 뒤 (AOF 켬): 끝나지 못한 스크립트의 SET이 남았는지 확인"
show GET lab:busy:w
show FUNCTION LIST LIBRARYNAME busy
rm -f "$BG_OUT"
rc FUNCTION DELETE busy >/dev/null
