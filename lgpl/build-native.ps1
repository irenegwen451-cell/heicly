<#
  Builds Heicly's RELEASE native libraries from the official source releases:
    libheif.dll     libheif, HEIF container + ONLY the built-in libde265 HEVC decoder (no encoders, no plugins)
    libde265.dll    libde265 HEVC decoder (separate DLL, linked dynamically by libheif: LGPL)
    libwebp.dll     libwebp encoder/decoder (WebPEncodeBGRA, WebPEncodeLosslessBGRA, WebPFree, ...)
    libsharpyuv.dll libwebp's RGB->YUV helper, split out of libwebp.dll by upstream
  into native\win-x64\ and native\win-arm64\ (picked up by src\Heicly.Core\Heicly.Core.csproj).

  This script is also the "build scripts and build flags" of the LGPL source offer (THIRD-PARTY-NOTICES.txt
  section 4): it pins the exact source tarballs and toolchain by version and SHA-256.

  Nothing is installed system-wide. Portable tools go to .tools\toolchain, source tarballs to .tools\downloads
  (each extracted into its own fresh folder), build trees to .tools\native-build.
  Toolchain: llvm-mingw (clang + lld + UCRT, cross-compiles x86_64 and aarch64 Windows), CMake, Ninja.
  The C/C++ runtime (libc++, libunwind, compiler-rt, winpthreads) is linked statically, so the DLLs depend on
  Windows system DLLs (KERNEL32, UCRT api-ms-win-crt-*) and on each other only.

  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-native.ps1 [-Rid x64|arm64|all] [-Clean]
#>
param(
  [ValidateSet('x64', 'arm64', 'all')]
  [string]$Rid = 'all',
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$ToolDir = Join-Path $Root '.tools\toolchain'
$DownloadDir = Join-Path $Root '.tools\downloads'
$BuildRoot = Join-Path $Root '.tools\native-build'
$OutRoot = Join-Path $Root 'native'

# ---- Pinned versions and SHA-256 of every download ---------------------------------------------------------------
# GitHub release assets: SHA-256 from the release's published asset digest (CMake also publishes cmake-*-SHA-256.txt).
# libwebp: Google publishes only a GPG signature (.asc) next to the tarball; the SHA-256 below was computed from the
# tarball downloaded from the official release bucket, whose GPG signature (libwebp-1.6.0.tar.gz.asc) was checked
# against the "WebP release signing key" 6B0E 6B70 976D E303 EDF2  F601 F9C3 D6BD B823 2B5D.
$Toolchain = @(
  @{ Name = 'llvm-mingw'; Version = '20261104'
     Url = 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261104/llvm-mingw-20261104-ucrt-x86_64.zip'
     Sha256 = '552191b5754c49a5a20723276a6fc56541ea1922c4c50b7b669022333fc1b40f' },
  @{ Name = 'cmake'; Version = '4.5.0'
     Url = 'https://github.com/Kitware/CMake/releases/download/v4.5.0/cmake-4.5.0-windows-x86_64.zip'
     Sha256 = '301b1728317ccd84e984b02e366a8293735bc5ac618757d3d8f58b578f062411' },
  @{ Name = 'ninja'; Version = '1.13.2'
     Url = 'https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip'
     Sha256 = '07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65' }
)
$Sources = @(
  @{ Name = 'libde265'; Version = '1.1.3'
     Url = 'https://github.com/strukturag/libde265/releases/download/v1.1.3/libde265-1.1.3.tar.gz'
     Sha256 = '554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905' },
  @{ Name = 'libheif'; Version = '1.23.7'
     Url = 'https://github.com/strukturag/libheif/releases/download/v1.23.7/libheif-1.23.7.tar.gz'
     Sha256 = 'f7483e818503ea6224c8863e4a56ac02c7089021a98472c811c12aa19faf2475' },
  @{ Name = 'libwebp'; Version = '1.6.0'
     Url = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz'
     Sha256 = 'e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564' }
)

function Get-Verified($item) {
  $file = Join-Path $DownloadDir ([IO.Path]::GetFileName($item.Url))
  if (-not (Test-Path $file)) {
    Write-Host "Downloading $($item.Url)"
    Invoke-WebRequest -Uri $item.Url -OutFile "$file.part" -UseBasicParsing
    Move-Item "$file.part" $file -Force
  }
  $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -ne $item.Sha256) {
    Remove-Item $file -Force
    throw "SHA-256 mismatch for $file`n  expected $($item.Sha256)`n  actual   $hash (file deleted)"
  }
  return $file
}

