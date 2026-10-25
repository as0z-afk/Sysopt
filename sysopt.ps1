<#
.SYNOPSIS
  sysopt for Windows — the same commands and the same safety contract as the
  POSIX core, implemented natively so no WSL, no MSYS and no remote script is
  needed.

.DESCRIPTION
  Safety contract (identical to lib/sysopt.sh):
    1. Nothing is written unless -Apply is given. Default is plan.
    2. Every write is backed up and recorded in a manifest.
    3. Writes are journalled before they happen, so an interrupted run is
       detectable with `doctor`.
    4. Merges are add-only; existing values are never overwritten.
    5. Anything a power service owns is skipped, never raced.
    6. A feature that does not exist here reports `not-supported` with a reason.
    7. `revert` restores original bytes.

.EXAMPLE
  .\sysopt.ps1 detect
  .\sysopt.ps1 plan
  .\sysopt.ps1 apply -Apply
  .\sysopt.ps1 verify
  .\sysopt.ps1 revert -All -Apply
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('detect','list','plan','apply','verify','status','doctor','revert','version','help')]
  [string]$Command = 'help',

  [switch]$Apply,
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$All,
  [string[]]$Only,
  [string]$Id,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$script:SysoptVersion = '1.1.0'
$script:SysoptName    = 'sysopt'

# ---------------------------------------------------------------- state ---
function Get-StateDir {
  if ($env:SYSOPT_STATE) { return $env:SYSOPT_STATE }
  $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
  return (Join-Path $base 'sysopt')
}
# A leftover word on the command line is a mistake, never a silent no-op.
# (This is how "-Apply" used to disappear when a caller splatted a string array.)
if ($Rest -and $Rest.Count -gt 0) {
  Write-Host ("[x] unexpected argument: " + ($Rest -join ' ')) -ForegroundColor Red
  Write-Host "    see: .\sysopt.ps1 help" -ForegroundColor Red
  exit 2
}

$StateDir  = Get-StateDir
# Test/CI seam, identical in spirit to the POSIX --root: when set, every system
# path is read from under this directory and nothing outside it is touched.
$script:Root = if ($env:SYSOPT_ROOT) { $env:SYSOPT_ROOT } else { '' }
$Manifest  = Join-Path $StateDir 'manifest.tsv'
$Journal   = Join-Path $StateDir 'journal.log'
$BackupDir = Join-Path $StateDir 'backups'

# plan is the default; -DryRun always wins, even next to -Apply
$script:PlanOnly = (-not $Apply.IsPresent) -or $DryRun.IsPresent

function Write-Say  { param($m) Write-Host $m }
function Write-Ok   { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2 { param($m) Write-Host "[x] $m" -ForegroundColor Red }
function Write-Dim  { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
function Write-Hdr  { param($m) Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Write-Kv   { param($k,$v) Write-Host ("  {0,-26} {1}" -f $k, $v) }

# fields[2..] joined, safely, for any field count
function Get-Rest {
  param($Fields)
  if ($Fields.Count -le 2) { return '' }
  return ($Fields[2..($Fields.Count - 1)] -join ' ')
}

function Ensure-State { if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null } }

function Write-Journal {
  param([string]$kind, [string]$id)
  Ensure-State
  $line = "{0}`t{1}`t{2}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $kind, $id
  Add-Content -Path $Journal -Value $line -Encoding UTF8
}

function Get-JournalPending {
  if (-not (Test-Path $Journal)) { return @() }
  $open = @{}
  foreach ($l in Get-Content $Journal) {
    $f = $l -split "`t"
    if ($f.Count -lt 3) { continue }
    if ($f[1] -eq 'begin') { $open[$f[2]] = 1 }
    if ($f[1] -eq 'done')  { $open.Remove($f[2]) }
  }
  return @($open.Keys)
}

function Set-Manifest {
  param([string]$id, [string]$kind, [string]$path, [string]$backup, [string]$note = '')
  Ensure-State
  $rows = @()
  if (Test-Path $Manifest) {
    $rows = @(Get-Content $Manifest | Where-Object { $_ -and (($_ -split "`t")[0] -ne $id) })
  }
  $rows += ("{0}`t{1}`t{2}`t{3}`t0`t{4}" -f $id, $kind, $path, $backup, $note)
  Set-Content -Path $Manifest -Value $rows -Encoding UTF8
}

function Get-ManifestRow {
  param([string]$id)
  if (-not (Test-Path $Manifest)) { return $null }
  foreach ($l in Get-Content $Manifest) {
    if (-not $l) { continue }
    $f = $l -split "`t"
    if ($f.Count -ge 4 -and $f[0] -eq $id) { return $f }
  }
  return $null
}

# field 5 of a manifest row: 'created' means sysopt made the file itself
function Get-ManifestNote {
  param([string]$id)
  $f = Get-ManifestRow $id
  if ($f -and $f.Count -ge 6) { return $f[5] }
  return ''
}

# Take a backup once per id, and never overwrite an existing backup.
function Save-Original {
  param([string]$id, [string]$path)
  $row = Get-ManifestRow $id
  if ($row -and $row[3] -and $row[3] -ne '-' -and (Test-Path $row[3])) { return $row[3] }
  return (Backup-File $id $path)
}

function Remove-ManifestRow {
  param([string]$id)
  if (-not (Test-Path $Manifest)) { return }
  $rows = @(Get-Content $Manifest | Where-Object { $_ -and (($_ -split "`t")[0] -ne $id) })
  Set-Content -Path $Manifest -Value $rows -Encoding UTF8
}

function Backup-File {
  param([string]$id, [string]$path)
  $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
  $dir = Join-Path $BackupDir $ts
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $safe = ($path -replace '[\\/:]', '_')
  $dest = Join-Path $dir ("{0}__{1}" -f $id, $safe)
  Copy-Item -LiteralPath $path -Destination $dest -Force
  return $dest
}

# ------------------------------------------------------------ detection ---
# True on Windows PowerShell and on PowerShell 7 running on Windows.
$script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)

function Get-CimSafe {
  param([string]$Class)
  # PowerShell 7 on Linux/macOS has no CIM provider; never let that be fatal.
  if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return $null }
  try { return (Get-CimInstance $Class -ErrorAction SilentlyContinue) } catch { return $null }
}

