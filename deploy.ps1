# =====================================================================
#  Wan2.2 本地视频生成环境 - 一键部署脚本
#  用法: powershell -ExecutionPolicy Bypass -File deploy.ps1 [-Quant Q4_K_M] [-SkipModels] [-SkipSmoke]
#  适用: Windows 10/11 x64 + NVIDIA 显卡 (显存 >= 8GB 建议 10GB+)
#  自动: 探测硬件/网络 -> 选择下载线路 -> 装环境 -> 下模型并校验 -> 冒烟测试
# =====================================================================
param(
  [string]$InstallRoot = "",   # 安装根目录，如 H:\AI。留空=自动选剩余空间最大的盘
  [ValidateSet("auto","Q3_K_M","Q4_K_S","Q4_K_M","Q5_K_M")]
  [string]$Quant = "auto",     # 量化档位，auto=按显存选择
  [switch]$SkipModels,         # 跳过模型下载（只装环境）
  [switch]$SkipSmoke,          # 跳过最后的冒烟测试
  [string]$Region = "auto"     # auto | cn | intl  下载线路
)
$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Manifest = Get-Content (Join-Path $RepoDir "models_manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-Step($m) { Write-Host "`n===== $m =====" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-W2($m)   { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err2($m) { Write-Host "  [XX] $m" -ForegroundColor Red; exit 1 }

# 快速探测 URL 可达性（返回 http code，000=不通）
function Test-Http($url) {
  & curl.exe -s -o NUL -w "%{http_code}" -m 12 $url 2>$null
}
# 下载（带断点续传 + 慢速自动断开重试）
function Get-File($url, $out) {
  & curl.exe -sL --fail --retry 10 --retry-delay 2 --retry-all-errors `
    --speed-limit 20000 --speed-time 30 -C - -o $out $url
  return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------- 0. 硬件探测
Write-Step "0/7 硬件探测"
$gpuName = ""; $vramMB = 0
try {
  $smi = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null
  if ($smi) {
    $parts = $smi.Split(","); $gpuName = $parts[0].Trim()
    $vramMB = [int]($parts[1].Trim() -replace "[^0-9]","")
  }
} catch {}
if (-not $gpuName) { Write-Err2 "未检测到 NVIDIA 显卡（需要 nvidia-smi），本方案必须有 N 卡" }
Write-Ok "GPU: $gpuName ($vramMB MB 显存)"
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Ok "内存: $ramGB GB"
if ($ramGB -lt 24) { Write-W2 "内存 <24GB，跑 14B 模型的显存卸载可能很慢，建议至少 32GB" }
if ($Quant -eq "auto") {
  if ($vramMB -lt 10240)      { $Quant = "Q3_K_M" }
  elseif ($vramMB -lt 15360)  { $Quant = "Q4_K_M" }
  else                        { $Quant = "Q5_K_M" }
}
Write-Ok "选择量化档位: $Quant （<10GB显存建议Q3, 12GB建议Q4, 16GB+建议Q5）"

# ---------------------------------------------------------- 1. 网络探测
Write-Step "1/7 网络探测，选择下载线路"
$probe = @{
  modelscope = Test-Http "https://www.modelscope.cn"
  github     = Test-Http "https://github.com"
  hf         = Test-Http "https://huggingface.co"
  pythonorg  = Test-Http "https://www.python.org"
  tuna       = Test-Http "https://pypi.tuna.tsinghua.edu.cn/simple/"
  ghfast     = Test-Http "https://ghfast.top"
}
foreach ($k in $probe.Keys) { Write-Host ("  {0,-12} -> {1}" -f $k, $probe[$k]) }
if ($Region -eq "auto") {
  if ($probe.github -eq "000" -and $probe.modelscope -ne "000") { $Region = "cn" }
  elseif ($probe.github -ne "000") { $Region = "intl" }
  else { $Region = "cn" }
}
Write-Ok "使用线路: $Region"

# ---------------------------------------------------------- 2. 安装位置
Write-Step "2/7 确定安装位置"
if (-not $InstallRoot) {
  $best = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 40GB } |
          Sort-Object Free -Descending | Select-Object -First 1
  if (-not $best) { Write-Err2 "没有任何盘剩余空间 > 40GB（全套约需 45GB）" }
  $InstallRoot = Join-Path ($best.Root + "AI") ""
}
$Root = Join-Path $InstallRoot "ComfyUI_windows_portable"
New-Item -ItemType Directory -Force -Path $Root, "$Root\logs" | Out-Null
$Tmp = Join-Path $Root "_downloads"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
Write-Ok "安装到: $Root"

