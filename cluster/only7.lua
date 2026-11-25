#!lua name=only7
-- 대상 노드에만 있는 라이브러리. 슬롯 이동 뒤에도 남는지 본다.
redis.register_function('only7_fn', function() return 'only7' end)
