#!lua name=clab
-- 이름은 clab 이지만 내용이 다른 판. 슬롯 이동 때 원본 노드의 clab 으로 덮이는지 본다.
redis.register_function('clab_v2_only', function() return 'v2' end)