function Get-PlatformInfo {
  $arch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE }
          elseif ($env:HOSTTYPE) { $env:HOSTTYPE } else { 'unknown' }
  $norm = switch ($arch) {
    'AMD64'   { 'x86_64' }
    'x86'     { 'x86_32' }
    'ARM64'   { 'aarch64' }
    'ARM'     { 'arm32' }
    'x86_64'  { 'x86_64' }
    'aarch64' { 'aarch64' }
    'arm64'   { 'aarch64' }
    default {
      if (-not $script:OnWindows -and (Get-Command uname -ErrorAction SilentlyContinue)) {
        (& uname -m) -replace 'armv7l', 'arm32' -replace 'i686', 'x86_32'
      } else { "unknown:$arch" }
    }
  }
  $os  = Get-CimSafe 'Win32_OperatingSystem'
  $cpu = Get-CimSafe 'Win32_Processor' | Select-Object -First 1
  [pscustomobject]@{
    Os        = if ($script:OnWindows) { 'windows' } else { 'non-windows' }
    OsName    = if ($os) { $os.Caption } else { [System.Environment]::OSVersion.VersionString }
    OsVersion = if ($os) { $os.Version } else { '' }
    Arch      = $norm
    ArchRaw   = $arch
    Cpu       = if ($cpu) { $cpu.Name.Trim() } else { 'unknown' }
    Cores     = [System.Environment]::ProcessorCount
    RamMB     = if ($os) { [int]($os.TotalVisibleMemorySize / 1024) } else { 0 }
    CanWrite  = $script:OnWindows
    IsAdmin   = if ($script:OnWindows) {
                  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                } else { $false }
  }
}

# -------------------------------------------------------------- actions ---
function Get-HostsNames {
  @(
    'doubleclick.net','googlesyndication.com','googleadservices.com','google-analytics.com',
    'amazon-adsystem.com','adsrvr.org','criteo.com','adnxs.com','rubiconproject.com',
    'taboola.com','outbrain.com','scorecardresearch.com','quantserve.com','moatads.com',
    'graph.facebook.com','pixel.facebook.com','analytics.twitter.com','static.ads-twitter.com',
    'bat.bing.com'
  )
}

$BeginMark = '# BEGIN sysopt managed block'
$EndMark   = '# END sysopt managed block'

function Get-HostsPath {
  if ($script:Root) { return (Join-Path $script:Root 'etc/hosts') }
  return (Join-Path $env:SystemRoot 'System32/drivers/etc/hosts')
}

