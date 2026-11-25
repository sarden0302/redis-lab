#!lua name=ratelimit
-- rate-limit.lua와 같은 로직을 Redis Functions 라이브러리로 옮긴 것.
-- FUNCTION LOAD REPLACE 로 올리고 FCALL rate_limit 1 <key> <limit> <windowMs> 로 부른다.
-- EVAL과 달리 KEYS/ARGV 전역 대신 인자(keys, args)로 받는다.

local function rate_limit(keys, args)
  local count = redis.call('INCR', keys[1])
  if count == 1 then
    redis.call('PEXPIRE', keys[1], args[2])
  end
  local remaining = redis.call('PTTL', keys[1])
  if remaining < 0 then
    redis.call('PEXPIRE', keys[1], args[2])
    remaining = tonumber(args[2])
  end
  if count > tonumber(args[1]) then
    return {0, remaining}
  end
  return {1, remaining}
end

-- 읽기 전용. no-writes 플래그가 있어야 FCALL_RO와 읽기 전용 레플리카에서 부를 수 있다.
local function peek(keys, args)
  return {tonumber(redis.call('GET', keys[1]) or 0), redis.call('PTTL', keys[1])}
end

redis.register_function('rate_limit', rate_limit)
redis.register_function{function_name = 'peek', callback = peek, flags = {'no-writes'}}
