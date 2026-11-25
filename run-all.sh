#!/usr/bin/env bash
# 모든 실험을 차례로 실행한다. --cleanup 을 주면 실험 7의 클러스터까지 끝난 뒤 지운다.
# 실험 6(클라이언트 분리)과 7(클러스터)은 자기 컨테이너를 따로 쓴다.
# 사용: ./run-all.sh [--cleanup]
set -euo pipefail
cd "$(dirname "$0")"
for s in run-1-session.sh run-2-dedup.sh run-3-eval-vs-function.sh run-4-busy.sh run-5-watch-vs-lua.sh; do
  echo "########## $s"
  ./"$s"
done
# 실험 6은 다른 벤치마크와 겹치지 않게 실험 1~5의 컨테이너를 지운 뒤 돌리고, 끝나면 스스로 지운다.
./cleanup.sh
echo "########## run-6-split-client.sh"
./run-6-split-client.sh up
./run-6-split-client.sh run "run-all-$(date +%H%M%S)"
./run-6-split-client.sh down
echo "########## run-7-cluster-functions.sh"
if [ "${1:-}" = "--cleanup" ]; then ./run-7-cluster-functions.sh --cleanup; else ./run-7-cluster-functions.sh; fi
echo "로그: results/raw/$(date +%Y-%m-%d)/, $(date +%Y-%m-%d)-watch/, 2026-11-25-split/, 2026-11-25-cluster/"
