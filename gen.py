# -*- coding: utf-8 -*-
r"""
Wan2.2 本地文生视频生成工具（通过 ComfyUI API）
用法示例:
  python gen.py --prompt "一只橘猫在草地上追蝴蝶，阳光明媚" --out outputs\cat.mp4
  python gen.py --prompt "..." --width 1280 --height 720 --length 81 --seed 42
"""
import argparse
import json
import os
import random
import shutil
import sys
import time
import urllib.request

SERVER = os.environ.get("COMFYUI_SERVER", "http://127.0.0.1:8188")
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "wan22_t2v_template.json")


def http_json(url, payload=None, timeout=30):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def build_workflow(a):
    with open(TEMPLATE, "r", encoding="utf-8") as f:
        raw = f.read()
    raw = (raw.replace("{{PROMPT}}", a.prompt.replace('"', "'"))
              .replace("{{NEGATIVE}}", a.negative.replace('"', "'"))
              .replace("{{WIDTH}}", str(a.width))
              .replace("{{HEIGHT}}", str(a.height))
              .replace("{{LENGTH}}", str(a.length))
              .replace("{{SEED}}", str(a.seed))
              .replace("{{STEPS}}", str(a.steps))
              .replace("{{CFG}}", str(a.cfg))
              .replace("{{SAMPLER}}", a.sampler)
              .replace("{{SCHEDULER}}", a.scheduler)
              .replace("{{BOUNDARY}}", str(a.boundary))
              .replace("{{FPS}}", str(a.fps))
              .replace("{{PREFIX}}", a.prefix))
    wf = json.loads(raw)
    if a.no_lora:
        # 不用加速 LoRA 时，模型直连采样器（慢但质量略高）
        wf["57"]["inputs"]["model"] = ["37", 0]
        wf["58"]["inputs"]["model"] = ["56", 0]
    return wf


def submit(wf):
    try:
        r = http_json(SERVER + "/prompt", {"prompt": wf, "client_id": "zcode_gen"})
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8"))
        except Exception:
            err = {"error": str(e)}
        print("[错误] ComfyUI 拒绝了工作流:", json.dumps(err, ensure_ascii=False, indent=2))
        sys.exit(1)
    return r["prompt_id"]


def wait_done(prompt_id, a):
    t0 = time.time()
    last_note = ""
    while True:
        time.sleep(5)
        elapsed = time.time() - t0
        if elapsed > a.timeout:
            print("[错误] 超时（%d 秒），任务可能还在跑，可在 ComfyUI 界面查看" % a.timeout)
            sys.exit(2)
        hist = http_json(SERVER + "/history/" + prompt_id)
        if prompt_id in hist:
            entry = hist[prompt_id]
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                print("[错误] 生成失败:", json.dumps(status, ensure_ascii=False)[:2000])
                sys.exit(3)
            return entry["outputs"]
        q = http_json(SERVER + "/queue")
        running = any(it[1] == prompt_id for it in q.get("queue_running", []))
        pending = any(it[1] == prompt_id for it in q.get("queue_pending", []))
        note = "排队中..." if pending else ("生成中..." if running else "启动中...")
        if note != last_note or elapsed % 30 < 5:
            print("[%4dm%02ds] %s" % (elapsed // 60, elapsed % 60, note))
            last_note = note


def fetch_outputs(outputs):
    files = []
    for node_out in outputs.values():
        for key, items in node_out.items():
            if not isinstance(items, list):
                continue
            for it in items:
                if isinstance(it, dict) and "filename" in it:
                    files.append((it["filename"], it.get("subfolder", ""), it.get("type", "output")))
    return files


def main():
    p = argparse.ArgumentParser(description="Wan2.2 文生视频（ComfyUI）")
    p.add_argument("--prompt", required=True, help="正向提示词（视频内容描述，建议写镜头语言）")
    p.add_argument("--negative", default="", help="负向提示词")
    p.add_argument("--width", type=int, default=1280, help="宽（默认1280；480p用832）")
    p.add_argument("--height", type=int, default=720, help="高（默认720；480p用480）")
    p.add_argument("--length", type=int, default=81, help="帧数，必须为4n+1（81=5秒）")
    p.add_argument("--seed", type=int, default=None, help="随机种子（不填则随机）")
    p.add_argument("--steps", type=int, default=4, help="总步数（用加速LoRA默认4；不用LoRA建议20）")
    p.add_argument("--cfg", type=float, default=1.0, help="CFG（加速LoRA用1.0；不用LoRA建议3.5）")
    p.add_argument("--boundary", type=int, default=2, help="高/低噪声切换步（默认steps的一半）")
    p.add_argument("--sampler", default="euler")
    p.add_argument("--scheduler", default="simple")
    p.add_argument("--fps", type=int, default=16, help="帧率（默认16）")
    p.add_argument("--no-lora", action="store_true", help="不加载加速LoRA（慢，质量略高）")
    p.add_argument("--out", default=None, help="输出文件路径（默认 outputs\\时间戳.mp4）")
    p.add_argument("--prefix", default="movie/wan22", help="ComfyUI 内部文件名前缀")
    p.add_argument("--timeout", type=int, default=3600, help="超时秒数")
    a = p.parse_args()

    if a.seed is None:
        a.seed = random.randint(0, 2**31 - 1)
    if a.boundary is None or a.boundary <= 0:
        a.boundary = max(1, a.steps // 2)
    if (a.length - 1) % 4 != 0:
        print("[提示] 帧数建议为 4n+1（如 33/49/81），已继续")
    print("参数: %dx%d %d帧@%dfps seed=%d steps=%d cfg=%s %s" % (
        a.width, a.height, a.length, a.fps, a.seed, a.steps, a.cfg,
        "无LoRA" if a.no_lora else "加速LoRA"))
    print("提示词:", a.prompt)

    wf = build_workflow(a)
    t0 = time.time()
    prompt_id = submit(wf)
    print("已提交任务:", prompt_id)
    outputs = wait_done(prompt_id, a)

    files = fetch_outputs(outputs)
    if not files:
        print("[错误] 完成但没有输出文件:", json.dumps(outputs, ensure_ascii=False)[:1000])
        sys.exit(4)
    out_dir = os.path.join(HERE, "outputs")
    os.makedirs(out_dir, exist_ok=True)
    saved = []
    for i, (fname, subfolder, ftype) in enumerate(files):
        url = "%s/view?%s" % (SERVER, urllib.parse.urlencode(
            {"filename": fname, "subfolder": subfolder, "type": ftype}))
        dst = a.out if (a.out and len(files) == 1) else os.path.join(
            out_dir, "%d_%s" % (int(time.time()), fname))
        if a.out and len(files) > 1 and i > 0:
            dst = a.out + ".%d" % i
        with urllib.request.urlopen(url, timeout=120) as r, open(dst, "wb") as f:
            shutil.copyfileobj(r, f)
        saved.append(os.path.abspath(dst))
        print("已保存:", os.path.abspath(dst))
    print("完成，用时 %.1f 分钟，seed=%d" % ((time.time() - t0) / 60.0, a.seed))


if __name__ == "__main__":
    main()
