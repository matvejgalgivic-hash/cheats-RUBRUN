#requires -version 5
<#
  update.ps1 - keeps packages\<gameId>.zip in sync with the vendor release.

  The original loader never ships a "new cheat" to the operator: it asks the
  backend for a signed manifest, compares package_sha256 with the file on disk
  and downloads the package when it differs. This script does exactly that,
  in the console, before start.bat arms the runtime.

  Flow:
    1. license.json -> POST /api/v1/auth            (token)
    2. GET  /api/v1/games/<id>/manifest             (signed manifest)
       payload -> version, package_size, package_sha256, entry_file
    3. sha256(packages\<id>.zip)  ==  package_sha256 ?  up to date, exit 0
    4. otherwise download /api/v1/games/<id>/package with a progress line,
       verify the hash, verify the zip really contains entry_file, then swap
       it in (old file kept as packages\<id>.zip.bak for rollback)
    5. drop the extracted runtime cache so the next inject uses the new exe

  Exit codes:
    0  up to date or updated
    2  no licence (skipped, not an error for the chain)
    3  download failed
    4  hash mismatch (file rejected, previous package untouched)
    5  archive is not usable (no entry_file inside)
    6  manifest/back-end unreachable

  Params:
    -Check      report only, never write anything
    -Force      download even when the hash already matches
    -Server     vendor base url (default https://95.85.230.17)
    -GameId     game id (default 1)
#>
[CmdletBinding()]
param(
    [string]$Server = 'https://95.85.230.17',
    [string]$GameId = '1',
    [switch]$Check,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgDir   = Join-Path $root 'packages'
$pkgZip   = Join-Path $pkgDir ($GameId + '.zip')
$pkgBak   = Join-Path $pkgDir ($GameId + '.zip.bak')
$pkgTmp   = Join-Path $pkgDir ($GameId + '.zip.download')
$markerJs = Join-Path $pkgDir 'update_info.json'
$license  = Join-Path $root 'license.json'
$realMan  = Join-Path $root 'real_manifest.json'
$flag     = Join-Path $root 'logs\vendor_down.flag'
$rtCache  = Join-Path $env:TEMP 'RobRun_inject'
$ua       = 'GameLoader/1.0.14'

function Info($m) { Write-Host ("[*] " + $m) -ForegroundColor Cyan }
function Ok($m)   { Write-Host ("[+] " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ("[x] " + $m) -ForegroundColor Red }

function Sha256-File($path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLower() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Human($bytes) {
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ("$bytes B")
}

# The vendor box drops the odd connection (seen: five auths in a row, the fifth
# came back as a network error). A lost update check is not a fatal event, but
# retrying twice turns most of those into a normal "up to date" run. Real
# answers - 401 for a dead key, 404 - are not retried.
function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            return (& $Action)
        } catch {
            # a MethodInvocationException would hide the WebException that
            # actually carries the status code
            $ex = $_.Exception
            while (-not $ex.Response -and $ex.InnerException) { $ex = $ex.InnerException }
            $code = 0
            if ($ex.Response) { try { $code = [int]$ex.Response.StatusCode } catch {} }
            $flat = ($code -eq 0 -or $code -ge 500 -or $code -eq 429)
            if ($i -ge $Tries -or -not $flat) { throw }
            $why = if ($code) { "HTTP $code" } else { "network error" }
            Warn ("vendor did not answer (" + $why + "), retrying in 2s ...")
            Start-Sleep -Seconds 2
        }
    }
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --------------------------------------------------------------- 1. licence
if (-not (Test-Path $license)) {
    Warn "no license.json - cannot ask the vendor for the current build"
    exit 2
}
try { $lic = Get-Content $license -Raw | ConvertFrom-Json } catch { Warn "license.json is unreadable"; exit 2 }
# license.json holds the key only. The hwid belongs to THIS PC and lives in
# hwid.txt (written by SETUP.bat); runtime_config.ini is the older spot.
function Read-Hwid {
    $f = Join-Path $root 'hwid.txt'
    if (Test-Path $f) {
        foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) {
            $v = $l.Trim()
            if ($v -and -not $v.StartsWith('#')) { return $v }
        }
    }
    $envH = [Environment]::GetEnvironmentVariable('ROBRUN_HWID')
    if ($envH) { return $envH.Trim() }
    $ini = Join-Path $root 'runtime_config.ini'
    if (Test-Path $ini) {
        $line = Select-String -Path $ini -Pattern '^\s*hwid\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($line) { return (($line.Line -replace '^\s*hwid\s*=\s*', '').Trim()) }
    }
    return ''
}
if (-not $lic.hwid) {
    $lic | Add-Member -NotePropertyName hwid -NotePropertyValue (Read-Hwid) -Force
}
if (-not $lic.key -or -not $lic.hwid) { Warn "no key in license.json / no hwid.txt for this PC"; exit 2 }
$keyIsOurs = ($lic.key.Trim().ToUpper() -eq 'RYKB-A4HF-RZBD-U9J8')
if ($keyIsOurs -and (Test-Path $flag)) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }

