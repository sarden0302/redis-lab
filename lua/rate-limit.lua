-- commerce-settle commerce/src/main/resources/redis/rate-limit.lua 를 그대로 옮긴 EVAL용 스크립트.
-- 고정 시간창 요청 제한. 첫 요청이 시간창을 시작하고, 이후 요청은 만료를 늘리지 않는다. 제한된 요청도 센다.
-- KEYS[1]: lab:rl:<식별자>
-- ARGV[1]: 시간창 안 허용 횟수, ARGV[2]: 시간창(ms)
-- 반환: {허용 1|거절 0, 남은 시간창 ms}
local count = redis.call('INCR', KEYS[1])
if count == 1 then
  redis.call('PEXPIRE', KEYS[1], ARGV[2])
end
local remaining = redis.call('PTTL', KEYS[1])
if remaining < 0 then
  -- 만료 없이 남은 키는 시간창이 끝나지 않으므로 다시 건다.
  redis.call('PEXPIRE', KEYS[1], ARGV[2])
  remaining = tonumber(ARGV[2])
end
if count > tonumber(ARGV[1]) then
  return {0, remaining}
end
return {1, remaining}
