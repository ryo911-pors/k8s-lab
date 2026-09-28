"""vllm bench serve の簡易版。/v1/completions に stream で投げ、throughput / TTFT / TPOT を出す。

python loadgen.py <base_url> <concurrency> <num_prompts>
"""
import asyncio, json, random, sys, time

import aiohttp

BASE, CONC, N = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
MODEL = "Qwen/Qwen2.5-0.5B-Instruct"
OUT_LEN = 128
WORDS = "the of and to in is was for on that with as by at from his her it an are this be".split()


def prompt():
    # 1単語 ≒ 1トークン。入力は約256トークン
    return " ".join(random.choice(WORDS) for _ in range(256))


async def one(session, results):
    body = {"model": MODEL, "prompt": prompt(), "max_tokens": OUT_LEN,
            "ignore_eos": True, "stream": True}
    t0 = time.perf_counter()
    first = None
    n = 0
    async with session.post(f"{BASE}/v1/completions", json=body) as r:
        async for line in r.content:
            line = line.strip()
            if not line.startswith(b"data:") or line == b"data: [DONE]":
                continue
            chunk = json.loads(line[5:])
            if chunk["choices"][0]["text"]:
                n += 1
                if first is None:
                    first = time.perf_counter()
    end = time.perf_counter()
    results.append((first - t0, (end - first) / max(n - 1, 1), n))


async def main():
    sem = asyncio.Semaphore(CONC)
    results = []

    async def guarded(session):
        async with sem:
            await one(session, results)

    conn = aiohttp.TCPConnector(limit=0)
    async with aiohttp.ClientSession(connector=conn, timeout=aiohttp.ClientTimeout(total=None)) as s:
        t0 = time.perf_counter()
        await asyncio.gather(*(guarded(s) for _ in range(N)))
        dur = time.perf_counter() - t0
    ttft = sorted(r[0] for r in results)
    tpot = sorted(r[1] for r in results)
    toks = sum(r[2] for r in results)
    print(f"concurrency={CONC} requests={len(results)} duration={dur:.1f}s")
    print(f"output throughput: {toks / dur:.0f} tok/s")
    print(f"TTFT mean {1000 * sum(ttft) / len(ttft):.0f} ms, p99 {1000 * ttft[int(len(ttft) * 0.99)]:.0f} ms")
    print(f"TPOT mean {1000 * sum(tpot) / len(tpot):.2f} ms")


asyncio.run(main())