$Py = Join-Path $Root "python_embeded\python.exe"
function Py { & $Py @args; if ($LASTEXITCODE -ne 0) { throw "python 执行失败: $args" } }

# ---------------------------------------------------------- 3. Python
Write-Step "3/7 Python 环境"
if (-not (Test-Path $Py)) {
  $zip = Join-Path $Tmp "python_embed.zip"
  $got = $false
  foreach ($u in $Manifest.python_embed.urls) {
    Write-Host "  下载 $u"
    if (Get-File $u $zip) { $got = $true; break }
  }
  if (-not $got) { Write-Err2 "Python 便携包下载失败" }
  Expand-Archive -Path $zip -DestinationPath "$Root\python_embeded" -Force
  # 关键：嵌入式 Python 的 ._pth 是隔离模式，必须打开 site 并加 ComfyUI 目录
  $pth = "$Root\python_embeded\python312._pth"
  (Get-Content $pth -Raw) -replace "#import site","import site" | Set-Content $pth -Encoding ASCII
  if ((Get-Content $pth -Raw) -notmatch "ComfyUI") { Add-Content $pth "..\ComfyUI" -Encoding ASCII }
  Write-Ok "python_embeded 就绪"
} else { Write-Ok "已有 Python，跳过" }
& $Py --version

# pip
& $Py -m pip --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "  安装 pip..."
  $gp = Join-Path $Tmp "get-pip.py"
  if (-not (Get-File "https://bootstrap.pypa.io/get-pip.py" $gp)) { Write-Err2 "get-pip 下载失败" }
  & $Py $gp --no-warn-script-location 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Err2 "pip 安装失败" }
}
Write-Ok "pip 就绪"
$PipIdx = @{ cn = "https://pypi.tuna.tsinghua.edu.cn/simple"; intl = "https://pypi.org/simple" }[$Region]

# ---------------------------------------------------------- 4. PyTorch (CUDA)
Write-Step "4/7 PyTorch (CUDA)"
$needTorch = $true
try {
  $r = & $Py -c "import torch;print('cuda' if torch.cuda.is_available() else 'cpu')" 2>$null
  if ($r -eq "cuda") { $needTorch = $false }
} catch {}
if ($needTorch) {
  if ($Region -eq "cn") {
    foreach ($w in $Manifest.torch.wheels) {
      $out = Join-Path $Tmp $w
      if (-not (Test-Path $out)) {
        Write-Host "  分段下载 $w ..."
        & $Py (Join-Path $RepoDir "chunked_dl.py") ($Manifest.torch.wheels_dir_url_cn + [uri]::EscapeDataString($w)) $out 16 8
        if ($LASTEXITCODE -ne 0) { Write-Err2 "下载失败: $w" }
      }
    }
    $whls = (Get-ChildItem (Join-Path $Tmp "*.whl")).FullName
    & $Py -m pip install --force-reinstall --no-deps @whls --no-warn-script-location 2>&1 | Select-Object -Last 2
  } else {
    & $Py -m pip install torch torchvision torchaudio --index-url $Manifest.torch.intl_index_url --no-warn-script-location 2>&1 | Select-Object -Last 2
  }
  $r = & $Py -c "import torch;print('cuda' if torch.cuda.is_available() else 'cpu')" 2>$null
  if ($r -ne "cuda") { Write-Err2 "CUDA 不可用。请确认 N 卡驱动已装并重跑" }
}
Write-Ok "PyTorch CUDA 可用"

