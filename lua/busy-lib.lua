#!lua name=busy
-- 실험 4. 끝나지 않는 루프를 함수로 등록한다. FUNCTION KILL로만 멈출 수 있다.
local function spin(keys, args)
  local i = 0
  while true do i = i + 1 end
end
redis.register_function('spin', spin)