# our key is bound to ONE machine: on any other PC the vendor answers 403. That
# is not a failure, it is the signal to let the OFFICIAL loader do the update.
function Give-Up-To-Official($why) {
    Bad ("cannot use the vendor with this key: " + $why)
    if ($keyIsOurs) {
        Warn "on this PC the official loader takes over the update (start_loader.bat)"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $flag) | Out-Null
            Set-Content -Path $flag -Value ("{0}  hwid={1}" -f (Get-Date).ToString('s'), $lic.hwid) -Encoding UTF8
        } catch {}
    } else {
        Warn "edit license.json: its key does not match the one the loader accepts"
    }
    exit 2
}

$token = $null
$authBody = @{ key = $lic.key; hwid = $lic.hwid } | ConvertTo-Json -Compress
try {
    $auth = Invoke-WithRetry {
        Invoke-RestMethod -Uri ($Server + '/api/v1/auth') -Method POST -TimeoutSec 20 -UseBasicParsing `
            -ContentType 'application/json' -UserAgent $ua -Body $authBody
    }
    $token = $auth.token
} catch {
    $code = 0
    $ex = $_.Exception
    while (-not $ex.Response -and $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex.Response) { try { $code = [int]$ex.Response.StatusCode } catch {} }
    if ($code -eq 403 -or $code -eq 401) { Give-Up-To-Official ("auth refused, HTTP $code") }
    Bad ("auth failed: " + $_.Exception.Message)
    exit 6
}
if (-not $token) { Bad "auth returned no token (key expired?)"; exit 6 }

$days = if ($null -ne $auth.days) { $auth.days } else { '?' }
$life = if ($auth.lifetime) { 'lifetime' } else { "$days day(s) left" }
Info ("licence ok, " + $life)

# -------------------------------------------------------------- 2. manifest
$manifest = $null
try {
    $manifest = Invoke-WithRetry {
        Invoke-RestMethod -Uri ($Server + "/api/v1/games/$GameId/manifest") -Method GET `
            -TimeoutSec 20 -UseBasicParsing -UserAgent $ua -Headers @{ Authorization = 'Bearer ' + $token }
    }
} catch {
    $code = 0
    $ex = $_.Exception
    while (-not $ex.Response -and $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex.Response) { try { $code = [int]$ex.Response.StatusCode } catch {} }
    if ($code -eq 403 -or $code -eq 401) { Give-Up-To-Official ("manifest refused, HTTP $code") }
    Bad ("manifest request failed: " + $_.Exception.Message)
    exit 6
}
if (-not $manifest.payload) { Bad "manifest has no payload"; exit 6 }

try {
    $pjson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($manifest.payload))
    $meta = $pjson | ConvertFrom-Json
} catch {
    Bad "manifest payload is not valid json"
    exit 6
}

$version = [string]$meta.version
$wantSha = ([string]$meta.package_sha256).ToLower()
$wantSz  = [int64]$meta.package_size
$entry   = if ($meta.entry_file) { [string]$meta.entry_file } else { 'RobRun.exe' }

