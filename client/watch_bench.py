"""실험 5. 같은 조건부 갱신을 네 가지로 부른다.

  watch-multi  WATCH + HMGET (왕복 1) -> 클라이언트에서 판단 -> MULTI/HSET/EXEC (왕복 1). EXEC가 nil이면 재시도
  naive        WATCH 없이 같은 흐름. 잃어버린 갱신이 실제로 잡히는지 확인하는 대조군
  evalsha      EVALSHA session-touch-count.lua (왕복 1)
  fcall        FCALL session_touch (왕복 1)

조건: state == ACTIVE 이고 authVersion == 3 일 때만 lastSeenAt과 touches(읽은 값 + 1)를 쓴다.
모든 전략이 같은 클라이언트(resp.py)를 쓰므로 클라이언트 비용은 같은 조건이다.

사용:
  python watch_bench.py --host redis-lab transcript
  python watch_bench.py --host redis-lab bench --reps 3 --duration 5 --conns 1 8 32 --out /out/x.csv
"""
import argparse
import asyncio
import csv
import random
import sys
import time
from collections import Counter

from resp import Redis, RedisError

SESSIONS = 10_000
VERSION = b'3'
NOW = 1764000999000
MAX_RETRIES = 10        # 첫 시도 + 재시도 10회. 그래도 충돌하면 포기(GAVE_UP)로 센다
LUA_FILE = '/lab/lua/session-touch-count.lua'
LIB_FILE = '/lab/lua/session-lib.lua'


def low_key(i):
    return f'lab:w:s:{i:012d}'


def hot_key(i):
    return f'lab:w:hot:{i}'


def session_fields(i):
    return ('actorKind', 'BUYER', 'actorId', i, 'purpose', 'SESSION', 'state', 'ACTIVE',
            'authVersion', 3, 'issuedAt', 1764000000000, 'expiresAt', 1764001800000,
            'lastSeenAt', 1764000000000, 'touches', 0)


# ---- 전략. 반환: (결과, EXEC 중단 수) -------------------------------------------

async def touch_watch(r, key, sha):
    aborts = 0
    while True:
        _, (state, version, touches) = await r.pipeline(
            ('WATCH', key), ('HMGET', key, 'state', 'authVersion', 'touches'))
        if state != b'ACTIVE' or version != VERSION:
            await r.call('UNWATCH')
            return ('NOT_FOUND' if state is None else 'REJECTED'), aborts
        *_, result = await r.pipeline(
            ('MULTI',),
            ('HSET', key, 'lastSeenAt', NOW, 'touches', int(touches) + 1),
            ('EXEC',))
        if result is not None:          # EXEC가 배열을 돌려주면 반영됨
            return 'UPDATED', aborts
        aborts += 1                     # nil: WATCH한 키가 그 사이 바뀌어 트랜잭션이 버려짐
        if aborts > MAX_RETRIES:
            return 'GAVE_UP', aborts


async def touch_naive(r, key, sha):
    state, version, touches = await r.call('HMGET', key, 'state', 'authVersion', 'touches')
    if state != b'ACTIVE' or version != VERSION:
        return ('NOT_FOUND' if state is None else 'REJECTED'), 0
    await r.pipeline(('MULTI',), ('HSET', key, 'lastSeenAt', NOW, 'touches', int(touches) + 1), ('EXEC',))
    return 'UPDATED', 0


async def touch_evalsha(r, key, sha):
    return (await r.call('EVALSHA', sha, 1, key, VERSION, NOW))[0].decode(), 0


async def touch_fcall(r, key, sha):
    return (await r.call('FCALL', 'session_touch', 1, key, VERSION, NOW))[0].decode(), 0


STRATEGIES = {'watch-multi': touch_watch, 'naive': touch_naive,
              'evalsha': touch_evalsha, 'fcall': touch_fcall}


# ---- 준비 ------------------------------------------------------------------------

