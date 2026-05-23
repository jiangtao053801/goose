# Goose Windows Desktop 构建脚本
# 用法: .\build-windows.ps1 [-WithLocalInference] [-SkipRustBuild] [-SkipPackage] [-Clean]
#
# 参数说明:
#   -WithLocalInference  尝试启用本地推理 (llama-cpp)，注意 MSVC 下可能编译失败
#   -SkipRustBuild       跳过 Rust 编译 (假设已编译完成)
#   -SkipPackage         跳过 Electron 打包 (只编译 Rust + 复制二进制)
#   -Clean               打包前清理 out 目录

param(
    [switch]$WithLocalInference,
    [switch]$SkipRustBuild,
    [switch]$SkipPackage,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Goose Windows Desktop 构建脚本" -ForegroundColor Cyan
Write-Host "   版本: 1.35.0" -ForegroundColor Cyan
Write-Host "   项目路径: $ScriptDir" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================
# Step 0: 环境检查
# ============================
Write-Host "[0/5] 检查构建环境..." -ForegroundColor Yellow

# 检查 Rust
try {
    $rustVer = rustc --version 2>$null
    Write-Host "  Rust: $rustVer" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Rust 未安装，请先安装 https://rustup.rs" -ForegroundColor Red
    exit 1
}

# 检查 Node.js
try {
    $nodeVer = node --version 2>$null
    Write-Host "  Node.js: $nodeVer" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Node.js 未安装" -ForegroundColor Red
    exit 1
}

# 检查 pnpm
try {
    $pnpmVer = pnpm --version 2>$null
    Write-Host "  pnpm: $pnpmVer" -ForegroundColor Green
} catch {
    Write-Host "  WARN: pnpm 未找到，尝试安装..." -ForegroundColor Yellow
    npm install -g pnpm
}

# 检查 UI 依赖是否已安装
$desktopDir = "$ScriptDir\ui\desktop"
if (-not (Test-Path "$desktopDir\node_modules\.pnpm")) {
    Write-Host "  前端依赖未安装，正在安装..." -ForegroundColor Yellow
    Set-Location "$ScriptDir\ui"
    pnpm install
    Set-Location $ScriptDir
} else {
    Write-Host "  前端依赖: 已安装" -ForegroundColor Green
}

Write-Host ""

# ============================
# Step 1: 编译 Rust 后端
# ============================
if (-not $SkipRustBuild) {
    Write-Host "[1/5] 编译 Rust 后端 (goosed + goose)..." -ForegroundColor Yellow

    $features = "code-mode,aws-providers,telemetry,otel,rustls-tls,system-keyring"
    $cargoBaseArgs = @("build", "--release")
    $cargoFeatureArgs = @("--no-default-features", "-F", $features)

    if ($WithLocalInference) {
        Write-Host "  模式: 包含本地推理 (llama-cpp) - 可能在 MSVC 下编译失败" -ForegroundColor Magenta
        $gooseServerArgs = @("build", "--release", "--bin", "goosed")
        $gooseCliArgs = @("build", "--release", "-p", "goose-cli")
    } else {
        Write-Host "  模式: 跳过本地推理 (无 llama-cpp) - 仅云端 Provider" -ForegroundColor Green
        $gooseServerArgs = @("build", "--release", "--bin", "goosed") + $cargoFeatureArgs
        $gooseCliArgs = @("build", "--release", "-p", "goose-cli") + $cargoFeatureArgs
    }

    Write-Host "  正在编译 goose-server (goosed.exe)..." -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & cargo $gooseServerArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: goose-server 编译失败" -ForegroundColor Red
        exit 1
    }
    $sw.Stop()
    Write-Host "  goose-server 编译完成，耗时: $([math]::Round($sw.Elapsed.TotalSeconds, 0))s" -ForegroundColor Green

    Write-Host "  正在编译 goose-cli (goose.exe)..." -ForegroundColor Cyan
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    & cargo $gooseCliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: goose-cli 编译失败" -ForegroundColor Red
        exit 1
    }
    $sw2.Stop()
    Write-Host "  goose-cli 编译完成，耗时: $([math]::Round($sw2.Elapsed.TotalSeconds, 0))s" -ForegroundColor Green
} else {
    Write-Host "[1/5] 跳过 Rust 编译 (--SkipRustBuild)" -ForegroundColor Yellow
}

Write-Host ""

# ============================
# Step 2: 复制二进制文件
# ============================
Write-Host "[2/5] 复制二进制文件到桌面应用..." -ForegroundColor Yellow

$binDir = "$desktopDir\src\bin"
$platformBinDir = "$desktopDir\src\platform\windows\bin"
$targetDir = "$ScriptDir\target\release"

