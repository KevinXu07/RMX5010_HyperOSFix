param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('bootloader', 'fastbootd')]
  [string]$Stage,
  [string]$Fastboot = '',
  [string]$Images = '',
  [string]$Partitions = '',
  [switch]$CleanCow,
  [switch]$Repair
)
$ErrorActionPreference = 'Stop'
$pkg = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Fastboot)) { $Fastboot = Join-Path $pkg 'platform-tools\fastboot.exe' }
if ([string]::IsNullOrWhiteSpace($Images)) { $Images = Join-Path $pkg 'images' }
if (!(Test-Path -LiteralPath $Fastboot)) { throw "缺少 fastboot：$Fastboot" }
$targets = @($Partitions.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($targets.Count -eq 0) { throw '未提供目标分区列表' }

$script:fb = $Fastboot

function Invoke-Fb {
  param([string[]]$Arguments, [int]$TimeoutSeconds = 180)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:fb
  $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { throw "无法启动 fastboot：$script:fb" }
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill() } catch { }
    throw "fastboot $($Arguments -join ' ') 超时（${TimeoutSeconds}s），请检查数据线与设备状态"
  }
  $p.WaitForExit()
  return [pscustomobject]@{
    Output = ($outTask.Result + $errTask.Result)
    Exit   = $p.ExitCode
  }
}