# ---------------------------------------------------------- 5. ComfyUI + 插件 + 依赖
Write-Step "5/7 ComfyUI 本体 / GGUF 插件 / 依赖"
$needComfy = $true
if (Test-Path "$Root\ComfyUI\main.py") {
  $cnt = (Get-ChildItem "$Root\ComfyUI" -Recurse -File -ErrorAction SilentlyContinue).Count
  if ($cnt -ge $Manifest.comfyui.min_file_count) { $needComfy = $false; Write-Ok "已有 ComfyUI（$cnt 个文件），跳过" }
  else { Write-W2 "已存在的 ComfyUI 文件数 $cnt 不足，重新下载补全" }
}
if ($needComfy) {
  $zip = Join-Path $Tmp "comfyui_src.zip"
  $got = $false
  foreach ($u in $Manifest.comfyui.urls) {
    if ($Region -eq "intl" -and $u -notmatch "github.com/comfyanonymous") { continue }
    Write-Host "  下载 $u"
    if (Get-File $u $zip) { $got = $true; break }
  }
  if (-not $got) { Write-Err2 "ComfyUI 源码包下载失败" }
  $ex = Join-Path $Tmp "comfyui_extract"
  if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
  & $Py -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" $zip $ex
  if ($LASTEXITCODE -ne 0) { Write-Err2 "解压失败（压缩包损坏）" }
  $srcRoot = (Get-ChildItem $ex -Directory | Select-Object -First 1).FullName
  $cnt = (Get-ChildItem $srcRoot -Recurse -File).Count
  foreach ($f in $Manifest.comfyui.must_exist) {
    if (-not (Test-Path (Join-Path $srcRoot $f))) { Write-Err2 "源码包不完整：缺少 $f（换个线路重跑）" }
  }
  if ($cnt -lt $Manifest.comfyui.min_file_count) { Write-Err2 "源码包不完整：仅 $cnt 个文件（< $($Manifest.comfyui.min_file_count)），换线路重跑" }
  if (Test-Path "$Root\ComfyUI") { Remove-Item "$Root\ComfyUI" -Recurse -Force }
  Move-Item $srcRoot "$Root\ComfyUI"
  Write-Ok "ComfyUI 就绪（$cnt 个文件，完整性已校验）"
}

# GGUF 插件
$plugDir = "$Root\ComfyUI\custom_nodes\ComfyUI-GGUF"
if (-not (Test-Path "$plugDir\nodes.py")) {
  $zip = Join-Path $Tmp "gguf_plugin.zip"; $got = $false
  foreach ($u in $Manifest.gguf_plugin.urls) {
    Write-Host "  下载 $u"
    if (Get-File $u $zip) { $got = $true; break }
  }
  if (-not $got) { Write-Err2 "GGUF 插件下载失败" }
  $ex = Join-Path $Tmp "gguf_extract"
  if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
  & $Py -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" $zip $ex
  New-Item -ItemType Directory -Force -Path "$Root\ComfyUI\custom_nodes" | Out-Null
  $inner = (Get-ChildItem $ex -Directory | Select-Object -First 1).FullName
  if (Test-Path $plugDir) { Remove-Item $plugDir -Recurse -Force }
  Move-Item $inner $plugDir
}
foreach ($f in $Manifest.gguf_plugin.must_exist) {
  if (-not (Test-Path (Join-Path $plugDir $f))) { Write-Err2 "插件文件缺失: $f" }
}
Write-Ok "ComfyUI-GGUF 插件就绪"

# pip 依赖
& $Py -m pip install gguf --index-url $PipIdx --no-warn-script-location 2>&1 | Out-Null
# 清华镜像可能缺 comfyui-workflow-templates-media-assets-02，先从官方源补上，避免依赖解析死循环
if ($Region -eq "cn") {
  $broken = $Manifest.pip_broken_on_tuna
  $code = Test-Http ("https://pypi.tuna.tsinghua.edu.cn/simple/" + ($broken -split "==")[0] + "/")
  if ($code -eq "404") {
    Write-Host "  预装镜像缺失包: $broken"
    & $Py -m pip install $broken --index-url "https://pypi.org/simple" --no-warn-script-location 2>&1 | Out-Null
  }
}
Write-Host "  安装 ComfyUI requirements..."
& $Py -m pip install -r "$Root\ComfyUI\requirements.txt" --index-url $PipIdx --no-warn-script-location 2>&1 | Select-Object -Last 2
if ($LASTEXITCODE -ne 0) { Write-Err2 "requirements 安装失败，查看上方报错" }
Write-Ok "依赖安装完成"

