#!lua name=dup_a
-- 부분 실패 확인용. dup_b 와 같은 함수 이름(dup_fn)을 등록한다.
redis.register_function('dup_fn', function() return 'a' end)
