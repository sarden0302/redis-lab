#!lua
-- shebang 있음(플래그 없음): 선언하지 않은 키 ARGV[1]도 건드린다.
redis.call('INCR', KEYS[1])
return redis.call('INCR', ARGV[1])
