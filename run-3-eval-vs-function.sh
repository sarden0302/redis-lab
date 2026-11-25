#!/usr/bin/env bash
# 실험 3. 같은 요청 제한 로직: EVAL/EVALSHA vs FUNCTION/FCALL
# 처리량, SCRIPT FLUSH·FLUSHALL·재시작 뒤 생존 여부, ACL 차이를 본다.
source "$(dirname "$0")/lib.sh"
LIMIT=5
WINDOW=60000

ensure_lab
start_log 3-eval-vs-function
reset_lab
rc ACL DELUSER lab-ro lab-app lab-noincr lab-eval >/dev/null

load_all() {
  SHA="$(rc_file "$LAB_DIR/lua/rate-limit.lua" SCRIPT LOAD | tr -d '\r')"
  SHA_PEEK="$(rc_file "$LAB_DIR/lua/rate-peek.lua" SCRIPT LOAD | tr -d '\r')"
  rc_file "$LAB_DIR/lua/ratelimit-lib.lua" FUNCTION LOAD REPLACE >/dev/null
}
load_all
echo "rate-limit.lua sha=$SHA, rate-peek.lua sha=$SHA_PEEK"
show FUNCTION LIST LIBRARYNAME ratelimit

section "정확성: 허용 ${LIMIT}회 뒤 거절 (EVALSHA와 FCALL 결과가 같아야 한다)"
for i in 1 2 3 4 5 6; do
  e="$(rc EVALSHA "$SHA" 1 lab:rl:eval "$LIMIT" "$WINDOW" | head -1 | tr -d '\r')"
  f="$(rc FCALL rate_limit 1 lab:rl:fcall "$LIMIT" "$WINDOW" | head -1 | tr -d '\r')"
  echo "요청 $i: EVALSHA 허용=$e, FCALL 허용=$f"
done
show FCALL_RO peek 1 lab:rl:fcall
show EVALSHA_RO "$SHA_PEEK" 1 lab:rl:eval

section "처리량 (키 10만 개 중 무작위, 허용 한도를 크게 두어 항상 허용)"
# EVAL은 매번 본문을 보낸다. 주석을 빼고 한 줄로 만든 본문을 쓴다.
BODY="$(grep -vE '^\s*--' "$LAB_DIR/lua/rate-limit.lua" | tr '\n' ' ')"
echo "EVAL 본문 크기: ${#BODY}바이트"
for P in $BENCH_PIPELINES; do
  bench eval-body "$P" 100000 EVAL "$BODY" 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
  bench evalsha "$P" 100000 EVALSHA "$SHA" 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
  bench fcall "$P" 100000 FCALL rate_limit 1 lab:rl:b:__rand_int__ 1000000000 "$WINDOW"
  bench base-incr "$P" 100000 INCR lab:rl:b:__rand_int__
done

section "SCRIPT FLUSH 뒤"
show SCRIPT FLUSH
show SCRIPT EXISTS "$SHA"
show EVALSHA "$SHA" 1 lab:rl:x "$LIMIT" "$WINDOW"
show FCALL rate_limit 1 lab:rl:x "$LIMIT" "$WINDOW"

section "FLUSHALL 뒤: 데이터만 지우고 함수는 남긴다"
show FLUSHALL
show FUNCTION LIST LIBRARYNAME ratelimit
show FCALL rate_limit 1 lab:rl:x "$LIMIT" "$WINDOW"

section "재시작 뒤 (AOF 켬, 볼륨 $LAB_VOLUME)"
load_all
show CONFIG GET appendonly
show SCRIPT EXISTS "$SHA"
show BGREWRITEAOF
sleep 2
echo "> docker restart $LAB_CONTAINER"
docker restart "$LAB_CONTAINER" >/dev/null
wait_ready
show SCRIPT EXISTS "$SHA"
show EVALSHA "$SHA" 1 lab:rl:y "$LIMIT" "$WINDOW"
show FUNCTION LIST LIBRARYNAME ratelimit
show FCALL rate_limit 1 lab:rl:y "$LIMIT" "$WINDOW"
echo "> /data 내용"
docker exec "$LAB_CONTAINER" sh -c 'ls -l /data /data/appendonlydir'
load_all
rc FCALL rate_limit 1 lab:rl:fcall "$LIMIT" "$WINDOW" >/dev/null
rc EVALSHA "$SHA" 1 lab:rl:eval "$LIMIT" "$WINDOW" >/dev/null

section "읽기 전용 호출(_RO)에 쓰기 스크립트를 넣으면 (기본 사용자)"
show EVALSHA_RO "$SHA" 1 lab:rl:eval "$LIMIT" "$WINDOW"
show FCALL_RO rate_limit 1 lab:rl:fcall "$LIMIT" "$WINDOW"

section "ACL: 읽기 전용 사용자 (+evalsha_ro +fcall_ro)"
as() { local u="$1"; shift; printf '> [%s] %s\n' "$u" "$*"; docker exec "$LAB_CONTAINER" redis-cli --no-auth-warning --user "$u" --pass labpw "$@"; }
show ACL SETUSER lab-ro on '>labpw' resetkeys '~lab:rl:*' -@all +evalsha_ro +fcall_ro +get +pttl
as lab-ro EVALSHA_RO "$SHA_PEEK" 1 lab:rl:eval
as lab-ro FCALL_RO peek 1 lab:rl:fcall
as lab-ro EVALSHA_RO "$SHA" 1 lab:rl:eval "$LIMIT" "$WINDOW"
as lab-ro FCALL_RO rate_limit 1 lab:rl:fcall "$LIMIT" "$WINDOW"
as lab-ro EVALSHA "$SHA" 1 lab:rl:eval "$LIMIT" "$WINDOW"
as lab-ro FCALL rate_limit 1 lab:rl:fcall "$LIMIT" "$WINDOW"

section "ACL: 함수만 부르는 앱 사용자 (+fcall, 내부 명령 권한 포함)"
show ACL SETUSER lab-app on '>labpw' resetkeys '~lab:rl:*' -@all +fcall +incr +pexpire +pttl
as lab-app FCALL rate_limit 1 lab:rl:app "$LIMIT" "$WINDOW"
as lab-app EVAL "return 'arbitrary code'" 0
as lab-app FUNCTION LOAD REPLACE "#!lua name=evil
redis.register_function('f', function() return 1 end)"
as lab-app FCALL rate_limit 1 other:key "$LIMIT" "$WINDOW"

section "ACL: 스크립트 안 명령도 호출자 권한으로 검사한다 (+fcall, -incr)"
show ACL SETUSER lab-noincr on '>labpw' resetkeys '~lab:rl:*' -@all +fcall +pexpire +pttl
as lab-noincr FCALL rate_limit 1 lab:rl:app "$LIMIT" "$WINDOW"

section "ACL: +eval 사용자는 임의 코드를 보낼 수 있다"
show ACL SETUSER lab-eval on '>labpw' resetkeys '~lab:rl:*' -@all +eval +incr +pexpire +pttl
as lab-eval EVAL "$BODY" 1 lab:rl:eval2 "$LIMIT" "$WINDOW"
as lab-eval EVAL "local s=0 for i=1,1000 do s=s+i end return s" 0
rc ACL DELUSER lab-ro lab-app lab-noincr lab-eval >/dev/null

section "요약 (label,pipeline,rps,p50_ms,p99_ms)"
cat "$SUMMARY"
