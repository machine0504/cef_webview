# 制作 Windows CEF「运行期下载包」(windows-x64.tar.gz)。
#
# 背景：make_cef_runtime.sh 依赖 bash/python，在 Windows 上不便；本 PowerShell 版
# 从官方 CEF 分发包的 Release/ 与 Resources/ 提取运行期文件，并入自编的 release
# subprocess，打成 <out>\<safeVer>\windows-x64.tar.gz，输出 size/sha256（用于手动
# 或脚本更新 manifest.json）。
#
# 用法（Windows PowerShell）：
#   powershell -NoProfile -File make_cef_runtime_windows.ps1 `
#     -CefRoot   <解压后的官方 CEF windows64 包目录(含 Release\ Resources\)> `
#     -Subprocess <release 的 cef_webview_subprocess.exe 路径> `
#     -Out        <输出目录(服务器根)> `
#     [-CefVersion 144.0.29+g0b1a012+chromium-144.0.7559.256]
param(
  [Parameter(Mandatory=$true)][string]$CefRoot,
  [Parameter(Mandatory=$true)][string]$Subprocess,
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$CefVersion = "144.0.29+g0b1a012+chromium-144.0.7559.256"
)
$ErrorActionPreference = "Stop"

$rel = Join-Path $CefRoot "Release"
$res = Join-Path $CefRoot "Resources"
if (-not (Test-Path $rel)) { throw "缺少 Release: $rel" }
if (-not (Test-Path $Subprocess)) { throw "缺少 subprocess: $Subprocess" }

$safeVer = $CefVersion -replace '\+','-'
$stage = Join-Path $env:TEMP ("cefwin_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $stage | Out-Null

# CEF 144 运行期 DLL（含新增 dxcompiler/dxil：D3D12 着色器编译，GPU 路径需要；
# 软件 OSR 不用但一并带上更稳）。snapshot_blob.bin 在 CEF 144 已并入 v8_context。
$relFiles = @(
  "libcef.dll","chrome_elf.dll","libEGL.dll","libGLESv2.dll",
  "vk_swiftshader.dll","vulkan-1.dll","d3dcompiler_47.dll",
  "dxcompiler.dll","dxil.dll",
  "vk_swiftshader_icd.json","v8_context_snapshot.bin"
)
foreach ($f in $relFiles) {
  $src = Join-Path $rel $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $stage $f) }
  else { Write-Warning "Release 缺少(跳过): $f" }
}

$resFiles = @("icudtl.dat","chrome_100_percent.pak","chrome_200_percent.pak","resources.pak")
foreach ($f in $resFiles) { Copy-Item (Join-Path $res $f) (Join-Path $stage $f) }

$localesDst = Join-Path $stage "locales"
New-Item -ItemType Directory -Force $localesDst | Out-Null
foreach ($l in @("zh-CN.pak","en-US.pak")) {
  Copy-Item (Join-Path $res "locales\$l") (Join-Path $localesDst $l)
}

Copy-Item $Subprocess (Join-Path $stage "cef_webview_subprocess.exe")

$pkgDir = Join-Path $Out $safeVer
New-Item -ItemType Directory -Force $pkgDir | Out-Null
$pkg = Join-Path $pkgDir "windows-x64.tar.gz"
Remove-Item -Force $pkg -ErrorAction SilentlyContinue
# Windows 10+ 自带 bsdtar，保留相对路径打包。
tar -czf $pkg -C $stage .
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

$sz = (Get-Item $pkg).Length
$sha = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
Write-Output ("WINPKG path=" + $pkg)
Write-Output ("WINPKG size=" + $sz + " sha256=" + $sha)
