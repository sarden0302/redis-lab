#!lua name=session
-- session-touch-count.lua와 같은 로직을 Redis Functions 라이브러리로 옮긴 것.
-- FCALL session_touch 1 <key> <기대 authVersion> <lastSeenAt>

local function session_touch(keys, args)
  local cur = redis.call('HMGET', keys[1], 'state', 'authVersion', 'touches')
  local state, version = cur[1], cur[2]
  if not state then
    return {'NOT_FOUND'}
  end
  if state ~= 'ACTIVE' then
    return {'REJECTED', 'STATE'}
  end
  if version ~= args[1] then
    return {'REJECTED', 'VERSION'}
  end
  redis.call('HSET', keys[1], 'lastSeenAt', args[2], 'touches', (tonumber(cur[3]) or 0) + 1)
  return {'UPDATED'}
end

redis.register_function('session_touch', session_touch)
