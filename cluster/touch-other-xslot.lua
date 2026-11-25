#!lua flags=allow-cross-slot-keys
-- allow-cross-slot-keys 플래그: 선언하지 않은 키 ARGV[1]도 건드린다.
redis.call('INCR', KEYS[1])
return redis.call('INCR', ARGV[1])