function Invoke-HostsBlock {
  param([string]$Phase)
  $hf = Get-HostsPath
  switch ($Phase) {
    { $_ -in 'plan','apply' } {
      $lines = if (Test-Path $hf) { Get-Content -LiteralPath $hf } else { @() }
      $keep = New-Object System.Collections.Generic.List[string]
      $skip = $false
      foreach ($l in $lines) {
        if ($l.StartsWith($BeginMark)) { $skip = $true;  continue }
        if ($l.StartsWith($EndMark))   { $skip = $false; continue }
        if (-not $skip) { $keep.Add($l) }
      }
      while ($keep.Count -gt 0 -and [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) {
        $keep.RemoveAt($keep.Count - 1)
      }
      $names = Get-HostsNames
      $out = New-Object System.Collections.Generic.List[string]
      $out.AddRange($keep)
      if ($keep.Count -gt 0) { $out.Add('') }
      $out.Add($BeginMark)
      $out.Add("# generated by $script:SysoptName $script:SysoptVersion — remove this whole block to revert")
      $out.Add('# exact hostnames only; A and AAAA records for every name')
      foreach ($n in $names) { $out.Add("0.0.0.0 $n"); $out.Add(":: $n") }
      $out.Add($EndMark)

      Write-Hdr "hosts block: $hf"
      Write-Dim "names $($names.Count), records $($names.Count * 2)"
      if ($script:PlanOnly) { Write-Dim '  [dry-run] not written'; return 0 }

      if (-not $script:Root -and -not (Get-PlatformInfo).IsAdmin) { Write-Err2 'hosts file needs an elevated shell'; return 1 }
      # compare the way the file will actually be read back: Set-Content adds a
      # trailing newline, so compare trimmed line sets, not raw strings
      $existing = if (Test-Path $hf) { @(Get-Content -LiteralPath $hf) } else { @() }
      $normOld = ($existing -join "`n").TrimEnd("`r","`n")
      $normNew = ($out      -join "`n").TrimEnd("`r","`n")
      if ((Test-Path $hf) -and ($normOld -eq $normNew)) {
        Write-Ok "$hf already current"; return 0
      }
      $existed = Test-Path $hf
      $bkp = if ($existed) { Save-Original 'hosts' $hf } else { '-' }
      if ($existed -and (-not $bkp -or -not (Test-Path $bkp))) {
        Write-Err2 "cannot back up $hf — refusing to write"; return 1
      }
      $note = if ($existed) { 'managed block' } else { 'created' }
      Write-Journal 'begin' 'hosts'
      Set-Content -LiteralPath $hf -Value $out -Encoding ASCII
      Write-Journal 'done' 'hosts'
      Set-Manifest 'hosts' 'file' $hf $bkp $note
      Write-Ok "$hf written"
      return 0
    }
    'verify' {
      if (-not (Test-Path $hf)) { return "FAIL`thosts block`tmissing" }
      $c = Get-Content -LiteralPath $hf
      $b = @($c | Where-Object { $_.StartsWith($BeginMark) }).Count
      $e = @($c | Where-Object { $_.StartsWith($EndMark) }).Count
      if ($b -ne 1 -or $e -ne 1) { return "FAIL`thosts block`t$b begin / $e end markers" }
      $missing = @()
      foreach ($n in Get-HostsNames) {
        if (-not ($c -contains "0.0.0.0 $n")) { $missing += $n }
        if (-not ($c -contains ":: $n"))      { $missing += "$n (AAAA)" }
      }
      if ($missing.Count -gt 0) { return "FAIL`thosts block`tmissing: $($missing -join ' ')" }
      return "PASS`thosts block`t1 block, every name has A and AAAA"
    }
    'revert' {
      if (-not (Test-Path $hf)) { Write-Ok 'no hosts file'; return 0 }
      $row = Get-ManifestRow 'hosts'
      if ($script:PlanOnly) { Write-Dim "  [dry-run] would restore $hf"; return 0 }
      if (-not $script:Root -and -not (Get-PlatformInfo).IsAdmin) { Write-Err2 'needs an elevated shell'; return 1 }
      if ($row -and $row[3] -ne '-' -and $row[3] -and (Test-Path $row[3])) {
        Copy-Item -LiteralPath $row[3] -Destination $hf -Force
        Write-Ok "$hf restored from backup"
      } elseif ((Get-ManifestNote 'hosts') -eq 'created') {
        Remove-Item -LiteralPath $hf -Force
        Write-Ok "$hf removed (sysopt created it)"
      } else {
        $keep = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($l in Get-Content -LiteralPath $hf) {
          if ($l.StartsWith($BeginMark)) { $skip = $true;  continue }
          if ($l.StartsWith($EndMark))   { $skip = $false; continue }
          if (-not $skip) { $keep.Add($l) }
        }
        Set-Content -LiteralPath $hf -Value $keep -Encoding ASCII
        Write-Ok "managed block removed from $hf"
      }
      Remove-ManifestRow 'hosts'
      return 0
    }
  }
}

function Get-FirefoxProfiles {
  $root = if ($script:Root) { Join-Path $script:Root 'profiles' }
          else { Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles' }
  if (-not (Test-Path $root)) { return @() }
  Get-ChildItem -Path $root -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName 'prefs.js')) -or (Test-Path (Join-Path $_.FullName 'times.json'))
  } | ForEach-Object { $_.FullName }
}

