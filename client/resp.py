"""최소 RESP2 클라이언트. 표준 라이브러리 asyncio만 쓴다.

명령 여러 개를 한 번에 보내고(파이프라인) 응답을 순서대로 읽는 것만 한다.
왕복 수와 보낸 명령 수를 세어 전략끼리 비교할 수 있게 한다.
"""
import asyncio


class RedisError(Exception):
    """서버가 보낸 에러 응답(-ERR ...)."""


class Redis:
    def __init__(self, reader, writer, name=''):
        self.reader, self.writer, self.name = reader, writer, name
        self.round_trips = 0   # pipeline() 호출 수 = 네트워크 왕복 수
        self.commands = 0      # 보낸 명령 수
        self.trace = None      # 리스트를 넣으면 (연결 이름, 명령들, 응답들)을 기록한다

    @classmethod
    async def connect(cls, host, port=6379, name=''):
        reader, writer = await asyncio.open_connection(host, port)
        return cls(reader, writer, name)

    @staticmethod
    def encode(args):
        # 명령은 bulk string 배열로 보낸다: *<개수>\r\n $<길이>\r\n<값>\r\n ...
        out = [b'*%d\r\n' % len(args)]
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out.append(b'$%d\r\n%s\r\n' % (len(a), a))
        return b''.join(out)

    async def read_reply(self):
        line = await self.reader.readline()
        if not line:
            raise ConnectionError('server closed the connection')
        kind, body = line[:1], line[1:-2]
        if kind == b'+':                      # simple string: OK, QUEUED
            return body.decode()
        if kind == b'-':                      # error: 예외로 던지지 않고 값으로 돌려준다
            return RedisError(body.decode())
        if kind == b':':                      # integer
            return int(body)
        if kind == b'$':                      # bulk string, -1이면 nil
            n = int(body)
            return None if n < 0 else (await self.reader.readexactly(n + 2))[:-2]
        if kind == b'*':                      # array, -1이면 nil (WATCH 충돌 시 EXEC 응답)
            n = int(body)
            return None if n < 0 else [await self.read_reply() for _ in range(n)]
        raise RedisError(f'unknown reply: {line!r}')

    async def pipeline(self, *cmds):
        """명령 여러 개를 한 번에 쓰고 응답을 순서대로 읽는다. 왕복 1회."""
        self.writer.write(b''.join(self.encode(c) for c in cmds))
        await self.writer.drain()
        replies = [await self.read_reply() for _ in cmds]
        self.round_trips += 1
        self.commands += len(cmds)
        if self.trace is not None:
            self.trace.append((self.name, cmds, replies))
        return replies

    async def call(self, *args):
        reply = (await self.pipeline(args))[0]
        if isinstance(reply, RedisError):
            raise reply
        return reply

    async def close(self):
        self.writer.close()
        await self.writer.wait_closed()