if (-not $wantSha -or $wantSha.Length -ne 64) { Bad "manifest has no usable package_sha256"; exit 6 }
Info ("vendor build: " + $version + "  (" + (Human $wantSz) + ", sha " + $wantSha.Substring(0, 12) + "...)")

# ------------------------------------------------------------- 3. local file
$haveSha = ''
$haveSz = 0
$haveVer = '?'
if (Test-Path $pkgZip) {
    $haveSz = (Get-Item $pkgZip).Length
    $haveSha = Sha256-File $pkgZip
}
if (Test-Path $markerJs) {
    try {
        $v = ([string](Get-Content $markerJs -Raw | ConvertFrom-Json).version).Trim()
        if ($v) { $haveVer = $v }
    } catch {}
}
$haveVerKnown = ($haveVer -ne '?')
$haveLabel = if ($haveVerKnown) { $haveVer } else { 'unknown' }
$szDelta = $haveSz - $wantSz
if ($szDelta -gt 0) { $szDeltaTxt = ' +' + (Human $szDelta) }
elseif ($szDelta -lt 0) { $szDeltaTxt = ' -' + (Human (-$szDelta)) }
else { $szDeltaTxt = '' }

$same = ($haveSha -eq $wantSha)
if ($same -and -not $Force) {
    Ok ("up to date: build " + $version + "  (" + (Human $haveSz) + ", sha " + $haveSha.Substring(0, 12) + "...)")
    $pkgInfo = @{
        version = $version; sha256 = $wantSha; size = $wantSz
        updated = (Get-Date).ToString('s'); previous_version = $haveVer
        previous_sha256 = $haveSha; state = 'current'
    } | ConvertTo-Json
    if (-not $Check) { try { Set-Content -Path $markerJs -Value $pkgInfo -Encoding UTF8 } catch {} }
    else { Warn "-Check given: nothing was written" }
    exit 0
}

if ($same -and $Force) {
    Info "hash already matches, -Force given: downloading anyway"
} elseif ($haveSz -gt 0) {
    # The label only exists if update_info.json survived. When it is missing the
    # build number is not guessable from the file, so do not invent one (least of
    # all by copying the vendor's) - the size delta already says what changed.
    if ($haveVerKnown) {
        Info ("local build " + $haveVer + " (" + (Human $haveSz) + ") differs from vendor " + $version + " (" + (Human $wantSz) + ")")
    } else {
        $note = if ($szDelta -eq 0) { 'same size as vendor, content differs' } else { 'vendor ' + $szDeltaTxt.Trim() }
        Info ("local package differs from vendor " + $version + "  (" + (Human $haveSz) + ", " + $note + ")")
    }
} else {
    Info "no local package yet - downloading build $version"
}

if ($Check) {
    Warn "-Check given: nothing was written"
    exit 0
}

# -------------------------------------------------------------- 4. download
New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
if (Test-Path $pkgTmp) { Remove-Item $pkgTmp -Force -ErrorAction SilentlyContinue }

Info ("downloading " + (Human $wantSz) + " ...")
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $req = [Net.HttpWebRequest]::Create($Server + "/api/v1/games/$GameId/package")
    $req.Method = 'GET'
    $req.UserAgent = $ua
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $req.Headers.Add('Authorization', 'Bearer ' + $token)
    $resp = $req.GetResponse()
} catch {
    Bad ("download did not start: " + $_.Exception.Message)
    exit 3
}