# ---------------------------------------------------------- 6. 模型下载 + 校验
if ($SkipModels) {
  Write-Step "6/7 模型下载（已跳过）"
} else {
  Write-Step "6/7 模型下载与校验（$Quant）"
  $srcOrder = @{ cn = @("modelscope","hf_mirror","huggingface"); intl = @("huggingface","modelscope") }[$Region]
  foreach ($m in $Manifest.models) {
    $name = $m.name -replace "\{QUANT\}", $Quant
    $dir = Join-Path $Root ("ComfyUI\models\" + $m.target)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir $name
    $variants = $m.variants
    $expectSize = if ($variants) { $variants.$Quant.size } else { $m.size }
    $expectSha  = if ($variants) { $variants.$Quant.sha256 } else { $m.sha256 }
    $need = $true
    if (Test-Path $dst) {
      if ((Get-Item $dst).Length -eq $expectSize) { $need = $false; Write-Ok "已存在: $name" }
    }
    if ($need) {
      $ok = $false
      foreach ($s in $srcOrder) {
        $u = $m.path_templates.$s -replace "\{QUANT\}", $Quant
        if (-not $u) { continue }
        Write-Host "  分段下载 [$s] $name"
        & $Py (Join-Path $RepoDir "chunked_dl.py") $u $dst 16 8
        if ($LASTEXITCODE -eq 0 -and (Get-Item $dst).Length -eq $expectSize) { $ok = $true; break }
        Write-W2 "线路 $s 失败，换下一条"
      }
      if (-not $ok) { Write-Err2 "模型下载失败: $name" }
    }
    if ($expectSha) {
      $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
      if ($h -ne $expectSha) { Write-Err2 "SHA256 不匹配: $name（文件损坏，删除后重跑）" }
      Write-Ok "SHA256 校验通过: $name"
    } else {
      Write-W2 "无预置哈希，仅校验大小: $name"
    }
  }
}

# ---------------------------------------------------------- 工作区文件
Write-Step "配置启动脚本与工作区"
$bat = @"
@echo off
rem ComfyUI 启动脚本；如遇显存不足(OOM)可再加 --lowvram
cd /d %~dp0
python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build
pause
"@
Set-Content (Join-Path $Root "run_nvidia_gpu.bat") $bat -Encoding ASCII
$ws = Join-Path $Root "workspace"
New-Item -ItemType Directory -Force -Path $ws, "$ws\outputs" | Out-Null
Copy-Item (Join-Path $RepoDir "gen.py") $ws -Force
Copy-Item (Join-Path $RepoDir "wan22_t2v_template.json") $ws -Force
Write-Ok "启动脚本: $Root\run_nvidia_gpu.bat"
Write-Ok "工作区:   $ws"

# ---------------------------------------------------------- 7. 冒烟测试
if ($SkipSmoke) {
  Write-Step "7/7 冒烟测试（已跳过）"
} else {
  Write-Step "7/7 启动服务 + 冒烟测试"
  $proc = Start-Process -FilePath $Py -ArgumentList "-s","ComfyUI\main.py","--windows-standalone-build" `
           -WorkingDirectory $Root -WindowStyle Hidden `
           -RedirectStandardOutput "$Root\logs\server_out.log" -RedirectStandardError "$Root\logs\server_err.log" -PassThru
  Write-Ok "ComfyUI 已后台启动 (PID $($proc.Id))，等待就绪..."
  $up = $false
  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep 5
    try {
      $st = Invoke-RestMethod "http://127.0.0.1:8188/system_stats" -TimeoutSec 5
      if ($st.system.comfyui_version) { $up = $true; break }
    } catch {}
  }
  if (-not $up) { Write-Err2 "服务 120 秒内未就绪，查看 $Root\logs\server_err.log" }
  Write-Ok "服务就绪: http://127.0.0.1:8188"
  Write-Host "  提交冒烟测试（512x288x33帧，约 3-5 分钟）..."
  & $Py (Join-Path $ws "gen.py") --prompt "A fluffy orange cat walks across a sunny meadow, cinematic" `
      --width 512 --height 288 --length 33 --seed 7 --out (Join-Path $ws "smoke_test.mp4") --timeout 2400
  if ($LASTEXITCODE -eq 0) { Write-Ok "冒烟测试通过！样例: $ws\smoke_test.mp4" }
  else { Write-W2 "冒烟测试失败，服务仍在运行，可手动重试或查看日志" }
}

# ---------------------------------------------------------- 完成
Write-Step "部署完成"
Write-Host @"
  ComfyUI:   $Root
  启动:      $Root\run_nvidia_gpu.bat  （网页界面 http://127.0.0.1:8188）
  生成视频:  $ws\gen.py  （用法: python gen.py --prompt `"描述`"）
  提示: 720p/81帧/4步约 5-8 分钟；480p 更快
"@ -ForegroundColor Green