# Extracts an archive into a NEW folder (deleted first if it exists) and returns the single top-level folder in it.
function Expand-Fresh([string]$archive, [string]$dest) {
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force $dest | Out-Null
  & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $dest
  if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $archive" }
  $top = @(Get-ChildItem $dest -Directory)
  if ($top.Count -eq 1) { return $top[0].FullName }
  return $dest
}

function Invoke-Checked([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($exe)) failed ($LASTEXITCODE): $($arguments -join ' ')" }
}

New-Item -ItemType Directory -Force $ToolDir, $DownloadDir, $BuildRoot | Out-Null

# ---- Toolchain ---------------------------------------------------------------------------------------------------
$toolHome = @{}
foreach ($t in $Toolchain) {
  $dest = Join-Path $ToolDir "$($t.Name)-$($t.Version)"
  $stamp = Join-Path $dest '.sha256'
  if (-not ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $t.Sha256))) {
    $archive = Get-Verified $t
    Write-Host "Extracting $($t.Name) $($t.Version)"
    [void](Expand-Fresh $archive $dest)
    Set-Content $stamp $t.Sha256 -Encoding ASCII
  }
  $top = @(Get-ChildItem $dest -Directory)
  $toolHome[$t.Name] = if ($top.Count -eq 1) { $top[0].FullName } else { $dest }
}
$LlvmBin = Join-Path $toolHome['llvm-mingw'] 'bin'
$CMake = Join-Path $toolHome['cmake'] 'bin\cmake.exe'
$Ninja = Join-Path $toolHome['ninja'] 'ninja.exe'
foreach ($p in @($CMake, $Ninja, (Join-Path $LlvmBin 'clang.exe'))) { if (-not (Test-Path $p)) { throw "Tool missing: $p" } }
# Process-local only: the build must find llvm-mingw's tools (llvm-rc, lld...). Nothing is written to the user's PATH.
$env:PATH = "$LlvmBin;$(Split-Path $CMake);$(Split-Path $Ninja);$env:SystemRoot\System32;$env:SystemRoot"
foreach ($v in @('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'PKG_CONFIG_PATH', 'CMAKE_PREFIX_PATH', 'INCLUDE', 'LIB')) {
  Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

# ---- Sources -----------------------------------------------------------------------------------------------------
$src = @{}
foreach ($s in $Sources) {
  $archive = Get-Verified $s
  $dest = Join-Path $DownloadDir "$($s.Name)-$($s.Version)-src"
  $stamp = Join-Path $dest '.sha256'
  if (-not ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $s.Sha256))) {
    Write-Host "Extracting $($s.Name) $($s.Version)"
    [void](Expand-Fresh $archive $dest)
    Set-Content $stamp $s.Sha256 -Encoding ASCII
  }
  $top = @(Get-ChildItem $dest -Directory)
  $src[$s.Name] = $top[0].FullName
}