function Get-Var {
  param([string]$Name, [int]$TimeoutSeconds = 20)
  $r = Invoke-Fb -Arguments @('getvar', $Name) -TimeoutSeconds $TimeoutSeconds
  $m = [regex]::Match(
    $r.Output,
    '(?im)^\s*(?:\(bootloader\)\s*)?' + [regex]::Escape($Name) + ':\s*(.+?)\s*$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Get-AllVars {
  return (Invoke-Fb -Arguments @('getvar', 'all') -TimeoutSeconds 90).Output
}

function Convert-Size([string]$Value) {
  if ($Value -match '^0x[0-9a-fA-F]+$') {
    return [Convert]::ToUInt64($Value.Substring(2), 16)
  }
  $n = 0L
  if ([Int64]::TryParse($Value, [ref]$n)) { return [UInt64]$n }
  return $null
}

function Get-PartitionSizes([string]$AllOutput) {
  $map = @{}
  foreach ($line in ($AllOutput -split "`r?`n")) {
    $m = [regex]::Match(
      $line,
      '^\s*(?:\(bootloader\)\s*)?partition-size:([^:\s]+):\s*(0x[0-9a-fA-F]+|\d+)\s*$')
    if ($m.Success) {
      $size = Convert-Size $m.Groups[2].Value
      if ($null -ne $size) { $map[$m.Groups[1].Value] = $size }
    }
  }
  return $map
}

function Get-PartitionHints([string]$AllOutput) {
  $set = New-Object System.Collections.Generic.HashSet[string]
  foreach ($line in ($AllOutput -split "`r?`n")) {
    $m = [regex]::Match(
      $line,
      '^\s*(?:\(bootloader\)\s*)?(?:partition-size|partition-type|has-slot|is-logical):([^:\s]+):')
    if ($m.Success) { [void]$set.Add($m.Groups[1].Value) }
  }
  return $set
}

function Format-Bytes([UInt64]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function Get-ImageSize([string]$Base) {
  $path = Join-Path $Images ($Base + '.img')
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "缺少镜像：$path（脚本不会继续刷写）"
  }
  return [UInt64](Get-Item -LiteralPath $path).Length
}

function Get-Slot {
  $slot = (Get-Var 'current-slot').Trim().TrimStart('_').ToLowerInvariant()
  if ($slot -notmatch '^(a|b)$') {
    throw '无法读取当前槽位 current-slot，本机应为 A/B 槽位设备，请检查数据线后重试'
  }
  return $slot
}

# ---------------------------------------------------------------- bootloader
if ($Stage -eq 'bootloader') {
  $product = Get-Var 'product'
  if ($product) { Write-Host "[设备] product = $product" } else { Write-Host '[设备] 未能读取 product 变量' }

  $slot = Get-Slot
  Write-Host "[设备] 当前槽位 = $slot"

  $unlocked = Get-Var 'unlocked'
  if ($unlocked) {
    Write-Host "[设备] 解锁状态 = $unlocked"
    if ($unlocked -match '^(no|false|0)$') {
      throw 'Bootloader 未解锁，禁止刷写'
    }
  }
  else {
    Write-Host '[设备] 未能读取解锁状态，交由 bootloader 自行校验'
  }

  $all = Get-AllVars
  $present = Get-PartitionHints $all
  if ($present.Count -eq 0) {
    Write-Host '[分区表] bootloader 未返回 getvar all 分区清单，改为逐个查询'
  }

  $missing = @()
  foreach ($name in $targets) {
    if ($present.Contains($name) -or $present.Contains($name + '_a') -or $present.Contains($name + '_b')) {
      continue
    }
    $type = Get-Var "partition-type:$name"
    $hasSlot = Get-Var "has-slot:$name"
    if ($type -or $hasSlot) { continue }
    $missing += $name
  }

  if ($missing.Count -gt 0 -and $missing.Count -eq $targets.Count) {
    Write-Host '[分区表] bootloader 完全无法读取分区信息，跳过分区存在性检查'
    exit 0
  }
  if ($missing.Count -gt 0) {
    throw ('设备缺少分区：' + ($missing -join '、') + '。刷写包与设备不匹配，已停止，未写入任何分区')
  }
  Write-Host ("[分区表] bootloader 阶段目标分区齐全（{0} 个）" -f $targets.Count)
  exit 0
}

# ----------------------------------------------------------------- fastbootd
$userspace = Get-Var 'is-userspace'
if ($userspace -notmatch '^(yes|true|1)$') {
  throw "设备不在 fastbootd（is-userspace=$userspace），无法刷写动态分区"
}
$slot = Get-Slot
Write-Host "[设备] fastbootd，当前槽位 = $slot"

$all = Get-AllVars
$sizes = Get-PartitionSizes $all

# 虚拟 A/B 的 COW 快照会占用 super 空间，导致动态分区扩容失败；先清掉。
$cowNames = @($sizes.Keys | Where-Object { $_ -match 'cow' })
if ($CleanCow -and $cowNames.Count -gt 0) {
  foreach ($cow in $cowNames) {
    Write-Host "[COW] 删除快照分区 $cow"
    $r = Invoke-Fb -Arguments @('delete-logical-partition', $cow) -TimeoutSeconds 60
    if ($r.Exit -ne 0 -and
        $r.Output -notmatch '(?i)not found|does not exist|no such partition|unknown partition') {
      throw "删除 COW 分区 $cow 失败：$($r.Output.Trim())"
    }
  }
  Write-Host "[COW] 已清理 $($cowNames.Count) 个快照分区"
  $all = Get-AllVars
  $sizes = Get-PartitionSizes $all
}
elseif ($cowNames.Count -gt 0) {
  Write-Host "[COW] 检测到 $($cowNames.Count) 个快照分区，未启用清理"
}

$plan = @()
$problems = @()
foreach ($name in $targets) {
  $slotted = $name + '_' + $slot
  $resolved = $null
  if ($sizes.ContainsKey($slotted)) { $resolved = $slotted }
  elseif ($sizes.ContainsKey($name)) { $resolved = $name }

  $imageSize = Get-ImageSize $name
  $partSize = if ($resolved) { [UInt64]$sizes[$resolved] } else { [UInt64]0 }

  $plan += [pscustomobject]@{
    Base      = $name
    Resolved  = $resolved
    ImageSize = $imageSize
    PartSize  = $partSize
  }

  if (-not $resolved) {
    $problems += "${name}：设备上没有该分区"
  }
  elseif ($partSize -lt $imageSize) {
    $problems += ("{0}：分区 {1} 小于镜像 {2}" -f $name, (Format-Bytes $partSize), (Format-Bytes $imageSize))
  }
}

$missingNames = @($plan | Where-Object { -not $_.Resolved } | ForEach-Object { $_.Base })
$smallNames = @($plan | Where-Object { $_.Resolved -and $_.PartSize -lt $_.ImageSize } | ForEach-Object { $_.Base })

if ($Repair -and $problems.Count -gt 0) {
  Write-Host "[修复] 需要重建的分区：$($problems -join '；')"
  $hasSlotted = @($sizes.Keys | Where-Object { $_ -match '_(a|b)$' }).Count -gt 0
  foreach ($item in $plan) {
    if ($item.Resolved -and $item.PartSize -ge $item.ImageSize) { continue }

    $targetName = if ($item.Resolved) { $item.Resolved }
    elseif ($hasSlotted) { $item.Base + '_' + $slot }
    else { $item.Base }

    if ($item.Resolved) {
      Write-Host "[修复] 删除逻辑分区 $targetName"
      $r = Invoke-Fb -Arguments @('delete-logical-partition', $targetName) -TimeoutSeconds 60
      if ($r.Exit -ne 0 -and
          $r.Output -notmatch '(?i)not found|does not exist|no such partition|unknown partition') {
        throw "删除分区 $targetName 失败：$($r.Output.Trim())"
      }
    }

    $wantBytes = [math]::Max([UInt64]$item.ImageSize, [UInt64]$item.PartSize)
    $wantMb = [UInt64][math]::Ceiling($wantBytes / 1MB)
    Write-Host "[修复] 创建逻辑分区 $targetName 约 ${wantMb} MB"
    $r = Invoke-Fb -Arguments @('create-logical-partition', $targetName, "$wantMb") -TimeoutSeconds 60
    if ($r.Exit -ne 0) {
      throw ("创建分区 $targetName 失败：{0}`n请确认 super 剩余空间是否足够（可先重启到 fastbootd 查看 getvar all）" -f $r.Output.Trim())
    }
    $created = Convert-Size ((Get-Var "partition-size:$targetName") -replace '\s', '')
    if ($null -ne $created) {
      Write-Host ("[修复] {0} 当前大小 {1}" -f $targetName, (Format-Bytes $created))
      if ($created -lt $item.ImageSize) {
        Write-Host ("[修复] 注意：{0} 仍小于镜像，fastboot 刷写时会自动扩容" -f $targetName)
      }
    }
  }
  $all = Get-AllVars
  $sizes = Get-PartitionSizes $all
  $plan = @()
  foreach ($name in $targets) {
    $slotted = $name + '_' + $slot
    $resolved = $null
    if ($sizes.ContainsKey($slotted)) { $resolved = $slotted }
    elseif ($sizes.ContainsKey($name)) { $resolved = $name }
    $imageSize = Get-ImageSize $name
    $partSize = if ($resolved) { [UInt64]$sizes[$resolved] } else { [UInt64]0 }
    $plan += [pscustomobject]@{
      Base      = $name
      Resolved  = $resolved
      ImageSize = $imageSize
      PartSize  = $partSize
    }
  }
  $missingNames = @($plan | Where-Object { -not $_.Resolved } | ForEach-Object { $_.Base })
  $smallNames = @($plan | Where-Object { $_.Resolved -and $_.PartSize -lt $_.ImageSize } | ForEach-Object { $_.Base })
}

if ($missingNames.Count -gt 0) {
  throw ("设备缺少逻辑分区：{0}。普通刷写无法继续，可用 force 参数重跑本脚本重建 super 逻辑分区" -f ($missingNames -join '、'))
}
if ($smallNames.Count -gt 0 -and -not $Repair) {
  Write-Host ("[分区表] 以下分区小于镜像，fastboot 刷写时会自动扩容：{0}" -f ($smallNames -join '、'))
}

foreach ($item in $plan) {
  Write-Host ("[分区] {0,-16} -> {1,-18} 镜像 {2,-10} 分区 {3}" -f
    ($item.Base + '.img'), $item.Resolved, (Format-Bytes $item.ImageSize), (Format-Bytes $item.PartSize))
}
Write-Host ("[分区表] fastbootd 阶段目标分区齐全（{0} 个），镜像大小校验通过" -f $plan.Count)
exit 0