$UserJsBegin = '// BEGIN sysopt managed prefs'
$UserJsEnd   = '// END sysopt managed prefs'
$PrefLines = @(
  @('browser.sessionstore.interval','600000'),
  @('browser.tabs.unloadOnLowMemory','true'),
  @('dom.ipc.processCount','4'),
  @('media.hardware-video-decoding.enabled','true'),
  @('toolkit.telemetry.enabled','false'),
  @('datareporting.healthreport.uploadEnabled','false'),
  @('network.dns.disablePrefetch','true'),
  @('network.prefetch-next','false'),
  @('browser.newtab.preload','false'),
  @('extensions.pocket.enabled','false')
)

function Invoke-FirefoxUserJs {
  param([string]$Phase)
  $profiles = @(Get-FirefoxProfiles)
  if ($profiles.Count -eq 0) {
    if ($Phase -eq 'verify') { return 'SKIP`tfirefox user.js`tno profile found' }
    Write-Dim '  no Firefox profile found — skipped'; return 0
  }
  switch ($Phase) {
    { $_ -in 'plan','apply' } {
      foreach ($p in $profiles) {
        $src = Join-Path $p 'user.js'
        $lines = if (Test-Path $src) { Get-Content -LiteralPath $src } else { @() }
        $outside = New-Object System.Collections.Generic.List[string]
        $inside  = New-Object System.Collections.Generic.List[string]
        $s = $false
        foreach ($l in $lines) {
          if ($l.StartsWith($UserJsBegin)) { $s = $true;  continue }
          if ($l.StartsWith($UserJsEnd))   { $s = $false; continue }
          if ($s) { $inside.Add($l) } else { $outside.Add($l) }
        }
        while ($outside.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outside[$outside.Count - 1])) {
          $outside.RemoveAt($outside.Count - 1)
        }
        $out = New-Object System.Collections.Generic.List[string]
        $out.AddRange($outside)
        $out.Add($UserJsBegin)
        $out.Add("// generated by $script:SysoptName $script:SysoptVersion — delete this whole block to revert")
        $kept = @()
        foreach ($pf in $PrefLines) {
          $k = $pf[0]; $v = $pf[1]
          if ($outside | Where-Object { $_ -match [regex]::Escape("user_pref(`"$k`"") }) { $kept += $k; continue }
          $out.Add("user_pref(`"$k`", $v);")
        }
        $out.Add($UserJsEnd)

        Write-Hdr "firefox profile: $p"
        if ($kept.Count -gt 0) { Write-Dim "  keeping your own value for: $($kept -join ' ')" }
        if ($script:PlanOnly) { Write-Dim '  [dry-run] not written'; continue }
        if ((Test-Path $src) -and ((Get-Content -LiteralPath $src) -join "`n") -eq ($out -join "`n")) {
          Write-Ok "$src already current"; continue
        }
        $jid = "userjs-$([IO.Path]::GetFileName($p))"
        $existed = Test-Path $src
        $bkp = if ($existed) { Save-Original $jid $src } else { '-' }
        if ($existed -and (-not $bkp -or -not (Test-Path $bkp))) {
          Write-Err2 "cannot back up $src — refusing to write"; continue
        }
        $note = if ($existed) { '' } else { 'created' }
        Write-Journal 'begin' $jid
        Set-Content -LiteralPath $src -Value $out -Encoding UTF8
        Write-Journal 'done'  $jid
        Set-Manifest $jid 'file' $src $bkp $note
        Write-Ok "$src written"
      }
      return 0
    }
    'verify' {
      $rows = @()
      foreach ($p in $profiles) {
        $src = Join-Path $p 'user.js'
        if (-not (Test-Path $src)) { $rows += "FAIL`tfirefox user.js`t$src missing"; continue }
        $c = @(Get-Content -LiteralPath $src | Where-Object { $_.StartsWith($UserJsBegin) }).Count
        if ($c -eq 1) { $rows += "PASS`tfirefox user.js`t$([IO.Path]::GetFileName($p))" }
        else { $rows += "FAIL`tfirefox user.js`t$([IO.Path]::GetFileName($p)) has $c block(s)" }
      }
      return ($rows -join "`n")
    }
    'revert' {
      foreach ($p in $profiles) {
        $src = Join-Path $p 'user.js'
        if (-not (Test-Path $src)) { continue }
        if ($script:PlanOnly) { Write-Dim "  [dry-run] would revert $src"; continue }
        $jid = "userjs-$([IO.Path]::GetFileName($p))"
        $row = Get-ManifestRow $jid
        if ($row -and $row[3] -ne '-' -and $row[3] -and (Test-Path $row[3])) {
          Copy-Item -LiteralPath $row[3] -Destination $src -Force
          Write-Ok "$src restored"
        } elseif ((Get-ManifestNote $jid) -eq 'created') {
          Remove-Item -LiteralPath $src -Force
          Write-Ok "$src removed (sysopt created it)"
        } else {
          $keep = New-Object System.Collections.Generic.List[string]
          $s = $false
          foreach ($l in Get-Content -LiteralPath $src) {
            if ($l.StartsWith($UserJsBegin)) { $s = $true;  continue }
            if ($l.StartsWith($UserJsEnd))   { $s = $false; continue }
            if (-not $s) { $keep.Add($l) }
          }
          Set-Content -LiteralPath $src -Value $keep -Encoding UTF8
          Write-Ok "managed block removed from $src"
        }
        Remove-ManifestRow "userjs-$([IO.Path]::GetFileName($p))"
      }
      return 0
    }
  }
}

function Invoke-ReportPower {
  param([string]$Phase)
  $scheme = 'unavailable'
  if (Get-Command powercfg -ErrorAction SilentlyContinue) {
    try { $scheme = (powercfg /getactivescheme) -join ' ' } catch { $scheme = 'unavailable' }
  }
  $svc = @()
  if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
    foreach ($s in 'Power','SysMain') {
      $o = Get-Service -Name $s -ErrorAction SilentlyContinue
      if ($o) { $svc += "$s=$($o.Status)" }
    }
  }
  if ($Phase -eq 'verify') { return "PASS`tpower state`t$scheme" }
  Write-Hdr 'power state (read-only)'
  Write-Kv 'active scheme' $scheme
  Write-Kv 'services' ($svc -join ' ')
  Write-Dim '  sysopt never changes the power scheme; use powercfg or the vendor tool'
  return 0
}

