<#
  sysopt.ps1 test suite.

  Same idea as tests/run_tests.sh: every path is staged under a throwaway
  directory via $env:SYSOPT_ROOT, so nothing on the real machine is touched.
  That is what lets this run on Windows *and* on Linux/macOS CI.

  usage:  pwsh -File tests/run_tests.ps1      (Windows PowerShell 5.1 works too)
#>
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root   = Split-Path -Parent $here
$sysopt = Join-Path $root 'bin/sysopt.ps1'

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Test-Case  { param($name, [scriptblock]$body)
  try { & $body } catch { Fail $name "exception: $($_.Exception.Message)" ; return }
}
function Pass { param($n) $script:Pass++; if ($env:SYSOPT_TEST_VERBOSE) { Write-Host "  ok   $n" } }
function Fail {
  param($n, $why)
  $script:Fail++
  $script:Failures += "  FAIL: $n  ($why)"
  Write-Host "  FAIL $n  ($why)" -ForegroundColor Red
}
function Check { param($name, $cond, $why = '')
  if ($cond) { Pass $name } else { Fail $name $why }
}
function Section { param($t) Write-Host ""; Write-Host $t }

function New-Env {
  $w = Join-Path ([IO.Path]::GetTempPath()) ("sysopt-ps-" + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path (Join-Path $w 'root/etc') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $w 'root/profiles/p1.default') -Force | Out-Null
  Set-Content -Path (Join-Path $w 'root/etc/hosts') -Value @('127.0.0.1 localhost','10.0.0.5 nas.lan') -Encoding ASCII
  Set-Content -Path (Join-Path $w 'root/profiles/p1.default/prefs.js') -Value '' -Encoding UTF8
  $env:SYSOPT_ROOT  = (Join-Path $w 'root')
  $env:SYSOPT_STATE = (Join-Path $w 'state')
  return $w
}

function Invoke-Sysopt {
  # Splat a *hashtable*: an array splat passes "-Apply" as a literal string and
  # the switch never binds. (Also never name a parameter $Args.)
  param(
    [string]$Cmd,
    [switch]$Apply,
    [switch]$All,
    [string]$Id,
    [switch]$DryRun
  )
  $p = @{ Command = $Cmd }
  if ($Apply)  { $p.Apply  = $true }
  if ($All)    { $p.All    = $true }
  if ($Id)     { $p.Id     = $Id }
  if ($DryRun) { $p.DryRun = $true }
  # *>&1 captures every stream: Write-Host goes to the information stream,
  # which 2>&1 alone would drop — and then every assertion on output lies.
  $out = & $sysopt @p *>&1 | Out-String
  return @{ Out = $out; Code = $LASTEXITCODE }
}

function Get-TreeHash {
  param($dir)
  (Get-ChildItem -Path $dir -Recurse -File | Sort-Object FullName | ForEach-Object {
    "{0} {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($dir.Length)
  }) -join "`n"
}

# --------------------------------------------------------------------------
Section '1. plan writes nothing'
$w = New-Env
$before = Get-Content (Join-Path $w 'root/etc/hosts') -Raw
$r = Invoke-Sysopt -Cmd plan
Check 'plan exits 0' ($r.Code -eq 0) "code $($r.Code)"
Check 'plan leaves hosts alone' ($before -eq (Get-Content (Join-Path $w 'root/etc/hosts') -Raw))
Check 'plan creates no manifest' (-not (Test-Path (Join-Path $env:SYSOPT_STATE 'manifest.tsv')))

Section '2. apply writes a block, a backup and a manifest row'
$r = Invoke-Sysopt -Cmd apply -Apply
$hf = Join-Path $w 'root/etc/hosts'
$text = Get-Content $hf -Raw
Check 'apply exits 0' ($r.Code -eq 0) "code $($r.Code)"
Check 'one begin marker' (((Get-Content $hf | Select-String 'BEGIN sysopt managed block').Count) -eq 1)
Check 'one end marker'   (((Get-Content $hf | Select-String 'END sysopt managed block').Count) -eq 1)
Check 'A record for doubleclick' ($text -match '0\.0\.0\.0 doubleclick\.net')
Check 'AAAA record for doubleclick' ($text -match ':: doubleclick\.net')
Check 'user line preserved' ($text -match '10\.0\.0\.5 nas\.lan')
$mf = Join-Path $env:SYSOPT_STATE 'manifest.tsv'
Check 'manifest exists' (Test-Path $mf)
$row = (Get-Content $mf | Where-Object { $_ -like 'hosts*' }) -split "`t"
Check 'manifest row has a backup path' ($row.Length -ge 4 -and $row[3] -ne '-' -and $row[3])
Check 'the backup file exists' (Test-Path $row[3])

