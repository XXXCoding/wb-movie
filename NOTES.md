# 部署踩坑实录（2026-09-26 首次部署，RTX 5070 / 12GB / 国内网络）

部署前快速通读一遍，能省掉大部分卡壳时间。

## 一、网络：先分层探测，别被表象骗了

1. **被墙 ≠ 端口不通**。本机 `github.com:443` TCP 三次握手能通（Test-NetConnection True），
   但 TLS ClientHello 一发就被重置（curl 显示 000）。判断要用 `curl` 测 HTTPS 层，
   TCP 测试只能说明端口没被封。
2. 实测可达性分区（2026-09）：
   - **不通**：huggingface.co、github.com、api.github.com、codeload.github.com、7-zip.org
   - **可达**：raw.githubusercontent.com、objects.githubusercontent.com（CDN 边缘）、
     ModelScope、gitee、ghfast.top、pypi.org、清华/阿里云/华为云镜像、python.org、npmmirror
3. **SSH 意外的好通道**：`git@github.com:22` 和 `git@ssh.github.com:443` 的 SSH 协议完全可用
   （HTTPS 被墙时，git 推送走 SSH 是最可靠的路）。
4. ghfast.top 等 GitHub 加速器：小文件可用（插件 zip OK），**大文件 ~127KB/s 且不稳**，
   别拿来下 GB 级文件。

## 二、ModelScope（模型主力线路，免费无需登录）

5. `/resolve/` 链接是 302 跳转 → `curl` 必须 `-L`，否则存下来的是几百字节的跳转页
   （看起来"下载成功"，实际是空壳）。
6. **单流约 4MB/s，但支持 Range** → 用分段并行下载（16 段实测聚合 17MB/s），
   9.65GB 约 10 分钟。见 `lib/chunked_dl.py`。
7. 两个坑：① 多个并发单流下载会被挂起（0 字节假死）；② 慢启动常见——
   0 字节卡几分钟再突然出数据。所以 curl 一律加 `--speed-limit 20000 --speed-time 30`
   （30 秒低于 20KB/s 自动断开重试）。
8. ModelScope 的 **HEAD 请求不返回 Content-Length** → 分段下载器探测总大小要用
   `Range: bytes=0-0` + 解析 `Content-Range` 头（chunked_dl.py 已实现）。

## 三、文件完整性：永远最后验一道

9. **ghfast.top 代理的 GitHub 源码 zip 是残缺包**：少了 `comfy/__init__.py` 等文件，
   但 zip 自身 CRC 校验通过、能正常解压！必须统计解压后文件数（ComfyUI ≥ 1100）
   并检查关键文件（comfy/options.py、comfy_extras/nodes_video.py）。
   ComfyUI 源码替代线路：**gitee.com/mirrors/comfyui**（官方同步镜像，~2MB/s）。
10. 大模型下载后一律 **SHA256 校验**（models_manifest.json 内置哈希）。
    ModelScope 的 API（`/api/v1/models/{ns}/{name}/repo/files`）能直接列出每个文件的
    大小和 SHA256，下载前先取来做对照表。
11. **绝对禁止两个进程同时写同一个文件**。本部署踩过：TaskStop 杀掉 shell 后
    curl 子进程变孤儿继续下载，与重试任务双写同一文件 → 文件损坏。
    处理：`taskkill /F /IM curl.exe` 杀干净再重下；python 下载器不受此影响。

## 四、Python 环境

12. PyPI 的 torch Windows 轮子**新版默认 CPU 构建**（`torch 2.14.0+cpu`）。
    CUDA 必须从 `download.pytorch.org/whl/cu130` 装（国外）或
    `mirrors.aliyun.com/pytorch-wheels/cu130/`（国内，3.5MB/s）。
    RTX 50 系（sm_120）要求 torch ≥ 2.7 + cu128。
13. 嵌入式 Python 的 `python312._pth` 是隔离模式：**不会自动把脚本目录加进 sys.path**，
    直接跑 `ComfyUI\main.py` 报 `No module named 'comfy'`。
    修法：_pth 文件里 `#import site` 改 `import site`，并追加一行 `..\ComfyUI`。
14. pip 装 ComfyUI requirements 时，清华镜像缺
    `comfyui-workflow-templates-media-assets-02==0.1.6` → 依赖解析器会无限回溯（卡 30 分钟+）。
    修法：先 `pip install comfyui-workflow-templates-media-assets-02==0.1.6 --index-url https://pypi.org/simple`
    单独装上，再跑 requirements。
15. pip 官方源 get-pip.py 国内只有 ~30KB/s：curl 加 `-C -` 续传 + 重试，2.6MB 也能过。

## 五、ComfyUI / 模型使用

16. 12GB 显存跑 14B Q4：靠 ComfyUI 自动显存卸载（日志出现 `lowvram patches` 属正常），
    内存 48GB 时体验良好；OOM 报错再加 `--lowvram`。
17. Wan2.2 A14B 是双模型架构（HighNoise + LowNoise 两阶段各采样一半步数），
    配 Lightning/Seko 4 步 LoRA 时：总步数 4、边界步 2、CFG 1、euler+simple、
    latent 用 EmptyHunyuanLatentVideo（帧数 4n+1）、16fps。
18. 非官方加速方式：`lightx2v/Wan2.2-Lightning` 仓库的 Seko V2.0 rank64 LoRA
    （T2V 用 `Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0/`），quality/速度均衡。
19. 显存 <8GB 跑不动 14B：改用 Wan2.2-TI2V-5B（单模型 ~10GB fp16，8GB 卡可跑，
    换 wan2.2_vae，24fps）。manifest 未含此模型，需要时按同样方法从
    `Comfy-Org/Wan_2.2_ComfyUI_Repackaged` 补。
20. 网吧还原卡：把仓库和 `ComfyUI_windows_portable` 放在非还原盘/自己的分区；
    模型目录也可以用 ComfyUI 的 `extra_model_paths.yaml` 指到移动硬盘。

## 六、现场快速排障

| 症状 | 先查 |
|---|---|
| 下载 0 字节不动 | ModelScope 慢启动，等 3 分钟；再不行杀掉 curl 重跑脚本（可续传） |
| `No module named 'comfy'` | python312._pth 是否含 `..\ComfyUI` 和 `import site` |
| torch `not compiled with CUDA` | 装了 PyPI 的 CPU 包 → 按第 12 条重装 +cu130 |
| pip 卡死不动 | media-assets-02 缺失回溯 → 按第 14 条 |
| 服务起不来 | 看 `logs\server_err.log`；端口 8188 被占则换 `--port 8189` |
| 生成 OOM | run_nvidia_gpu.bat 加 `--lowvram`；或降档位/降分辨率 |
