-- 세션 갱신(RedisJSON 문서). Hash 버전과 같은 조건을 Lua 안에서 JSON.* 명령으로 확인한다.
-- KEYS[1]: lab:sess:j:<id>  (문서: {"state":..,"authVersion":<number>,..})
-- ARGV[1]: 기대 authVersion, ARGV[2]: lastSeenAt(ms)
-- 반환: {'UPDATED'} | {'REJECTED', 'STATE'|'VERSION'} | {'NOT_FOUND'}
-- 경로를 여러 개 주면 JSON.GET은 {"$.state":[..],"$.authVersion":[..]} 형태의 문자열을 돌려준다.
local raw = redis.call('JSON.GET', KEYS[1], '$.state', '$.authVersion')
if not raw then
  return {'NOT_FOUND'}
end
local doc = cjson.decode(raw)
local state, version = doc['$.state'][1], doc['$.authVersion'][1]
if state ~= 'ACTIVE' then
  return {'REJECTED', 'STATE'}
end
if version ~= tonumber(ARGV[1]) then
  return {'REJECTED', 'VERSION'}
end
redis.call('JSON.SET', KEYS[1], '$.lastSeenAt', ARGV[2])
return {'UPDATED'}
