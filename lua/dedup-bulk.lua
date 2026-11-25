-- 실험 2 대량 실행. 요청 ID <prefix><12자리 번호> count개를 넣거나(add) 존재 여부를 센다(exists).
-- KEYS[1]: Set / Bloom / Cuckoo 키
-- ARGV[1]: 'set' | 'bf' | 'cf', ARGV[2]: 'add' | 'exists', ARGV[3]: ID 접두사, ARGV[4]: count
-- Cuckoo는 CF.ADD가 중복도 다시 넣으므로 중복 감지에는 CF.ADDNX를 쓴다.
-- 반환: add는 새로 들어간(=중복 아님으로 판정된) 개수, exists는 '있다'고 답한 개수
local cmds = {
  set = {add = 'SADD', exists = 'SISMEMBER'},
  bf = {add = 'BF.ADD', exists = 'BF.EXISTS'},
  cf = {add = 'CF.ADDNX', exists = 'CF.EXISTS'},
}
local cmd = cmds[ARGV[1]][ARGV[2]]
local prefix, n, hits = ARGV[3], tonumber(ARGV[4]), 0
for i = 0, n - 1 do
  hits = hits + redis.call(cmd, KEYS[1], prefix .. string.format('%012d', i))
end
return hits
