-- 장애 조치 확인용으로 한 노드에만 올리는 스크립트. 본문만 hit.lua와 다르다.
return {redis.call('INCR', KEYS[1]), 'only-on-one-node'}