async def load_code(admin):
    with open(LUA_FILE, 'rb') as f:
        sha = (await admin.call('SCRIPT', 'LOAD', f.read())).decode()
    with open(LIB_FILE, 'rb') as f:
        await admin.call('FUNCTION', 'LOAD', 'REPLACE', f.read())
    return sha


async def seed(admin, keys):
    replies = await admin.pipeline(*(('HSET', k) + session_fields(i) for i, k in enumerate(keys)))
    errors = [x for x in replies if isinstance(x, RedisError)]
    if errors:
        raise errors[0]


async def sum_touches(admin, keys):
    replies = await admin.pipeline(*(('HGET', k, 'touches') for k in keys))
    return sum(int(x) for x in replies)


async def server_commands(admin):
    info = (await admin.call('INFO', 'stats')).decode()
    for line in info.splitlines():
        if line.startswith('total_commands_processed:'):
            return int(line.split(':')[1])
    return 0


# ---- 한 칸 측정 ------------------------------------------------------------------

async def run_cell(host, admin, sha, strategy, contention, conns, duration, hot_keys):
    fn = STRATEGIES[strategy]
    keys = [low_key(i) for i in range(SESSIONS)] if contention == 'low' else [hot_key(i) for i in range(hot_keys)]
    await seed(admin, keys)
    clients = [await Redis.connect(host) for _ in range(conns)]
    latencies, outcomes = [], Counter()
    aborts = 0
    before = await server_commands(admin)
    deadline = time.perf_counter() + duration

    async def worker(r):
        nonlocal aborts
        while time.perf_counter() < deadline:
            key = random.choice(keys)
            t0 = time.perf_counter()
            outcome, a = await fn(r, key, sha)
            latencies.append(time.perf_counter() - t0)
            outcomes[outcome] += 1
            aborts += a

    start = time.perf_counter()
    await asyncio.gather(*(worker(c) for c in clients))
    elapsed = time.perf_counter() - start
    server_cmds = await server_commands(admin) - before - 1   # 뒤 INFO 자신은 뺀다
    touches = await sum_touches(admin, keys)
    for c in clients:
        await c.close()

    ops = len(latencies)
    updated = outcomes['UPDATED']
    latencies.sort()
    q = lambda p: latencies[min(ops - 1, int(p * ops))] * 1000
    return {
        'strategy': strategy, 'contention': contention, 'conns': conns,
        'elapsed_s': round(elapsed, 2), 'ops': ops, 'updated': updated,
        'updates_per_s': round(updated / elapsed),
        'p50_ms': round(q(0.50), 3), 'p99_ms': round(q(0.99), 3),
        'rtt_per_op': round(sum(c.round_trips for c in clients) / ops, 3),
        'cmds_per_op': round(sum(c.commands for c in clients) / ops, 3),
        'server_cmds_per_op': round(server_cmds / ops, 3),
        'aborts': aborts, 'aborts_per_update': round(aborts / updated, 3) if updated else '',
        'gave_up': outcomes['GAVE_UP'],
        'other': sum(v for k, v in outcomes.items() if k not in ('UPDATED', 'GAVE_UP')),
        'touches_sum': touches, 'lost': updated - touches,
    }


async def bench(args):
    admin = await Redis.connect(args.host)
    sha = await load_code(admin)
    fields = None
    with open(args.out, 'w', newline='') as f:
        out = None
        for rep in range(1, args.reps + 1):
            for contention in args.contention:
                for conns in args.conns:
                    for strategy in args.strategies:
                        row = {'rep': rep, **await run_cell(args.host, admin, sha, strategy, contention,
                                                            conns, args.duration, args.hot_keys)}
                        if out is None:
                            fields = list(row)
                            out = csv.DictWriter(f, fieldnames=fields)
                            out.writeheader()
                            print(','.join(fields))
                        out.writerow(row)
                        f.flush()
                        print(','.join(str(row[k]) for k in fields), flush=True)
    await admin.close()