# ---- Build -------------------------------------------------------------------------------------------------------
# Release (-O2), static C/C++ runtime, no build-path or timestamp leakage into the DLLs.
function Build-Rid([string]$rid) {
  $triple = if ($rid -eq 'arm64') { 'aarch64-w64-mingw32' } else { 'x86_64-w64-mingw32' }
  $cpu = if ($rid -eq 'arm64') { 'ARM64' } else { 'AMD64' }
  $work = Join-Path $BuildRoot "win-$rid"
  if ($Clean -and (Test-Path $work)) { Remove-Item $work -Recurse -Force }
  $prefix = Join-Path $work 'prefix'
  # Fresh install prefix on every run: stale headers/DLLs from an earlier run (or an earlier pinned version) must never
  # be found by CMake or copied into native\.
  if (Test-Path $prefix) { Remove-Item $prefix -Recurse -Force }
  New-Item -ItemType Directory -Force $work, $prefix | Out-Null

  $tc = Join-Path $work 'toolchain.cmake'
  $bin = $LlvmBin -replace '\\', '/'
  $pfx = $prefix -replace '\\', '/'
  $map = "-ffile-prefix-map=$(($Root -replace '\\', '/'))=."
  @"
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $cpu)
set(CMAKE_C_COMPILER "$bin/$triple-clang.exe")
set(CMAKE_CXX_COMPILER "$bin/$triple-clang++.exe")
set(CMAKE_RC_COMPILER "$bin/$triple-windres.exe")
set(CMAKE_AR "$bin/llvm-ar.exe")
set(CMAKE_RANLIB "$bin/llvm-ranlib.exe")
set(CMAKE_STRIP "$bin/llvm-strip.exe")
set(CMAKE_FIND_ROOT_PATH "$pfx")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS_INIT "$map")
set(CMAKE_CXX_FLAGS_INIT "$map")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static -Wl,--no-insert-timestamp -Wl,--gc-sections")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
"@ | Set-Content $tc -Encoding ASCII

  $common = @("-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=$($Ninja -replace '\\', '/')", "-DCMAKE_TOOLCHAIN_FILE=$($tc -replace '\\', '/')",
    "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=$pfx", "-DCMAKE_PREFIX_PATH=$pfx", "-DBUILD_SHARED_LIBS=ON",
    "-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON")

  function Build-One([string]$name, [string[]]$options) {
    Write-Host "==== $name for win-$rid" -ForegroundColor Cyan
    $b = Join-Path $work $name
    if (Test-Path $b) { Remove-Item $b -Recurse -Force }
    Invoke-Checked $CMake (@('-S', $src[$name], '-B', $b) + $common + $options)
    Invoke-Checked $CMake @('--build', $b, '--parallel')
    Invoke-Checked $CMake @('--install', $b, '--strip')
  }

  Build-One 'libde265' @('-DENABLE_SDL=OFF', '-DENABLE_DECODER=OFF', '-DENABLE_ENCODER=OFF')

  # Every codec except the built-in libde265 decoder is off; no plugin loading, no examples/tests/gdk-pixbuf.
  Build-One 'libheif' @(
    '-DWITH_LIBDE265=ON', '-DWITH_LIBDE265_PLUGIN=OFF', '-DENABLE_PLUGIN_LOADING=OFF',
    '-DWITH_X265=OFF', '-DWITH_X264=OFF', '-DWITH_X265_PLUGIN=OFF', '-DWITH_KVAZAAR=OFF', '-DWITH_KVAZAAR_PLUGIN=OFF',
    '-DWITH_AOM_DECODER=OFF', '-DWITH_AOM_ENCODER=OFF', '-DWITH_DAV1D=OFF', '-DWITH_RAV1E=OFF', '-DWITH_SvtEnc=OFF',
    '-DWITH_OpenH264_DECODER=OFF', '-DWITH_OpenH264_ENCODER=OFF', '-DWITH_FFMPEG_DECODER=OFF',
    '-DWITH_JPEG_DECODER=OFF', '-DWITH_JPEG_ENCODER=OFF', '-DWITH_OpenJPEG_DECODER=OFF', '-DWITH_OpenJPEG_ENCODER=OFF',
    '-DWITH_OPENJPH_DECODER=OFF', '-DWITH_OPENJPH_ENCODER=OFF', '-DWITH_UVG266=OFF', '-DWITH_VVDEC=OFF', '-DWITH_VVENC=OFF',
    '-DWITH_LIBSHARPYUV=OFF', '-DWITH_UNCOMPRESSED_CODEC=OFF', '-DWITH_HEADER_COMPRESSION=OFF',
    '-DWITH_GDK_PIXBUF=OFF', '-DWITH_EXAMPLES=OFF', '-DWITH_EXAMPLE_HEIF_VIEW=OFF', '-DBUILD_TESTING=OFF',
    '-DWITH_FUZZERS=OFF', '-DBUILD_DOCUMENTATION=OFF', '-DENABLE_EXPERIMENTAL_FEATURES=OFF')

  Build-One 'libwebp' @(
    '-DWEBP_BUILD_ANIM_UTILS=OFF', '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF', '-DWEBP_BUILD_GIF2WEBP=OFF',
    '-DWEBP_BUILD_IMG2WEBP=OFF', '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF', '-DWEBP_BUILD_WEBPMUX=OFF',
    '-DWEBP_BUILD_EXTRAS=OFF', '-DWEBP_BUILD_LIBWEBPMUX=OFF', '-DWEBP_USE_THREAD=ON', '-DWEBP_LINK_STATIC=OFF')

  $out = Join-Path $OutRoot "win-$rid"
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Force $out | Out-Null
  foreach ($dll in @('libheif.dll', 'libde265.dll', 'libwebp.dll', 'libsharpyuv.dll')) {
    $found = Join-Path $prefix "bin\$dll"
    # libwebp.dll imports libsharpyuv.dll (split out upstream since 1.3): both are required.
    if (-not (Test-Path $found)) { throw "Expected output missing: $found" }
    Copy-Item $found $out
  }
  Test-Rid $rid $out
}

