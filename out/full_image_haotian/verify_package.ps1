param([switch]$Strict, [switch]$IncludeSukisu)
$ErrorActionPreference = 'Stop'
$pkg = Split-Path -Parent $MyInvocation.MyCommand.Path
$imgDir = Join-Path $pkg 'images'
$hashFile = Join-Path $pkg 'metadata\sha256_images.txt'
if (!(Test-Path $hashFile)) { throw '缺少 metadata\sha256_images.txt 校验清单' }
$lines = Get-Content $hashFile | Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' }
$bad = 0
foreach ($line in $lines) {
  $line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' | Out-Null
  $want = $Matches[1].ToLowerInvariant(); $name = Split-Path $Matches[2] -Leaf
  $path = Join-Path $imgDir $name
  if (!(Test-Path $path)) { Write-Host "[缺失] $name" -ForegroundColor Red; $bad++; continue }
  $got = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($got -ne $want) { Write-Host "[校验失败] $name" -ForegroundColor Red; $bad++ }
  else { Write-Host "[通过] $name" }
}
if ($bad) { throw "有 $bad 个镜像校验失败，禁止继续刷入" }
# fastboot 只会给名字以 vbmeta 结尾的分区写 flags（vbmeta_system/vbmeta_vendor 不会被打上），
# 所以三件套必须预先打 flags=3，否则 first-stage 会按链式 vbmeta 的 hashtree 建 dm-verity 而挂载失败。
foreach ($vb in 'vbmeta.img','vbmeta_system.img','vbmeta_vendor.img') {
  $path = Join-Path $imgDir $vb
  $b = [System.IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 124 -or [System.Text.Encoding]::ASCII.GetString($b,0,4) -ne 'AVB0') { throw "$vb 不是 AVB 镜像" }
  $flags = ([uint32]$b[120] -shl 24) -bor ([uint32]$b[121] -shl 16) -bor ([uint32]$b[122] -shl 8) -bor [uint32]$b[123]
  if ($flags -ne 3) { throw "$vb flags=0x$('{0:x}' -f $flags)，必须为 0x3（disable-verification + hashtree-disabled）" }
  Write-Host "[通过] $vb flags=0x3"
}
if ($Strict -and $lines.Count -ne 54) { throw "校验清单应包含 54 个镜像，实际为 $($lines.Count) 个" }
if ($Strict -and (Get-ChildItem $imgDir -Filter '*.raw.img')) { throw 'images/ 中不得包含 raw 构建中间文件' }
if ($IncludeSukisu) {
  $sukisuPath = Join-Path $pkg 'optional\init_boot_sukisu.img'
  if (!(Test-Path -LiteralPath $sukisuPath -PathType Leaf)) { throw '缺少 optional\init_boot_sukisu.img' }
  $sukisuHash = (Get-FileHash -LiteralPath $sukisuPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "[通过] optional\init_boot_sukisu.img sha256=$sukisuHash"
}
Write-Host "OS4 RMX5010 haotian OS4.0.0.19 包校验通过，共 $($lines.Count) 个镜像。"
