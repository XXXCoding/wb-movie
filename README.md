# wan22-fast-deploy —— 本地视频生成环境快速部署包

一套在 **Windows + NVIDIA 显卡** 机器上快速部署 **Wan2.2 量化版（GGUF）文生视频** 环境的脚本。
专为"换机器 / 网吧部署"设计：自动探测硬件与网络，选择可用下载线路，装完自动校验并试跑。

> 首次部署实录（RTX 5070 / 12GB / 国内网络）：从零到出片约 1 小时，其中模型 26GB 下载约 30 分钟。
> 二次部署（环境热缓存/网速好）：约 20–40 分钟。

## 硬件要求

| 项目 | 最低 | 推荐 |
|---|---|---|
| 显卡 | NVIDIA 8GB 显存（用 Q3 量化） | 12GB+（Q4/Q5） |
| 内存 | 24GB | 48GB（跑 14B 需大量显存卸载到内存） |
| 磁盘 | 45GB 可用（自动选空间最大的盘） | SSD 更快 |
| 系统 | Windows 10 x64（1803+，自带 curl） / Win11 | - |

显存与量化档位（auto 档自动选择）：
- < 10GB → Q3_K_M（模型 7.2GB×2）
- 10–15GB → Q4_K_M（9.65GB×2，画质/速度均衡，实测 4070/5070 流畅）
- > 15GB → Q5_K_M（10.8GB×2）

## 一键部署

把整个仓库文件夹拷到目标机器（U盘/网盘均可，**不含模型，仅几 MB**），然后：

```bat
:: 双击 START_HERE.bat，或命令行：
powershell -NoProfile -ExecutionPolicy Bypass -File deploy.ps1
```

可选参数：

| 参数 | 说明 |
|---|---|
| `-InstallRoot "H:\AI"` | 指定安装根目录（默认自动选剩余空间最大的盘） |
| `-Quant Q4_K_M` | 指定量化档位（auto/Q3_K_M/Q4_K_S/Q4_K_M/Q5_K_M） |
| `-Region cn` | 强制线路：cn（国内镜像）/ intl（直连），默认自动探测 |
| `-SkipModels` | 只装环境不下载模型（约 8GB，之后可单独补） |
| `-SkipSmoke` | 跳过最后的测试视频生成 |

脚本会依次完成：硬件探测 → 网络探测选线 → Python 3.12 便携版 → PyTorch CUDA（cu130，支持 RTX 50 系）→
ComfyUI + ComfyUI-GGUF 插件 → 依赖 → 模型分段下载 + SHA256 校验 → 启动脚本 → 冒烟测试（一段 2 秒小视频）。

脚本**可重复执行**：已完成的步骤自动跳过，中断后重跑即可续传。

## 部署完成后

```
ComfyUI_windows_portable\
├─ run_nvidia_gpu.bat      ← 双击启动，网页界面 http://127.0.0.1:8188
├─ ComfyUI\                ← 程序 + 模型（models\ 下）
└─ workspace\
   ├─ gen.py               ← 命令行生成
   └─ outputs\
```

命令行生成视频：

```bat
python_embeded\python.exe workspace\gen.py --prompt "一只橘猫在草地上追蝴蝶，阳光明媚，固定镜头" --out workspace\outputs\cat.mp4
```

常用参数：
- `--width 832 --height 480`：480p，速度翻倍
- `--length 81`：帧数（4n+1），81 帧 ≈ 5 秒 @16fps
- `--seed 42`：固定种子复现
- `--no-lora --steps 20 --cfg 3.5`：不用加速 LoRA，细节略好但慢 5 倍

性能参考（RTX 5070 实测）：480p/81帧/4步 ≈ 3–5 分钟；720p/81帧/4步 ≈ 5–8 分钟。

## 换机器 / 网吧注意

1. 网吧机器可能有还原卡：重启后 H 盘若被清空，重跑脚本即可（模型重新下载）；把仓库和安装目录放不被还原的盘。
2. 默认全部走国内镜像（ModelScope / gitee / 清华 / 阿里云），**无需翻墙**。
3. 若显卡不同只需让脚本自动选量化档位；显存 8GB 以下跑 14B 会非常吃力，建议改用 5B 模型（见 docs/NOTES.md 扩展思路）。
4. 详细踩坑记录（网络分区、残缺压缩包、pip 死循环等 20 条）见 **NOTES.md**——排查问题时先看它。

## 文件清单

```
├─ START_HERE.bat            双击入口
├─ deploy.ps1                一键部署主脚本
├─ models_manifest.json      模型清单（URL×3条线路 / 大小 / SHA256）
├─ chunked_dl.py             大文件分段并行下载器（支持断点、Range 探测）
├─ gen.py                    命令行文生视频工具
├─ wan22_t2v_template.json   文生视频工作流（双阶段采样+加速LoRA）
├─ NOTES.md                  部署踩坑实录（重要）
└─ README.md                 本文件
```
