#!lua name=clab
-- 실험 7(클러스터)용 함수 라이브러리. 어느 노드에서 실행됐는지 보이도록 노드 ID를 같이 돌려준다.

local function myid()
  return redis.call('CLUSTER', 'MYID')
end

-- 선언한 키 하나를 INCR 한다.
local function hit(keys, args)
  return {redis.call('INCR', keys[1]), myid()}
end

-- 선언한 키 두 개를 INCR 한다. 슬롯이 다르면 FCALL 단계에서 CROSSSLOT이 나야 한다.
local function hit2(keys, args)
  return {redis.call('INCR', keys[1]), redis.call('INCR', keys[2]), myid()}
end

-- 읽기 전용 조회(FCALL cpeek). ASK 리다이렉트 확인에 쓴다. 함수 이름은 라이브러리가 달라도 노드 안에서 겹치면 안 되므로
-- ratelimit 라이브러리의 peek 와 다른 이름으로 등록한다.
local function peek(keys, args)
  return {redis.call('GET', keys[1]) or false, myid()}
end

-- 키 없이 호출. 어느 노드가 실행하는지 확인한다.
local function whoami(keys, args)
  return myid()
end

-- 키를 선언하지 않고(numkeys 0) 인자로 받은 키에 쓴다.
local function write_nokey(keys, args)
  return {redis.call('INCR', args[1]), myid()}
end

-- 선언한 키 외에 선언하지 않은 키(args[1])도 건드린다.
local function touch_other(keys, args)
  redis.call('INCR', keys[1])
  return {redis.call('INCR', args[1]), myid()}
end

redis.register_function('hit', hit)
redis.register_function('hit2', hit2)
redis.register_function{function_name = 'cpeek', callback = peek, flags = {'no-writes'}}
redis.register_function{function_name = 'whoami', callback = whoami, flags = {'no-writes'}}
redis.register_function('whoami_rw', whoami)
redis.register_function('write_nokey', write_nokey)
redis.register_function('touch_other', touch_other)
redis.register_function{function_name = 'touch_other_x', callback = touch_other, flags = {'allow-cross-slot-keys'}}