# actions table: id -> supported here, needs admin, summary
$Actions = [ordered]@{
  'hosts_block'    = @{ Supported = $true;  Admin = $true;  Summary = 'Block a fixed ad/tracker hostname list in the Windows hosts file' }
  'firefox_userjs' = @{ Supported = $true;  Admin = $false; Summary = 'Managed prefs block inside each Firefox profile user.js' }
  'report_power'   = @{ Supported = $true;  Admin = $false; Summary = 'Report the active power scheme; changes nothing' }
  'firefox_policy' = @{ Supported = $false; Admin = $true;  Summary = 'Not implemented on Windows: Firefox reads policy from the registry (HKLM\SOFTWARE\Policies\Mozilla\Firefox); use the ADMX templates instead' }
  'swappiness'     = @{ Supported = $false; Admin = $true;  Summary = 'Not applicable: Windows has no vm.swappiness' }
}

# ------------------------------------------------------------ win tweaks ---
# The curated half of "the ultimate utility tool": a short list of registry
# values, each one captured before it is written and restored exactly on
# revert. No service is disabled, no app is removed, no security control is
# touched, nothing here needs a reboot.
#
# Adding one is a data edit, not a code edit — that is on purpose.
$WinTweaks = [ordered]@{
  'wu_telemetry' = @{
    Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    Name = 'AllowTelemetry'; Type = 'DWord'; Value = 0
    Summary = 'Policy: send no optional diagnostic data (0 = Security only)'
  }
  'wu_consumer' = @{
    Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    Name = 'DisableWindowsConsumerFeatures'; Type = 'DWord'; Value = 1
    Summary = 'Stop Windows silently installing promoted Store apps'
  }
  'wu_delivery_lan' = @{
    Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    Name = 'DODownloadMode'; Type = 'DWord'; Value = 1
    Summary = 'Limit update delivery to your own network (1 = LAN only)'
  }
  'wu_bing_search' = @{
    Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Search'
    Name = 'BingSearchEnabled'; Type = 'DWord'; Value = 0
    Summary = 'Stop web results from appearing in Start menu search'
  }
  'wu_tips' = @{
    Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Name = 'SoftLandingEnabled'; Type = 'DWord'; Value = 0
    Summary = 'Stop Windows tips and suggestion popups'
  }
  'wu_sync_ads' = @{
    Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Name = 'ShowSyncProviderNotifications'; Type = 'DWord'; Value = 0
    Summary = 'Stop File Explorer advertising Microsoft 365'
  }
}

