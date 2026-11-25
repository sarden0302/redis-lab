return redis.call('INCR', KEYS[1])
-- EVAL/EVALSHA용. 선언한 키 하나를 INCR 한다. 주석을 첫 줄에 두지 않는다: '--'로 시작하는 본문은
-- redis-cli --cluster call 이 옵션으로 읽어 거부한다(실험 7 Q3-d).
