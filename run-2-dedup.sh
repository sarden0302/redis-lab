#!/usr/bin/env bash
# 실험 2. 중복 요청 감지: Set vs Bloom filter (+ Cuckoo filter 참고)
source "$(dirname "$0")/lib.sh"
N="${DEDUP_N:-1000000}"
MISS_N="${DEDUP_MISS_N:-100000}"
ERR_RATE=0.001

ensure_lab
start_log 2-dedup
reset_lab
BULK="$(rc_file "$LAB_DIR/lua/dedup-bulk.lua" SCRIPT LOAD | tr -d '\r')"

ms() { date +%s%3N; }

section "적재: 요청 ID ${N}개 (Lua 루프 한 번, 서버 안 처리 시간)"
# Bloom/Cuckoo는 RESERVE 때 메모리를 미리 잡으므로 RESERVE 전부터 잰다.
for kind in set bf cf; do
  before="$(used_memory)"; t0="$(ms)"
  case "$kind" in
    bf) show BF.RESERVE lab:dup:bf "$ERR_RATE" "$N" ;;
    cf) show CF.RESERVE lab:dup:cf "$N" ;;
  esac
  added="$(rc EVALSHA "$BULK" 1 "lab:dup:$kind" "$kind" add req- "$N" | tr -d '\r')"
  t1="$(ms)"; after="$(used_memory)"
  echo "$kind: 새로 추가=$added / $N, 소요=$((t1 - t0))ms, used_memory 증가=$((after - before))B"
done

section "메모리"
show MEMORY USAGE lab:dup:set SAMPLES 0
show OBJECT ENCODING lab:dup:set
show MEMORY USAGE lab:dup:bf
show BF.INFO lab:dup:bf
show MEMORY USAGE lab:dup:cf
show CF.INFO lab:dup:cf

section "중복 판정: 이미 넣은 ID를 다시 넣기"
show SADD lab:dup:set req-000000000005
show BF.ADD lab:dup:bf req-000000000005
show CF.ADDNX lab:dup:cf req-000000000005

section "거짓 양성: 넣지 않은 ID ${MISS_N}개 조회"
for kind in set bf cf; do
  fp="$(rc EVALSHA "$BULK" 1 "lab:dup:$kind" "$kind" exists miss- "$MISS_N" | tr -d '\r')"
  awk -v k="$kind" -v fp="$fp" -v n="$MISS_N" 'BEGIN{printf "%s: 있다고 답한 수=%d / %d, 거짓 양성률=%.4f%%\n", k, fp, n, fp*100/n}'
done
echo "(참고) 넣은 ID ${MISS_N}개 조회. 거짓 음성은 없어야 한다."
for kind in set bf cf; do
  hit="$(rc EVALSHA "$BULK" 1 "lab:dup:$kind" "$kind" exists req- "$MISS_N" | tr -d '\r')"
  echo "$kind: 있다고 답한 수=$hit / $MISS_N"
done

section "삭제"
show SREM lab:dup:set req-000000000005
show BF.DEL lab:dup:bf req-000000000005
echo "--- CF.ADD는 같은 항목을 또 넣는다. 두 번 들어간 항목은 두 번 지워야 사라진다"
show CF.ADD lab:dup:cf req-000000000006
show CF.DEL lab:dup:cf req-000000000006
show CF.EXISTS lab:dup:cf req-000000000006
show CF.DEL lab:dup:cf req-000000000006
show CF.EXISTS lab:dup:cf req-000000000006

section "처리량"
# 추가: 빈 키에 무작위 ID(최대 N종). 조회: 적재한 키에서 무작위 ID(모두 존재).
rc BF.RESERVE lab:dup:bench:bf "$ERR_RATE" "$N" >/dev/null
for P in $BENCH_PIPELINES; do
  bench sadd "$P" "$N" SADD lab:dup:bench:set req-__rand_int__
  bench bf.add "$P" "$N" BF.ADD lab:dup:bench:bf req-__rand_int__
  bench sismember "$P" "$N" SISMEMBER lab:dup:set req-__rand_int__
  bench bf.exists "$P" "$N" BF.EXISTS lab:dup:bf req-__rand_int__
  bench cf.exists "$P" "$N" CF.EXISTS lab:dup:cf req-__rand_int__
done

section "요약 (label,pipeline,rps,p50_ms,p99_ms)"
cat "$SUMMARY"