foreach ($k in $WinTweaks.Keys) {
  $needsAdmin = ($WinTweaks[$k].Hive -eq 'HKLM')
  $Actions[$k] = @{ Supported = $script:OnWindows; Admin = $needsAdmin; Summary = $WinTweaks[$k].Summary }
}

function Get-RegValue {
  param([string]$Path, [string]$Name)
  $res = [pscustomobject]@{ Exists = $false; Type = ''; Value = $null }
  if (-not (Test-Path $Path)) { return $res }
  $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $res }
  $prop = $item.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $res }
  $res.Exists = $true
  $res.Type   = $prop.TypeNameOfValue
  $res.Value  = $prop.Value
  return $res
}

function ConvertTo-Note {
  param($State, $Type)
  if (-not $State.Exists) { return 'prior=0' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$State.Value))
  return "prior=1|$Type|$b64"
}

function ConvertFrom-Note {
  param([string]$Note)
  $out = [pscustomobject]@{ Existed = $false; Type = ''; Value = $null }
  if (-not $Note) { return $out }
  $f = $Note -split '\|'
  if ($f.Count -ge 1 -and $f[0] -eq 'prior=1') {
    $out.Existed = $true
    if ($f.Count -ge 3) {
      $out.Type = $f[1]
      $out.Value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($f[2]))
      if ($out.Type -like 'Int*') { $out.Value = [int]$out.Value }
    }
  }
  return $out
}

function Invoke-RegTweak {
  param([string]$Id, [string]$Phase)

  # A registry cannot be staged under SYSOPT_ROOT, so off Windows this action
  # reports rather than pretends — even when a staging root is set.
  if (-not $script:OnWindows) {
    if ($Phase -eq 'verify') { return "SKIP`t$Id`tregistry is Windows-only" }
    Write-Dim "  $Id`: registry is Windows-only"
    return 0
  }

  $t = $WinTweaks[$Id]
  if (-not $t) { Write-Err2 "unknown tweak: $Id"; return 2 }

  $path = "$($t.Hive):\$($t.Key)"
  $cur  = Get-RegValue -Path $path -Name $t.Name
  $want = $t.Value

  if ($Phase -eq 'verify') {
    if ($cur.Exists -and "$($cur.Value)" -eq "$want") {
      return "PASS`t$Id`t$( $t.Name ) = $want"
    }
    if (-not $cur.Exists) { return "FAIL`t$Id`t$($t.Name) is not set" }
    return "FAIL`t$Id`t$($t.Name) = $($cur.Value), want $want"
  }

  if ($Phase -eq 'revert') {
    $note = Get-ManifestNote $Id
    if (-not $note) {
      Write-Warn2 "$Id is not in the manifest — leaving the registry alone"
      return 1
    }
    $prior = ConvertFrom-Note $note
    if ($script:PlanOnly) { Write-Dim "  [dry-run] would restore $($t.Hive)\$($t.Key)\$($t.Name)"; return 0 }
    if (-not $script:OnWindows) { Write-Err2 'this port runs on Windows only'; return 1 }
    $needsAdmin = ($t.Hive -eq 'HKLM')
    if ($needsAdmin -and -not $script:Root -and -not (Get-PlatformInfo).IsAdmin) {
      Write-Err2 "$Id needs an elevated shell"; return 1
    }
    Write-Journal 'begin' "$Id-revert"
    try {
      if ($prior.Existed) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name $t.Name -Value $prior.Value -Force
        Write-Ok "$($t.Name) restored to its previous value"
      } else {
        if (Test-Path $path) {
          Remove-ItemProperty -Path $path -Name $t.Name -Force -ErrorAction SilentlyContinue
          Write-Ok "$($t.Name) removed (it did not exist before sysopt)"
        }
      }
      Write-Journal 'done' "$Id-revert"
      Remove-ManifestRow $Id
    } catch {
      Write-Journal 'abort' "$Id-revert"
      Write-Err2 "revert failed: $($_.Exception.Message)"
      return 1
    }
    return 0
  }

  # plan | apply
  Write-Hdr "$Id — $($t.Summary)"
  Write-Dim "  $($t.Hive)\$($t.Key)"
  if ($cur.Exists) { Write-Dim "  $($t.Name): $($cur.Value)  ->  $want" }
  else             { Write-Dim "  $($t.Name): (not set)  ->  $want" }

  if ($script:PlanOnly) { Write-Dim '  [dry-run] not written'; return 0 }
  if (-not $script:OnWindows) { Write-Err2 'this port runs on Windows only'; return 1 }

  $needsAdmin = ($t.Hive -eq 'HKLM')
  if ($needsAdmin -and -not $script:Root -and -not (Get-PlatformInfo).IsAdmin) {
    Write-Err2 "$Id writes to HKLM and needs an elevated shell"; return 1
  }
  if ($cur.Exists -and "$($cur.Value)" -eq "$want") {
    Write-Ok "$($t.Name) already has the wanted value"; return 0
  }

  $note = ConvertTo-Note $cur $t.Type
  Write-Journal 'begin' $Id
  try {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $t.Name -Value $want -Force
    Write-Journal 'done' $Id
    Set-Manifest $Id 'registry' "$path\$($t.Name)" '-' $note
    Write-Ok "$($t.Name) = $want"
  } catch {
    Write-Journal 'abort' $Id
    Write-Err2 "write failed: $($_.Exception.Message)"
    return 1
  }
  return 0
}

