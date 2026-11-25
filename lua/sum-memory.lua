-- 접두사 + 12자리 번호 키 N개의 MEMORY USAGE(SAMPLES 0: 전체 원소 계산) 합계.
-- ARGV[1]: 키 접두사, ARGV[2]: N
local prefix, n, total = ARGV[1], tonumber(ARGV[2]), 0
for i = 0, n - 1 do
  total = total + (redis.call('MEMORY', 'USAGE', prefix .. string.format('%012d', i), 'SAMPLES', '0') or 0)
end
return total