# ---- 단일 호출 기록 ---------------------------------------------------------------

def fmt(x):
    if x is None:
        return '(nil)'
    if isinstance(x, bytes):
        return '"' + x.decode() + '"'
    if isinstance(x, RedisError):
        return f'(error) {x}'
    if isinstance(x, list):
        return '[' + ', '.join(fmt(v) for v in x) + ']'
    return str(x)


def fmt_cmd(cmd):
    parts = [c.decode() if isinstance(c, bytes) else str(c) for c in cmd]
    return ' '.join(p if len(p) <= 60 else p[:40] + '...' for p in parts)


def print_trace(trace):
    for n, (name, cmds, replies) in enumerate(trace, 1):
        print(f'  [{name}] 왕복 {n}: 명령 {len(cmds)}개')
        for c, r in zip(cmds, replies):
            print(f'    > {fmt_cmd(c)}')
            print(f'    < {fmt(r)}')
    trace.clear()


async def transcript(args):
    admin = await Redis.connect(args.host, name='admin')
    sha = await load_code(admin)
    key, blocked = hot_key(0), 'lab:w:blocked'
    await seed(admin, [key])
    await admin.call('HSET', blocked, 'state', 'BLOCKED', 'authVersion', 3, 'touches', 0)
    trace = []
    a = await Redis.connect(args.host, name='A')
    b = await Redis.connect(args.host, name='B')
    a.trace = b.trace = trace

    print('### 1. WATCH 흐름, 충돌 없음')
    print(f'  결과: {await touch_watch(a, key, sha)}')
    print_trace(trace)

    print('### 2. WATCH 흐름, 충돌 한 번: A가 읽은 뒤 B가 같은 키를 갱신')
    _, (state, version, touches) = await a.pipeline(
        ('WATCH', key), ('HMGET', key, 'state', 'authVersion', 'touches'))
    await b.call('EVALSHA', sha, 1, key, VERSION, NOW)
    *_, result = await a.pipeline(
        ('MULTI',), ('HSET', key, 'lastSeenAt', NOW, 'touches', int(touches) + 1), ('EXEC',))
    print(f'  A의 EXEC 응답: {fmt(result)} -> A는 처음부터 다시 읽는다')
    print(f'  A 재시도 결과: {await touch_watch(a, key, sha)}')
    print_trace(trace)
    print(f'  touches = {fmt(await admin.call("HGET", key, "touches"))} (A 두 번 성공 + B 한 번)')

    print('### 3. WATCH 흐름, 조건 불일치(BLOCKED): EXEC 없이 UNWATCH')
    print(f'  결과: {await touch_watch(a, blocked, sha)}')
    print_trace(trace)

    print('### 4. EVALSHA / FCALL (각각 왕복 1)')
    await touch_evalsha(a, key, sha)
    await touch_fcall(a, key, sha)
    await touch_evalsha(a, blocked, sha)
    print_trace(trace)
    for c in (a, b, admin):
        await c.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--host', default='redis-lab')
    sub = p.add_subparsers(dest='mode', required=True)
    sub.add_parser('transcript')
    bp = sub.add_parser('bench')
    bp.add_argument('--strategies', nargs='+', default=list(STRATEGIES))
    bp.add_argument('--contention', nargs='+', default=['low', 'high'])
    bp.add_argument('--conns', nargs='+', type=int, default=[1, 8, 32])
    bp.add_argument('--duration', type=float, default=5)
    bp.add_argument('--hot-keys', type=int, default=1)
    bp.add_argument('--reps', type=int, default=3)
    bp.add_argument('--out', default='/out/5-watch-vs-lua-bench.csv')
    args = p.parse_args()
    print(f'# python {sys.version.split()[0]}', flush=True)
    asyncio.run(transcript(args) if args.mode == 'transcript' else bench(args))


if __name__ == '__main__':
    main()
