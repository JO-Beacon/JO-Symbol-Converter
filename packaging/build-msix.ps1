#Requires -Version 5.1
<#
.SYNOPSIS
  从 Flutter 的 Windows Release 产物生成 Microsoft Store 用的 MSIX 包。

.DESCRIPTION
  - 版本号由 pubspec.yaml 的 `version:` 推导，第三段之后补 .0（MSIX 要求四段、第四段为 0）。
  - 图标由 assets/images/jo_symbol_converter_icon.png 缩放生成，无需手工准备多套尺寸。
  - 只做打包，不做签名；Store 会用自己的证书重签，本地测试可用 -Sign 自签。

.EXAMPLE
  pwsh -File packaging\build-msix.ps1

.EXAMPLE
  pwsh -File packaging\build-msix.ps1 -Sign -PfxPath .\test.pfx -PfxPassword (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
  [string]$Configuration = 'Release',
  [string]$Version,
  [string]$OutDir,
  [switch]$Store,
  [switch]$NoBuild,
  [switch]$Sign,
  [string]$PfxPath,
  [securestring]$PfxPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packagingDir = $PSScriptRoot
$projectRoot = Split-Path $packagingDir -Parent
if (-not $OutDir) { $OutDir = Join-Path $packagingDir 'out' }

function Get-MsixVersion {
  param([string]$Root)
  $pubspec = Join-Path $Root 'pubspec.yaml'
  $line = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
  if (-not $line) { throw "pubspec.yaml 里找不到 version 字段" }
  $raw = $line.Matches[0].Groups[1].Value.Trim()
  $noBuild = ($raw -split '\+')[0]
  $parts = $noBuild.Split('.')
  if ($parts.Count -lt 3) { throw "版本号 $raw 不是 x.y.z 形式" }
  return "$($parts[0]).$($parts[1]).$($parts[2]).0"
}

function Get-SdkTool {
  param([string]$Name)
  $kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
  $candidates = Get-ChildItem $kits -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending
  foreach ($c in $candidates) {
    $p = Join-Path $c.FullName "x64\$Name"
    if (Test-Path $p) { return $p }
  }
  throw "找不到 $Name，请确认已安装 Windows SDK"
}

function Export-Logo {
  param(
    [System.Drawing.Image]$Source,
    [int]$Width,
    [int]$Height,
    [string]$Destination,
    [int]$IconSize = 0
  )
  $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    if ($IconSize -gt 0) {
      $x = [int](($Width - $IconSize) / 2)
      $y = [int](($Height - $IconSize) / 2)
      $g.DrawImage($Source, $x, $y, $IconSize, $IconSize)
    } else {
      $g.DrawImage($Source, 0, 0, $Width, $Height)
    }
  } finally {
    $g.Dispose()
    $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
  }
}

$msixVersion = if ($Version) { $Version } else { Get-MsixVersion -Root $projectRoot }
if ($msixVersion -notmatch '^\d+\.\d+\.\d+\.0$') {
  throw "MSIX 版本号必须是 x.y.z.0，当前为 $msixVersion"
}

if (-not $NoBuild) {
  $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
  $flutter = if ($flutterCmd) { $flutterCmd.Source } else { 'C:\flutter\bin\flutter.bat' }
  if (-not (Test-Path $flutter)) { throw "找不到 flutter，无法构建；可用 -NoBuild 直接打包已有产物" }
  $buildArgs = @('build', 'windows', '--release')
  if ($Store) { $buildArgs += '--dart-define=STORE_BUILD=true' }
  $label = if ($Store) { '商店版本' } else { '普通版本' }
  Write-Host "构建$label ..." -ForegroundColor Cyan
  & $flutter @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "flutter build 失败（退出码 $LASTEXITCODE）" }
}

$sourceDir = Join-Path $projectRoot "build\windows\x64\runner\$Configuration"
if (-not (Test-Path (Join-Path $sourceDir 'jo_symbol_converter.exe'))) {
  throw "找不到构建产物：$sourceDir。请先运行 flutter build windows --release"
}

$makeappx = Get-SdkTool -Name 'makeappx.exe'
$layoutDir = Join-Path $packagingDir '.layout'
if (Test-Path $layoutDir) { Remove-Item $layoutDir -Recurse -Force }
New-Item -ItemType Directory -Path $layoutDir | Out-Null

Write-Host "复制构建产物 ..." -ForegroundColor Cyan
Copy-Item (Join-Path $sourceDir '*') $layoutDir -Recurse -Force

Write-Host "生成图标 ..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$assetsDir = Join-Path $layoutDir 'Assets'
New-Item -ItemType Directory -Path $assetsDir | Out-Null
$iconPath = Join-Path $projectRoot 'assets\images\jo_symbol_converter_icon.png'
$source = [System.Drawing.Image]::FromFile($iconPath)
try {
  Export-Logo -Source $source -Width 44 -Height 44 -Destination (Join-Path $assetsDir 'Square44x44Logo.png')
  Export-Logo -Source $source -Width 150 -Height 150 -Destination (Join-Path $assetsDir 'Square150x150Logo.png')
  Export-Logo -Source $source -Width 310 -Height 310 -Destination (Join-Path $assetsDir 'Square310x310Logo.png')
  Export-Logo -Source $source -Width 50 -Height 50 -Destination (Join-Path $assetsDir 'StoreLogo.png')
  Export-Logo -Source $source -Width 310 -Height 150 -Destination (Join-Path $assetsDir 'Wide310x150Logo.png') -IconSize 150
} finally {
  $source.Dispose()
}

Write-Host "写入 AppxManifest.xml（版本 $msixVersion）..." -ForegroundColor Cyan
$manifest = Get-Content (Join-Path $packagingDir 'AppxManifest.xml') -Raw -Encoding UTF8
$manifest = $manifest.Replace('@@VERSION@@', $msixVersion)
$manifestPath = Join-Path $layoutDir 'AppxManifest.xml'
[System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outName = "JO-SymbolConverter_${msixVersion}_x64.msix"
$outPath = Join-Path $OutDir $outName
if (Test-Path $outPath) { Remove-Item $outPath -Force }

Write-Host "打包 ..." -ForegroundColor Cyan
& $makeappx pack /d $layoutDir /p $outPath /o
if ($LASTEXITCODE -ne 0) { throw "makeappx 打包失败（退出码 $LASTEXITCODE）" }

if ($Sign) {
  if (-not $PfxPath) { throw "使用 -Sign 时必须提供 -PfxPath" }
  $signtool = Get-SdkTool -Name 'signtool.exe'
  Write-Host "签名 ..." -ForegroundColor Cyan
  $signArgs = @('sign', '/fd', 'SHA256', '/f', (Resolve-Path $PfxPath).Path)
  if ($PfxPassword) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
    try {
      $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
      $signArgs += @('/p', $plain)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
  $signArgs += $outPath
  & $signtool @signArgs
  if ($LASTEXITCODE -ne 0) { throw "signtool 签名失败（退出码 $LASTEXITCODE）" }
}

$sizeMb = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
Write-Host ""
Write-Host "完成：$outPath（$sizeMb MB）" -ForegroundColor Green
Write-Host "本地测试安装：Add-AppxPackage -Path '$outPath' -AllowUnsigned" -ForegroundColor DarkGray
