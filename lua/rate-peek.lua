-- 읽기 전용 스크립트. 현재 횟수와 남은 시간창(ms)을 돌려준다. EVALSHA_RO로 부를 수 있다.
-- KEYS[1]: lab:rl:<식별자>
return {tonumber(redis.call('GET', KEYS[1]) or 0), redis.call('PTTL', KEYS[1])}