Section '3. a second apply changes nothing'
$sum1 = (Get-FileHash $hf).Hash
$r = Invoke-Sysopt -Cmd apply -Apply
$sum2 = (Get-FileHash $hf).Hash
Check 'hosts unchanged' ($sum1 -eq $sum2)
Check 'reports already current' ($r.Out -match 'already current')

Section '4. verify notices tampering'
$r = Invoke-Sysopt -Cmd verify
Check 'verify passes on a good system' (-not ($r.Out -cmatch 'FAIL')) (($r.Out -replace "`r?`n",' | '))
(Get-Content $hf) | Where-Object { $_ -notmatch 'criteo\.com' } | Set-Content $hf -Encoding ASCII
$r = Invoke-Sysopt -Cmd verify
Check 'verify fails after a name is removed' ($r.Out -cmatch 'FAIL')

Section '5. revert restores the original bytes'
$w = New-Env
$hf = Join-Path $w 'root/etc/hosts'
$orig = Get-Content $hf -Raw
Invoke-Sysopt -Cmd apply -Apply | Out-Null
$r = Invoke-Sysopt -Cmd revert -Id hosts_block -Apply
Check 'revert exits 0' ($r.Code -eq 0) "code $($r.Code)"
Check 'hosts is byte-identical' ($orig -eq (Get-Content $hf -Raw))
Check 'no markers left' (-not ((Get-Content $hf -Raw) -match 'sysopt managed block'))

Section '6. a user.js that sysopt created is removed again'
$w = New-Env
$ujs = Join-Path $w 'root/profiles/p1.default/user.js'
Invoke-Sysopt -Cmd apply -Apply | Out-Null
Check 'user.js was created' (Test-Path $ujs)
Invoke-Sysopt -Cmd revert -All -Apply | Out-Null
Check 'user.js removed on revert' (-not (Test-Path $ujs))

Section '7. a user.js that already existed is restored, not deleted'
$w = New-Env
$ujs = Join-Path $w 'root/profiles/p1.default/user.js'
Set-Content -Path $ujs -Value 'user_pref("general.useragent.override", "mine");' -Encoding UTF8
$beforeJs = Get-Content $ujs -Raw
Invoke-Sysopt -Cmd apply -Apply | Out-Null
Check 'the block was added' ((Get-Content $ujs -Raw) -match 'BEGIN sysopt managed prefs')
Invoke-Sysopt -Cmd revert -All -Apply | Out-Null
Check 'the original user.js is back' ($beforeJs -eq (Get-Content $ujs -Raw))

Section '8. a pref the user already set is never overridden'
$w = New-Env
$ujs = Join-Path $w 'root/profiles/p1.default/user.js'
Set-Content -Path $ujs -Value 'user_pref("dom.ipc.processCount", 8);' -Encoding UTF8
$r = Invoke-Sysopt -Cmd apply -Apply
$txt = Get-Content $ujs -Raw
Check 'the user value is untouched' ($txt -match 'processCount", 8')
Check 'it is not duplicated by us' ((([regex]::Matches($txt, 'ipc\.processCount')).Count) -eq 1)
Check 'the plan said so' ($r.Out -match 'keeping your own value')
Check 'other prefs were added' ($txt -match 'browser\.sessionstore\.interval')

Section '9. a stale manifest cannot make revert delete a file you own'
$w = New-Env
$ujs = Join-Path $w 'root/profiles/p1.default/user.js'
Set-Content -Path $ujs -Value 'user_pref("x", 1);' -Encoding UTF8
New-Item -ItemType Directory -Path $env:SYSOPT_STATE -Force | Out-Null
Set-Content -Path (Join-Path $env:SYSOPT_STATE 'manifest.tsv') -Value ("userjs-p1.default`tfile`t$ujs`t-`t0`t") -Encoding UTF8
$r = Invoke-Sysopt -Cmd revert -Id firefox_userjs -Apply
Check 'the file still exists' (Test-Path $ujs)
Check 'the user line survives' ((Get-Content $ujs -Raw) -match 'user_pref\("x", 1\)')
Check 'our block is gone' (-not ((Get-Content $ujs -Raw) -match 'sysopt managed prefs'))

Section '10. a bogus action name is a usage error'
$w = New-Env
$r = Invoke-Sysopt -Cmd revert -Id not_an_action -Apply
Check 'exit code 2' ($r.Code -eq 2) "code $($r.Code)"

# --------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------'
Write-Host ("  passed {0}   failed {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { $script:Failures | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host '  all good'
exit 0