$total = $resp.ContentLength
$in = $resp.GetResponseStream()
$out = [IO.File]::Create($pkgTmp)
$buf = New-Object byte[] 131072
$done = 0
$lastPct = -5
try {
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
        $done += $n
        $pct = if ($total -gt 0) { [int](100 * $done / $total) } else { 0 }
        if ($pct -ge $lastPct + 5) {
            $lastPct = $pct
            Write-Host -NoNewline ("`r    " + ("{0,3}" -f $pct) + "%  " + (Human $done) + " / " + (Human $total) + "   ")
        }
    }
} catch {
    try { $out.Dispose() } catch {}
    try { $in.Dispose() } catch {}
    try { $resp.Close() } catch {}
    Remove-Item $pkgTmp -Force -ErrorAction SilentlyContinue
    Bad ("download broke off: " + $_.Exception.Message)
    exit 3
} finally {
    try { $out.Dispose() } catch {}
    try { $in.Dispose() } catch {}
    try { $resp.Close() } catch {}
}
Write-Host ""
Info ("saved in " + [int]$sw.Elapsed.TotalSeconds + "s")

$gotSz = (Get-Item $pkgTmp).Length
if ($wantSz -gt 0 -and $gotSz -ne $wantSz) {
    Bad ("size mismatch: got " + (Human $gotSz) + ", expected " + (Human $wantSz))
    Remove-Item $pkgTmp -Force -ErrorAction SilentlyContinue
    exit 3
}

# ----------------------------------------------------------------- 5. verify
$gotSha = Sha256-File $pkgTmp
if ($gotSha -ne $wantSha) {
    Bad ("sha256 mismatch: got " + $gotSha)
    Bad  "file rejected, the previous package is untouched"
    Remove-Item $pkgTmp -Force -ErrorAction SilentlyContinue
    exit 4
}
Ok "sha256 verified"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipOk = $false
try {
    $z = [IO.Compression.ZipFile]::OpenRead($pkgTmp)
    try {
        $e = $z.Entries | Where-Object { $_.FullName -eq $entry } | Select-Object -First 1
        if ($e -and $e.Length -gt 102400) {
            $zipOk = $true
            Info ("archive ok: " + $entry + " (" + (Human $e.Length) + ")")
        } elseif ($e) {
            Bad ("archive entry " + $entry + " is too small (" + $e.Length + " bytes)")
        } else {
            Bad ("archive has no " + $entry)
        }
    } finally { $z.Dispose() }
} catch {
    Bad ("archive is not a valid zip: " + $_.Exception.Message)
}
if (-not $zipOk) {
    Remove-Item $pkgTmp -Force -ErrorAction SilentlyContinue
    exit 5
}

# ----------------------------------------------------------------- 6. swap
if (Test-Path $pkgZip) {
    Move-Item -Path $pkgZip -Destination $pkgBak -Force
    Info ("previous package kept as " + (Split-Path $pkgBak -Leaf))
}
Move-Item -Path $pkgTmp -Destination $pkgZip -Force
Ok ("installed build " + $version)

# keep the loader-ui fallback in step with the new build: api.py replays the
# signed manifest and points size/sha at the zip it serves
if (Test-Path $realMan) {
    try { Copy-Item $realMan ($realMan + '.old') -Force } catch {}
}
try {
    @{ signature = $manifest.signature; payload = $manifest.payload } |
        ConvertTo-Json -Compress | Set-Content -Path $realMan -Encoding UTF8
} catch { Warn "could not refresh real_manifest.json (loader-ui fallback keeps the old one)" }

# the extracted copy in %TEMP% wins over the package inside inject.ps1, so it
# has to go or the old exe keeps getting injected. inject.ps1 also compares
# timestamps, so a locked file is replaced automatically on the next run.
if (Test-Path $rtCache) {
    try {
        Remove-Item $rtCache -Recurse -Force -ErrorAction Stop
        Info "runtime cache cleared"
    } catch {
        Warn "runtime cache is locked (a RobRun.exe is still running)"
        Info "inject.ps1 will re-extract it: the zip is newer than the cached exe"
    }
}

@{ version = $version; sha256 = $wantSha; size = $wantSz
   updated = (Get-Date).ToString('s'); previous_version = $haveVer
   previous_sha256 = $haveSha; rollback = ($pkgBak | Split-Path -Leaf)
   state = 'updated' } | ConvertTo-Json | Set-Content -Path $markerJs -Encoding UTF8

Ok ("update done: " + $haveLabel + " -> " + $version)
exit 0
