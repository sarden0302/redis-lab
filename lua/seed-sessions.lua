-- 실험 1 데이터 준비. 같은 필드를 가진 세션 N개를 세 가지 형태로 만든다.
-- ARGV[1]: N, ARGV[2]: 'hash' | 'json' | 'jsonw'
-- 키 번호는 redis-benchmark의 __rand_int__(12자리 0 채움)와 맞춘다.
local n, kind = tonumber(ARGV[1]), ARGV[2]
for i = 0, n - 1 do
  local id = string.format('%012d', i)
  if kind == 'hash' then
    redis.call('HSET', 'lab:sess:h:' .. id, 'actorKind', 'BUYER', 'actorId', tostring(i),
      'purpose', 'SESSION', 'state', 'ACTIVE', 'authVersion', '3',
      'issuedAt', '1764000000000', 'expiresAt', '1764001800000', 'lastSeenAt', '1764000000000')
  else
    local body = cjson.encode({actorKind = 'BUYER', actorId = tostring(i), purpose = 'SESSION',
      state = 'ACTIVE', authVersion = 3, issuedAt = 1764000000000, expiresAt = 1764001800000,
      lastSeenAt = 1764000000000})
    if kind == 'json' then
      redis.call('JSON.SET', 'lab:sess:j:' .. id, '$', body)
    else
      -- 필터 경로($[?(...)])는 루트의 자식에 적용되므로 세션을 한 단계 감싼다.
      redis.call('JSON.SET', 'lab:sess:jw:' .. id, '$', '{"s":' .. body .. '}')
    end
  end
end
return n