function Get-TargetActions {
  if ($Only -and $Only.Count -gt 0) { return @($Only) }
  return @($Actions.Keys)
}

function Invoke-Action {
  param([string]$Id, [string]$Phase)
  if (-not $script:OnWindows -and -not $script:Root) {
    # this port manages Windows files; on anything else it reports, it does not write
    if ($Phase -eq 'verify') { return "SKIP`t$Id`tnot supported on non-windows" }
    Write-Dim "  $Id`: not supported here (this port is Windows-only)"
    return 0
  }
  switch ($Id) {
    'hosts_block'    { return Invoke-HostsBlock $Phase }
    'firefox_userjs' { return Invoke-FirefoxUserJs $Phase }
    'report_power'   { return Invoke-ReportPower $Phase }
    default {
      if ($Id -like 'wu_*') { return (Invoke-RegTweak -Id $Id -Phase $Phase) }
      if ($Phase -eq 'verify') { return "SKIP`t$Id`tnot supported on windows" }
      Write-Dim "  $Id`: not supported on windows"
      return 0
    }
  }
}

# ------------------------------------------------------------- commands ---
function Show-Help {
@"
sysopt $script:SysoptVersion — portable, reversible system tuning (Windows)

usage: .\sysopt.ps1 <command> [-Apply] [-Yes] [-Only id1,id2]

commands
  detect    describe this machine and what is supported here
  list      list actions
  plan      show every change (default; writes nothing)
  apply     make the changes            (requires -Apply)
  verify    PASS/FAIL per item
  status    what is applied and where
  doctor    read-only diagnosis, including interrupted writes
  revert    undo one action (-Only id) or everything (-All), requires -Apply
  version   version and platform

safety
  * nothing is written without -Apply
  * every write is backed up, journalled, and listed in a manifest
  * existing values are never overwritten
  * revert restores the original file
"@
}

function Invoke-Detect {
  $p = Get-PlatformInfo
  Write-Hdr "$script:SysoptName $script:SysoptVersion — system"
  Write-Kv 'os'            "$($p.Os) ($($p.OsName))"
  Write-Kv 'os version'    $p.OsVersion
  Write-Kv 'architecture'  "$($p.Arch) (raw: $($p.ArchRaw))"
  Write-Kv 'cpu'           $p.Cpu
  Write-Kv 'cores'         $p.Cores
  Write-Kv 'ram total'     "$($p.RamMB) MB"
  Write-Kv 'elevated'      $p.IsAdmin
  Write-Kv 'powershell'    $PSVersionTable.PSVersion
  Write-Hdr 'capabilities on this platform'
  foreach ($k in $Actions.Keys) {
    $a = $Actions[$k]
    $st = if (-not $script:OnWindows)      { 'not-supported' }
          elseif ($a.Supported)            { 'available' }
          else                             { 'not-supported' }
    Write-Host ("  {0,-18} {1,-14} {2}" -f $k, $st, $a.Summary)
  }
  if (-not $script:OnWindows -and -not $script:Root) {
    Write-Dim '  this port is for Windows; the POSIX engine (bin/sysopt) is the one for this host'
  }
  return 0
}

function Invoke-Plan  { $rc = 0; foreach ($a in Get-TargetActions) { Invoke-Action $a 'plan'  | Out-Null }; return $rc }
function Invoke-ApplyAll {
  if ($script:PlanOnly) { Write-Warn2 '-DryRun given: showing the plan only'; return (Invoke-Plan) }
  foreach ($a in Get-TargetActions) { $r = Invoke-Action $a 'apply'; if ($r -is [int] -and $r -ne 0) { return $r } }
  return 0
}

