#!/usr/bin/env bash
# 실험 1. 세션 객체 저장과 조건부 갱신: Hash + Lua vs RedisJSON(+Lua / 단독)
source "$(dirname "$0")/lib.sh"
N="${SESSION_N:-10000}"
FILTER='$[?(@.state=="ACTIVE" && @.authVersion==3)]'
NOW=1764000999000

ensure_lab
start_log 1-session
reset_lab

section "코드 줄 수 (주석·빈 줄 제외)"
for f in session-touch-hash.lua session-touch-json.lua; do
  printf '%s: %s\n' "$f" "$(grep -cvE '^\s*(--|$)' "$LAB_DIR/lua/$f")"
done
echo "JSON 단독: 명령 1줄 (JSON.MERGE key '$FILTER' '{...}')"

SHA_H="$(rc_file "$LAB_DIR/lua/session-touch-hash.lua" SCRIPT LOAD | tr -d '\r')"
SHA_J="$(rc_file "$LAB_DIR/lua/session-touch-json.lua" SCRIPT LOAD | tr -d '\r')"
SEED="$(rc_file "$LAB_DIR/lua/seed-sessions.lua" SCRIPT LOAD | tr -d '\r')"
SUMMEM="$(rc_file "$LAB_DIR/lua/sum-memory.lua" SCRIPT LOAD | tr -d '\r')"

section "메모리: 같은 세션 ${N}개"
# 형태마다 빈 DB에서 따로 넣어 키 공간 dict 확장 비용이 똑같이 들어가게 한다. 스크립트 캐시는 FLUSHALL 뒤에도 남는다.
rc EVALSHA "$SEED" 0 10 hash >/dev/null   # Lua VM 워밍업
for kind in hash json jsonw; do
  rc FLUSHALL >/dev/null
  before="$(used_memory)"
  rc EVALSHA "$SEED" 0 "$N" "$kind" >/dev/null
  after="$(used_memory)"
  case "$kind" in hash) p=lab:sess:h: ;; json) p=lab:sess:j: ;; jsonw) p=lab:sess:jw: ;; esac
  sum="$(rc EVALSHA "$SUMMEM" 0 "$p" "$N" | tr -d '\r')"
  echo "$kind: MEMORY USAGE 합계=${sum}B (키당 $((sum / N))B), used_memory 증가=$((after - before))B (키당 $(((after - before) / N))B)"
done
rc EVALSHA "$SEED" 0 "$N" hash >/dev/null
rc EVALSHA "$SEED" 0 "$N" json >/dev/null
show OBJECT ENCODING lab:sess:h:000000000001
show MEMORY USAGE lab:sess:h:000000000001 SAMPLES 0
show MEMORY USAGE lab:sess:j:000000000001 SAMPLES 0
show MEMORY USAGE lab:sess:jw:000000000001 SAMPLES 0
show JSON.DEBUG MEMORY lab:sess:j:000000000001

section "정확성: 일치 / 버전 불일치 / BLOCKED / 키 없음"
rc HSET lab:sess:h:blocked state BLOCKED authVersion 3 >/dev/null
rc JSON.SET lab:sess:j:blocked '$' '{"state":"BLOCKED","authVersion":3,"lastSeenAt":0}' >/dev/null
rc JSON.SET lab:sess:jw:blocked '$' '{"s":{"state":"BLOCKED","authVersion":3,"lastSeenAt":0}}' >/dev/null
echo "--- Hash + Lua"
show EVALSHA "$SHA_H" 1 lab:sess:h:000000000001 3 "$NOW"
show EVALSHA "$SHA_H" 1 lab:sess:h:000000000001 4 "$NOW"
show EVALSHA "$SHA_H" 1 lab:sess:h:blocked 3 "$NOW"
show EVALSHA "$SHA_H" 1 lab:sess:h:nothing 3 "$NOW"
show HGET lab:sess:h:000000000001 lastSeenAt
echo "--- JSON + Lua"
show EVALSHA "$SHA_J" 1 lab:sess:j:000000000001 3 "$NOW"
show EVALSHA "$SHA_J" 1 lab:sess:j:000000000001 4 "$NOW"
show EVALSHA "$SHA_J" 1 lab:sess:j:blocked 3 "$NOW"
show EVALSHA "$SHA_J" 1 lab:sess:j:nothing 3 "$NOW"
show JSON.GET lab:sess:j:000000000001 '$.lastSeenAt'
echo "--- JSON 단독: NX/XX는 경로 존재 여부만 본다"
show JSON.SET lab:sess:j:000000000002 '$.lastSeenAt' 1 NX
show JSON.SET lab:sess:j:000000000002 '$.noSuchField' 1 XX
show JSON.SET lab:sess:j:blocked '$.lastSeenAt' 1 XX
echo "--- JSON 단독: NUMINCRBY는 조건 없이 더한다"
show JSON.NUMINCRBY lab:sess:j:blocked '$.authVersion' 1
echo "--- JSON 단독: 필터 경로. 감싸지 않은 문서는 조건이 맞아도 실패한다"
show JSON.MERGE lab:sess:j:000000000002 "$FILTER" "{\"lastSeenAt\":$NOW}"
echo "--- JSON 단독: 필터 경로 + 감싼 문서({\"s\":{...}})"
show JSON.MERGE lab:sess:jw:000000000001 "$FILTER" "{\"lastSeenAt\":$NOW,\"device\":\"web\"}"
show JSON.MERGE lab:sess:jw:000000000001 '$[?(@.state=="ACTIVE" && @.authVersion==4)]' "{\"lastSeenAt\":1}"
show JSON.MERGE lab:sess:jw:blocked "$FILTER" "{\"lastSeenAt\":1}"
show JSON.MERGE lab:sess:jw:nothing "$FILTER" "{\"lastSeenAt\":1}"
show JSON.NUMINCRBY lab:sess:jw:000000000001 "$FILTER.lastSeenAt" 1
show JSON.NUMINCRBY lab:sess:jw:blocked "$FILTER.lastSeenAt" 1
show JSON.GET lab:sess:jw:000000000001

section "처리량 (키 ${N}개 중 무작위, 조건 항상 일치)"
for P in $BENCH_PIPELINES; do
  bench hash-lua "$P" "$N" EVALSHA "$SHA_H" 1 lab:sess:h:__rand_int__ 3 "$NOW"
  bench json-lua "$P" "$N" EVALSHA "$SHA_J" 1 lab:sess:j:__rand_int__ 3 "$NOW"
  bench json-filter-merge "$P" "$N" JSON.MERGE lab:sess:jw:__rand_int__ "$FILTER" "{\"lastSeenAt\":$NOW}"
  bench base-hset "$P" "$N" HSET lab:sess:h:__rand_int__ lastSeenAt "$NOW"
  bench base-json-set "$P" "$N" JSON.SET lab:sess:j:__rand_int__ '$.lastSeenAt' "$NOW"
done

section "요약 (label,pipeline,rps,p50_ms,p99_ms)"
cat "$SUMMARY"
