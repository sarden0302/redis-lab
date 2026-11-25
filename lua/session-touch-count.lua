-- 실험 5용 세션 갱신(Hash). session-touch-hash.lua와 조건·반환이 같고, 갱신 횟수 touches를 하나 더 쓴다.
-- touches는 읽은 값 + 1을 다시 쓴다. WATCH 방식과 같은 "읽고 판단하고 쓰기"를 하고, 잃어버린 갱신이 있으면 합계로 드러난다.
-- KEYS[1]: 세션 키, ARGV[1]: 기대 authVersion, ARGV[2]: lastSeenAt(ms)
-- 반환: {'UPDATED'} | {'REJECTED', 'STATE'|'VERSION'} | {'NOT_FOUND'}
local cur = redis.call('HMGET', KEYS[1], 'state', 'authVersion', 'touches')
local state, version = cur[1], cur[2]
if not state then
  return {'NOT_FOUND'}
end
if state ~= 'ACTIVE' then
  return {'REJECTED', 'STATE'}
end
if version ~= ARGV[1] then
  return {'REJECTED', 'VERSION'}
end
redis.call('HSET', KEYS[1], 'lastSeenAt', ARGV[2], 'touches', (tonumber(cur[3]) or 0) + 1)
return {'UPDATED'}