function Invoke-Verify {
  Write-Hdr 'verification'
  $fails = 0
  foreach ($a in Get-TargetActions) {
    $r = Invoke-Action $a 'verify'
    foreach ($line in ("$r" -split "`n")) {
      if (-not $line) { continue }
      $f = $line -split "`t"
      switch ($f[0]) {
        'PASS' { Write-Host ("  {0}PASS{1} {2,-18} {3}" -f '','', $f[1], (Get-Rest $f)) -ForegroundColor Green }
        'FAIL' { Write-Host ("  FAIL {0,-18} {1}" -f $f[1], (Get-Rest $f)) -ForegroundColor Red; $fails++ }
        'WARN' { Write-Host ("  WARN {0,-18} {1}" -f $f[1], (Get-Rest $f)) -ForegroundColor Yellow }
        'SKIP' { Write-Host ("  SKIP {0,-18} {1}" -f $f[1], (Get-Rest $f)) -ForegroundColor DarkGray }
      }
    }
  }
  if ($fails -eq 0) { Write-Ok 'no failures'; return 0 }
  Write-Err2 "$fails check(s) failed"; return 1
}

function Invoke-Status {
  Write-Hdr "$script:SysoptName $script:SysoptVersion — status"
  Write-Kv 'state dir' $StateDir
  $n = if (Test-Path $Manifest) { (Get-Content $Manifest | Where-Object { $_ }).Count } else { 0 }
  Write-Kv 'manifest'  "$n item(s)"
  if (Test-Path $Manifest) {
    Write-Hdr 'managed items'
    Get-Content $Manifest | ForEach-Object {
      $f = $_ -split "`t"; Write-Host ("  {0,-24} {1,-10} {2}" -f $f[0], $f[1], $f[2])
    }
  }
  $p = @(Get-JournalPending)
  if ($p.Count -gt 0) { Write-Warn2 "interrupted: $($p -join ' ')" }
  return 0
}

function Invoke-Doctor {
  Write-Hdr 'doctor — read-only'
  $warn = 0
  $p = @(Get-JournalPending)
  if ($p.Count -gt 0) { Write-Warn2 "interrupted operation(s): $($p -join ' ')"; $warn++ }
  else { Write-Ok 'journal clean (no interrupted writes)' }
  if (Test-Path $Manifest) {
    $missing = 0
    foreach ($l in Get-Content $Manifest) {
      $f = $l -split "`t"
      if ($f.Count -ge 3 -and $f[2] -and -not (Test-Path $f[2])) { Write-Warn2 "manifest lists $($f[0]) but $($f[2]) is gone"; $missing++ }
    }
    if ($missing -eq 0) { Write-Ok 'every managed path is present' }
    $warn += $missing
  } else { Write-Ok 'nothing applied yet' }
  if ($warn -eq 0) { Write-Ok 'no known-harmful state'; return 0 }
  Write-Warn2 "$warn item(s) need attention"
  return 0
}

function Invoke-Revert {
  $targets = @()
  if ($All)                          { $targets = @($Actions.Keys) }
  elseif ($Only -and $Only.Count)    { $targets = @($Only) }
  elseif ($Id)                       { $targets = @($Id) }

  if ($targets.Count -eq 0) {
    Write-Err2 'usage: .\sysopt.ps1 revert -Id <action> | -All   (add -Apply to actually revert)'
    return 2
  }
  foreach ($t in $targets) {
    if (-not $Actions.Contains($t)) { Write-Err2 "unknown action: $t"; return 2 }
    Invoke-Action $t 'revert' | Out-Null
  }
  if ($script:PlanOnly) { Write-Dim '  [dry-run] nothing was reverted — re-run with -Apply' }
  else { Write-Ok "reverted: $($targets -join ' ')" }
  return 0
}

# ------------------------------------------------------------- dispatch ---
switch ($Command) {
  'detect'  { exit (Invoke-Detect) }
  'list'    {
    $pi = Get-PlatformInfo
    Write-Hdr "actions on $($pi.Os)/$($pi.Arch)"
    foreach ($k in $Actions.Keys) {
      $a = $Actions[$k]
      $st = if ($script:OnWindows -and $a.Supported) { 'available' } else { 'not-supported' }
      Write-Host ("  {0,-18} {1,-14} {2}" -f $k, $st, $a.Summary)
    }
    Write-Host ''
    Write-Host '  nothing above is written without -Apply.'
    exit 0
  }
  'plan'    { exit (Invoke-Plan) }
  'apply'   { exit (Invoke-ApplyAll) }
  'verify'  { exit (Invoke-Verify) }
  'status'  { exit (Invoke-Status) }
  'doctor'  { exit (Invoke-Doctor) }
  'revert'  { exit (Invoke-Revert) }
  'version' { Write-Say "$script:SysoptName $script:SysoptVersion"; $p = Get-PlatformInfo; Write-Kv 'platform' "$($p.Os)/$($p.Arch)"; exit 0 }
  default   { Show-Help; exit 0 }
}