# ---- Verification ------------------------------------------------------------------------------------------------
$SystemDll = '^(kernel32|user32|advapi32|bcrypt|ntdll|ole32|shell32|ws2_32|ucrtbase|api-ms-win-[a-z0-9-]+)\.dll$'
$OurDll = '^(libheif|libde265|libwebp|libsharpyuv)\.dll$'
$RequiredExports = @{
  'libheif.dll' = @('heif_init', 'heif_get_version', 'heif_context_alloc', 'heif_context_read_from_memory_without_copy',
    'heif_get_global_security_limits', 'heif_context_get_security_limits', 'heif_context_set_security_limits',
    'heif_decode_image', 'heif_image_get_plane_readonly2', 'heif_image_get_decoding_warnings')
  'libde265.dll' = @('de265_new_decoder', 'de265_get_version')
  'libwebp.dll' = @('WebPEncodeBGRA', 'WebPEncodeLosslessBGRA', 'WebPFree', 'WebPGetEncoderVersion')
}

function Test-Rid([string]$rid, [string]$dir) {
  $readobj = Join-Path $LlvmBin 'llvm-readobj.exe'
  $wantMachine = if ($rid -eq 'arm64') { 0xAA64 } else { 0x8664 }
  $problems = @()
  foreach ($f in Get-ChildItem $dir -Filter *.dll) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $machine = [BitConverter]::ToUInt16($b, $pe + 4)
    if ($machine -ne $wantMachine) { $problems += ('{0}: machine 0x{1:X4}, expected 0x{2:X4}' -f $f.Name, $machine, $wantMachine) }

    $imports = @(& $readobj --coff-imports $f.FullName | Select-String '^\s*Name:\s*(\S+\.dll)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    foreach ($i in $imports) {
      if ($i -notmatch $SystemDll -and $i -notmatch $OurDll) { $problems += "$($f.Name): unexpected dependency $i" }
      elseif ($i -match $OurDll -and -not (Test-Path (Join-Path $dir $i))) { $problems += "$($f.Name): imports $i, which is not in $dir" }
    }
    $exports = @(& $readobj --coff-exports $f.FullName | Select-String '^\s*Name:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($RequiredExports.ContainsKey($f.Name)) {
      foreach ($e in $RequiredExports[$f.Name]) { if ($exports -notcontains $e) { $problems += "$($f.Name): missing export $e" } }
    }
    Write-Host ('  {0,-16} 0x{1:X4} {2,10:N0} bytes  imports: {3}' -f $f.Name, $machine, $f.Length, ($imports -join ', '))
  }
  $heifImports = & $readobj --coff-imports (Join-Path $dir 'libheif.dll') | Out-String
  if ($heifImports -notmatch 'libde265\.dll') { $problems += 'libheif.dll does not import libde265.dll (must be dynamic)' }
  if ($problems.Count) { $problems | ForEach-Object { Write-Host "  FAIL: $_" -ForegroundColor Red }; throw "Verification failed for win-$rid" }
  Write-Host "  PASS: win-$rid machine type, dependencies and exports" -ForegroundColor Green
}

$rids = if ($Rid -eq 'all') { @('x64', 'arm64') } else { @($Rid) }
foreach ($r in $rids) { Build-Rid $r }

$check = Join-Path $Root 'tools\check-licences.ps1'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $check -Path $OutRoot
if ($LASTEXITCODE -ne 0) { throw 'Licence check failed on native\' }
Write-Host 'Native release libraries are in native\win-<rid>\' -ForegroundColor Green