foreach ($dir in @($binDir, $platformBinDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# 复制 goosed.exe
$goosedSrc = "$targetDir\goosed.exe"
if (Test-Path $goosedSrc) {
    Copy-Item -Path $goosedSrc -Destination "$binDir\goosed.exe" -Force
    Copy-Item -Path $goosedSrc -Destination "$platformBinDir\goosed.exe" -Force
    Write-Host "  复制 goosed.exe -> src/bin/ & src/platform/windows/bin/" -ForegroundColor Green
} else {
    Write-Host "  WARN: goosed.exe 未找到于 $goosedSrc" -ForegroundColor Yellow
    Write-Host "  请确保已完成 Step 1 编译" -ForegroundColor Yellow
}

# 复制 goose.exe
$gooseSrc = "$targetDir\goose.exe"
if (Test-Path $gooseSrc) {
    Copy-Item -Path $gooseSrc -Destination "$binDir\goose.exe" -Force
    Copy-Item -Path $gooseSrc -Destination "$platformBinDir\goose.exe" -Force
    Write-Host "  复制 goose.exe -> src/bin/ & src/platform/windows/bin/" -ForegroundColor Green
} else {
    Write-Host "  WARN: goose.exe 未找到于 $gooseSrc" -ForegroundColor Yellow
}

Write-Host ""

# ============================
# Step 3: 准备平台二进制文件
# ============================
Write-Host "[3/5] 准备 Windows 平台特定文件..." -ForegroundColor Yellow

Set-Location $desktopDir
$env:ELECTRON_PLATFORM = "win32"
node scripts/prepare-platform-binaries.js
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARN: 平台文件准备脚本出错（非致命，继续）" -ForegroundColor Yellow
}
Set-Location $ScriptDir
Write-Host ""

# ============================
# Step 4: 清理旧输出 (可选)
# ============================
if ($Clean) {
    Write-Host "[4/5] 清理旧的打包输出..." -ForegroundColor Yellow
    $outDir = "$desktopDir\out"
    if (Test-Path $outDir) {
        Remove-Item -Path $outDir -Recurse -Force
        Write-Host "  已清理 out 目录" -ForegroundColor Green
    }
} else {
    Write-Host "[4/5] 跳过清理 (使用 --Clean 可清理旧输出)" -ForegroundColor Yellow
}
Write-Host ""

# ============================
# Step 5: 打包 Electron 应用
# ============================
if (-not $SkipPackage) {
    Write-Host "[5/5] 打包 Electron 桌面应用..." -ForegroundColor Yellow

    Set-Location $desktopDir
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # electron-forge make 可能因 Node.js 版本兼容问题导致 ZIP 步骤失败
    # 先尝试 package（不创建 ZIP），成功后再手动压缩
    Write-Host "  运行 electron-forge package..." -ForegroundColor Cyan
    $packageResult = pnpm exec electron-forge package --platform=win32 --arch=x64 2>&1
    $packageExitCode = $LASTEXITCODE

    # 如果 package 成功，手动创建 ZIP
    $packagedDir = "$desktopDir\out\Goose-win32-x64"
    if ($packageExitCode -eq 0 -or (Test-Path $packagedDir)) {
        Write-Host "  Electron 打包成功!" -ForegroundColor Green
        
        # 手动创建 ZIP (绕过 Node.js v25 的 cross-zip 兼容性问题)
        $zipOutput = "$desktopDir\out\make\Goose-win32-x64.zip"
        $zipParent = Split-Path $zipOutput -Parent
        if (-not (Test-Path $zipParent)) {
            New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
        }
        
        Write-Host "  正在创建 ZIP 包..." -ForegroundColor Cyan
        # 先删除旧 ZIP
        if (Test-Path $zipOutput) {
            Remove-Item $zipOutput -Force
        }
        Compress-Archive -Path "$packagedDir\*" -DestinationPath $zipOutput -Force
        Write-Host "  ZIP 创建成功!" -ForegroundColor Green
    } else {
        # fallback: 尝试直接 make（旧 Node.js 版本可用）
        Write-Host "  package 失败，尝试 electron-forge make..." -ForegroundColor Yellow
        pnpm run make --platform=win32 --arch=x64
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Electron 打包失败" -ForegroundColor Red
            Write-Host "  常见原因: Node.js 版本不兼容 (项目要求 v24, 当前 v25+)" -ForegroundColor Yellow
            Write-Host "  建议: 使用 Node.js 24.x 或先确保 Rust 二进制已复制到 src/bin/" -ForegroundColor Yellow
            exit 1
        }
    }

    $sw.Stop()
    Write-Host "  打包完成，耗时: $([math]::Round($sw.Elapsed.TotalSeconds, 0))s" -ForegroundColor Green

    # 显示输出文件
    $outDir = "$desktopDir\out"
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "   构建完成! 输出文件:" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Cyan

    # 查找 ZIP 文件
    $zipFiles = Get-ChildItem -Path $outDir -Recurse -Filter "*.zip" -ErrorAction SilentlyContinue
    foreach ($zip in $zipFiles) {
        $sizeMB = [math]::Round($zip.Length / 1MB, 1)
        Write-Host "   $($zip.FullName) ($sizeMB MB)" -ForegroundColor White
    }

    # 查找 EXE 文件
    $exeFiles = Get-ChildItem -Path $outDir -Recurse -Filter "Goose.exe" -ErrorAction SilentlyContinue
    foreach ($exe in $exeFiles) {
        Write-Host "   $($exe.FullName)" -ForegroundColor White
    }
} else {
    Write-Host "[5/5] 跳过打包 (--SkipPackage)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  二进制文件已就绪: $binDir" -ForegroundColor Green
}

Set-Location $ScriptDir
Write-Host ""
Write-Host " ========== 全部完成! ==========" -ForegroundColor Green
