# -*- coding: utf-8 -*-
"""分块并行下载器：对支持 Range 的大文件用多线程分段下载后拼接。"""
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


def get_total(url):
    size, ranges = 0, False
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=60) as r:
            size = int(r.headers.get("Content-Length") or 0)
            ranges = (r.headers.get("Accept-Ranges") == "bytes")
    except Exception as e:
        print("HEAD 失败: %s, 改用 Range 探测" % e)
    if size == 0 or not ranges:
        req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            cr = r.headers.get("Content-Range") or ""
            if r.status == 206 and "/" in cr:
                size = int(cr.rsplit("/", 1)[1])
                ranges = True
    return size, ranges


def fetch_range(url, start, end, path, tries=8):
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"Range": "bytes=%d-%d" % (start, end)})
            with urllib.request.urlopen(req, timeout=120) as r, open(path, "wb") as f:
                got = 0
                expect = end - start + 1
                while True:
                    buf = r.read(1024 * 512)
                    if not buf:
                        break
                    f.write(buf)
                    got += len(buf)
                if got == expect:
                    return path, got
                print("  chunk %s: 收到 %d/%d 字节, 重试" % (os.path.basename(path), got, expect))
        except Exception as e:
            print("  chunk %s: %s, 第 %d 次重试" % (os.path.basename(path), e, attempt + 1))
            time.sleep(2 + attempt)
    raise RuntimeError("chunk failed: " + path)


def main():
    url, out = sys.argv[1], sys.argv[2]
    nchunks = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    workers = int(sys.argv[4]) if len(sys.argv) > 4 else 6
    total, ok = get_total(url)
    if not ok or total == 0:
        print("服务器不支持分段或大小未知 (size=%s, ranges=%s)" % (total, ok))
        sys.exit(1)
    step = total // nchunks
    jobs = [(i * step, (total - 1) if i == nchunks - 1 else (i + 1) * step - 1)
            for i in range(nchunks)]
    print("总大小 %.2f GB, 分 %d 段并行下载 -> %s" % (total / 1e9, nchunks, out))
    t0 = time.time()
    done_bytes = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {}
        for i, (s, e) in enumerate(jobs):
            p = "%s.part%03d" % (out, i)
            futs[ex.submit(fetch_range, url, s, e, p)] = (i, s, e, p)
        for fu in as_completed(futs):
            i, s, e, p = futs[fu]
            _, got = fu.result()
            done_bytes += got
            rate = done_bytes / max(time.time() - t0, 1) / 1e6
            print("  [%d/%d] 段 %d 完成 (%.1f MB/s)" % (
                len([f for f in futs if f.done()]), len(jobs), i, rate))
    with open(out, "wb") as o:
        for i in range(nchunks):
            p = "%s.part%03d" % (out, i)
            with open(p, "rb") as f:
                while True:
                    buf = f.read(1024 * 1024 * 8)
                    if not buf:
                        break
                    o.write(buf)
            os.remove(p)
    final = os.path.getsize(out)
    if final != total:
        print("大小不符: %d != %d" % (final, total))
        sys.exit(1)
    print("完成: %s (%.2f GB, 用时 %.1f 分钟)" % (out, total / 1e9, (time.time() - t0) / 60))


if __name__ == "__main__":
    main()
