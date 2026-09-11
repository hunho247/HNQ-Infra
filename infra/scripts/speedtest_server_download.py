# python3 -m venv venv
# source venv/bin/activate
# pip install aiohttp
# python main.py

import asyncio
import aiohttp
import time
from dataclasses import dataclass

# ====== CONFIG ======
URL = "https://storage-minio-console.l2cteam.work/api/v1/download-shared-object/aHR0cHM6Ly9zdG9yYWdlLW1pbmlvLWFwaS5sMmN0ZWFtLndvcmsvYnVja2V0LWdpYWFuLWNsaW5pYy1wcm9kL0JDb21wYXJlT1NYLTQuNC43LjI4Mzk3LnppcD9YLUFtei1BbGdvcml0aG09QVdTNC1ITUFDLVNIQTI1NiZYLUFtei1DcmVkZW50aWFsPVNHMkMxN1pSM0NKTU9FNUhTUVM3JTJGMjAyNjAyMjAlMkZ1cy1lYXN0LTElMkZzMyUyRmF3czRfcmVxdWVzdCZYLUFtei1EYXRlPTIwMjYwMjIwVDAxMzYyMlomWC1BbXotRXhwaXJlcz00MzE5OCZYLUFtei1TZWN1cml0eS1Ub2tlbj1leUpoYkdjaU9pSklVelV4TWlJc0luUjVjQ0k2SWtwWFZDSjkuZXlKaFkyTmxjM05MWlhraU9pSlRSekpETVRkYVVqTkRTazFQUlRWSVUxRlROeUlzSW1WNGNDSTZNVGMzTVRVNU5EQXpPQ3dpY0dGeVpXNTBJam9pWVdSdGFXNGlmUS5GcTBKMnYxSmU2ZjVtOG5TbGpSYUM5WTh3ZTZhRVJYYmFRT09UU2hlaUhCT0RxdEFKUVcxMmJSLXF1eFhhUnJvRFV4b1BmZTd5UDBWYmhCZ0QwTDg1dyZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QmdmVyc2lvbklkPW51bGwmWC1BbXotU2lnbmF0dXJlPWEzNWRiMTljYmYzMDliNjA3ZjM3Y2YzNTljZmI1MTZhYjI1NjA4ZjM3Yzk3OTE3MjFmMjk4OTQzMmVjYjZmYTU"
CONCURRENT_USERS = 1          # số "máy" giả lập
TEST_DURATION = 10             # giây
CHUNK_SIZE = 256 * 1024        # 256 KiB
PRINT_EVERY = 1.0              # giây
# ====================


@dataclass
class ClientStats:
    bytes: int = 0
    errors: int = 0
    last_bytes: int = 0
    done: int = 0  # 0/1


def human_mib(n_bytes: int) -> float:
    return n_bytes / (1024 * 1024)


def human_mbps(n_bytes: int, dt: float) -> float:
    if dt <= 0:
        return 0.0
    return (n_bytes * 8) / (dt * 1_000_000)


async def download_loop(session: aiohttp.ClientSession, idx: int, stats: ClientStats, stop_evt: asyncio.Event):
    """
    Mỗi client sẽ liên tục tải URL (GET) cho tới khi stop_evt được set.
    Không ghi ra disk, chỉ đọc stream để đo throughput.
    """
    while not stop_evt.is_set():
        try:
            async with session.get(URL) as resp:
                if resp.status != 200:
                    stats.errors += 1
                    # đợi chút để tránh spam request khi bị lỗi
                    await asyncio.sleep(0.5)
                    continue

                async for chunk in resp.content.iter_chunked(CHUNK_SIZE):
                    stats.bytes += len(chunk)
                    if stop_evt.is_set():
                        break
        except asyncio.CancelledError:
            break
        except Exception:
            stats.errors += 1
            await asyncio.sleep(0.5)

    stats.done = 1


async def progress_printer(all_stats: list[ClientStats], start_ts: float, stop_evt: asyncio.Event):
    last_ts = time.time()
    while not stop_evt.is_set():
        await asyncio.sleep(PRINT_EVERY)
        now = time.time()
        dt = now - last_ts
        elapsed = now - start_ts

        # tính tổng + tốc độ tức thời
        total_bytes = sum(s.bytes for s in all_stats)
        total_delta = sum((s.bytes - s.last_bytes) for s in all_stats)

        # print header
        print("\033[2J\033[H", end="")  # clear screen
        print(f"Download load test | users={len(all_stats)} | elapsed={elapsed:.1f}s / {TEST_DURATION}s")
        print(f"TOTAL: {human_mib(total_bytes):.2f} MiB  |  inst: {human_mbps(total_delta, dt):.2f} Mbps")
        print("-" * 80)

        # print per-client
        for i, s in enumerate(all_stats):
            delta = s.bytes - s.last_bytes
            inst_mbps = human_mbps(delta, dt)
            status = "DONE" if s.done else "RUN "
            print(
                f"[{i:02d}] {status}  "
                f"downloaded={human_mib(s.bytes):8.2f} MiB  "
                f"inst={inst_mbps:8.2f} Mbps  "
                f"errors={s.errors}"
            )

        # update last_bytes
        for s in all_stats:
            s.last_bytes = s.bytes
        last_ts = now

    # in lần cuối (khi stop)
    now = time.time()
    elapsed = now - start_ts
    total_bytes = sum(s.bytes for s in all_stats)
    avg_mbps = human_mbps(total_bytes, elapsed)

    print("\n=== FINAL SUMMARY ===")
    print(f"Duration: {elapsed:.2f}s")
    print(f"Total downloaded: {human_mib(total_bytes):.2f} MiB")
    print(f"Average throughput (total): {avg_mbps:.2f} Mbps")
    print(f"Average per user: {avg_mbps/len(all_stats):.2f} Mbps")
    print(f"Total errors: {sum(s.errors for s in all_stats)}")


async def main():
    stop_evt = asyncio.Event()
    stats = [ClientStats() for _ in range(CONCURRENT_USERS)]

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=None)
    # limit=0 => unlimited connections (nhưng ta kiểm soát bằng số task)
    connector = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300)

    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        start_ts = time.time()

        workers = [
            asyncio.create_task(download_loop(session, i, stats[i], stop_evt))
            for i in range(CONCURRENT_USERS)
        ]
        printer = asyncio.create_task(progress_printer(stats, start_ts, stop_evt))

        # chạy đúng TEST_DURATION
        try:
            await asyncio.sleep(TEST_DURATION)
        finally:
            stop_evt.set()
            # chờ workers thoát “êm”
            await asyncio.gather(*workers, return_exceptions=True)
            await asyncio.sleep(0.1)
            printer.cancel()
            try:
                await printer
            except asyncio.CancelledError:
                pass


if __name__ == "__main__":
    asyncio.run(main())