#!/usr/bin/env bash
# lab 컨테이너·볼륨·네트워크만 지운다. 스크립트와 결과 파일은 남긴다.
set -euo pipefail
CONTAINER="${LAB_CONTAINER:-redis-lab}"
VOLUME="${LAB_VOLUME:-redis-lab-data}"
NET="${LAB_NET:-redis-lab-net}"
if docker inspect "$CONTAINER-client" >/dev/null 2>&1; then docker rm -f "$CONTAINER-client" >/dev/null && echo "removed container $CONTAINER-client"; fi
if docker inspect "$CONTAINER" >/dev/null 2>&1; then docker rm -f "$CONTAINER" >/dev/null && echo "removed container $CONTAINER"; else echo "no container $CONTAINER"; fi
docker volume rm "$VOLUME" >/dev/null 2>&1 && echo "removed volume $VOLUME" || echo "no volume $VOLUME"
docker network rm "$NET" >/dev/null 2>&1 && echo "removed network $NET" || echo "no network $NET"
