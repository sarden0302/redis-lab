-- 세션 갱신(Hash). state가 ACTIVE이고 authVersion이 기대값과 같을 때만 lastSeenAt을 쓴다.
-- KEYS[1]: lab:sess:h:<id>
-- ARGV[1]: 기대 authVersion, ARGV[2]: lastSeenAt(ms)
-- 반환: {'UPDATED'} | {'REJECTED', 'STATE'|'VERSION'} | {'NOT_FOUND'}
local cur = redis.call('HMGET', KEYS[1], 'state', 'authVersion')
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
redis.call('HSET', KEYS[1], 'lastSeenAt', ARGV[2])
return {'UPDATED'}
