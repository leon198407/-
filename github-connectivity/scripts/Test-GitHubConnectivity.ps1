#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose and fix GitHub connectivity on Windows.

.DESCRIPTION
    Five-layer probe: proxy -> DNS -> TCP -> TLS/SNI -> browser.
    Classifies each failure as IP_DEAD (change IP helps) or SNI_BLOCKED
    (hosts can never help). Mode=Apply pins the fastest verified-live IP
    into the hosts file.

.PARAMETER Mode
    Diagnose  - probe all known GitHub domains using current DNS/hosts (default)
    Scan      - probe a candidate IP pool for github.com, pick the best
    Apply     - Scan, then write the best IP into hosts and flush DNS

.PARAMETER HostsPath
    Defaults to %windir%\System32\drivers\etc\hosts. Needs Administrator to write.

.PARAMETER Timeout
    Per-probe curl timeout in seconds. Default 6.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Test-GitHubConnectivity.ps1 -Mode Diagnose

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Test-GitHubConnectivity.ps1 -Mode Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Scan', 'Apply')]
    [string]$Mode = 'Diagnose',

    [string]$HostsPath = "$env:windir\System32\drivers\etc\hosts",

    [int]$Timeout = 6
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- constants
# Known GitHub frontend IPs. Availability in CN networks changes daily,
# so this list is a starting point, not an answer.
$CandidateIps = @(
    '140.82.112.3', '140.82.113.3', '140.82.114.3', '140.82.116.3',
    '140.82.121.3', '140.82.121.4', '20.27.177.113', '20.200.245.247',
    '20.29.134.23', '20.26.156.215', '20.233.83.145', '20.207.73.82',
    '20.175.192.147', '4.237.22.38', '20.205.243.166', '20.201.28.151'
)

$Domains = @(
    'github.com',
    'api.github.com',
    'codeload.github.com',
    'objects.githubusercontent.com',
    'avatars.githubusercontent.com',
    'github.githubassets.com',
    'raw.githubusercontent.com',
    'gist.github.com',
    'github.io'
)

# ---------------------------------------------------------------- helpers
function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===')
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Probe one (hostname, ip) pair with the correct SNI, bypassing DNS.
function Invoke-Probe {
    param(
        [string]$Name,
        [string]$Ip,
        [int]$TimeoutSec = 6
    )

    $raw = & curl.exe -s -o NUL -m $TimeoutSec `
        --resolve "$($Name):443:$($Ip)" `
        -w "%{http_code}|%{time_total}" `
        "https://$($Name)/" 2>$null

    $code = '000'
    $t = 99.0
    if ($raw) {
        $parts = ("$raw").Trim() -split '\|'
        if ($parts.Count -ge 2) {
            $code = $parts[0]
            $parsed = 0.0
            if ([double]::TryParse($parts[1], [ref]$parsed)) { $t = $parsed }
        }
    }

    # Verdict rules -- the whole point of this script:
    #   fast failure (<2s)  => TLS reset by middlebox => SNI blocked, IP change is useless
    #   slow failure (>=5s) => SYN dropped              => dead IP, IP change works
    $verdict = 'UNKNOWN'
    if ($code -eq '000') {
        if ($t -lt 2.0) { $verdict = 'SNI_BLOCKED' } else { $verdict = 'IP_DEAD' }
    }
    elseif ($code -eq '400') { $verdict = 'WRONG_SERVICE' }
    else { $verdict = 'REACHABLE' }

    [pscustomobject]@{
        Host    = $Name
        IP      = $Ip
        Code    = $code
        Time    = [math]::Round($t, 2)
        Verdict = $verdict
    }
}

function Get-EffectiveIp {
    param([string]$Name)
    # MUST honour the hosts file: this is the IP the OS (and the browser)
    # will actually use. Note: Resolve-DnsName -DnsOnly BYPASSES hosts and
    # returns the raw DNS answer -- never use it here.
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Name) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString }
        if ($addrs) { return @($addrs | Select-Object -Unique) }
    }
    catch { }

    $r = Resolve-DnsName $Name -Type A -ErrorAction SilentlyContinue
    return @($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress } | Select-Object -Unique)
}

# ---------------------------------------------------------------- L1 proxy
function Show-ProxyState {
    Write-Section 'L1 proxy / environment'

    # netsh output is localized, so never match on English text -- detect a
    # configured proxy by looking for an IP:port pattern instead.
    $winhttp = (netsh winhttp show proxy) -join ' '
    if ($winhttp -match '\d{1,3}(\.\d{1,3}){3}(:\d+)?') {
        Write-Host ('WinHTTP        : PROXY CONFIGURED -> ' + ($winhttp -replace '\s+', ' ').Trim())
    }
    else {
        Write-Host 'WinHTTP        : no proxy (direct access)'
    }

    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($ie) {
        Write-Host ("IE/System      : ProxyEnable=$($ie.ProxyEnable) ProxyServer=$($ie.ProxyServer)")
    }

    foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
        $val = [Environment]::GetEnvironmentVariable($v)
        Write-Host ("{0,-15}: {1}" -f $v, $(if ($val) { $val } else { '(empty)' }))
    }

    if (Test-Command 'git') {
        $p = & git config --global --get https.proxy 2>$null
        Write-Host ("git https.proxy: " + $(if ($p) { $p } else { '(empty)' }))
    }
    else {
        Write-Host 'git            : NOT INSTALLED (clone/pull will fail for a reason unrelated to network)'
    }
}

# ---------------------------------------------------------------- L2 DNS
function Show-DnsState {
    param([string]$Name)

    $sys = Get-EffectiveIp $Name
    Write-Output ("{0,-42} hosts/DNS -> {1}" -f $Name, $(if ($sys) { $sys -join ', ' } else { 'NO ANSWER' }))
}

# ---------------------------------------------------------------- main probes
function Invoke-Diagnose {
    Write-Section 'L2/L3/L4 probe (bypasses DNS, real TLS handshake per IP)'
    Write-Host ("{0,-40} {1,-16} {2,-6} {3,-8} {4}" -f 'HOST', 'IP', 'CODE', 'TIME', 'VERDICT')

    $rows = @()
    foreach ($d in $Domains) {
        $ips = Get-EffectiveIp $d
        if (-not $ips) {
            Write-Host ("{0,-40} {1,-16} {2,-6} {3,-8} {4}" -f $d, '-', '-', '-', 'NO_DNS')
            continue
        }
        foreach ($ip in $ips) {
            $p = Invoke-Probe -Name $d -Ip $ip -TimeoutSec $Timeout
            $rows += $p
            Write-Host ("{0,-40} {1,-16} {2,-6} {3,-8} {4}" -f $p.Host, $p.IP, $p.Code, $p.Time, $p.Verdict)
        }
    }
    return $rows
}

function Invoke-Scan {
    Write-Section "scan candidate IPs for github.com (timeout ${Timeout}s)"
    Write-Host ("{0,-16} {1,-6} {2,-8} {3}" -f 'IP', 'CODE', 'TIME', 'VERDICT')

    $rows = @()
    foreach ($ip in $CandidateIps) {
        $p = Invoke-Probe -Name 'github.com' -Ip $ip -TimeoutSec $Timeout
        $rows += $p
        Write-Host ("{0,-16} {1,-6} {2,-8} {3}" -f $p.IP, $p.Code, $p.Time, $p.Verdict)
    }

    $alive = @($rows | Where-Object { $_.Verdict -eq 'REACHABLE' -and $_.Code -eq '200' } | Sort-Object Time)

    if ($alive.Count -eq 0) {
        Write-Host ''
        Write-Host 'No reachable github.com IP. This line is being throttled or blocked.'
        Write-Host 'A proxy/VPN is required; hosts cannot fix it.'
        return $null
    }

    Write-Section 'stability retest of top 3 (3 attempts each)'
    $top = @($alive | Select-Object -First 3)
    $scored = @()
    foreach ($a in $top) {
        $codes = @()
        $times = @()
        1..3 | ForEach-Object {
            $r = & curl.exe -s -o NUL -m $Timeout --resolve "github.com:443:$($a.IP)" `
                -w "%{http_code}|%{time_total}" "https://github.com/" 2>$null
            $p = ("$r").Trim() -split '\|'
            $codes += $p[0]
            if ($p.Count -ge 2) {
                $v = 0.0
                if ([double]::TryParse($p[1], [ref]$v)) { $times += $v }
            }
        }
        $ok = @($codes | Where-Object { $_ -eq '200' }).Count
        $avg = if ($times.Count -gt 0) { [math]::Round((($times | Measure-Object -Average).Average), 2) } else { 99.0 }
        # Rank by success count first, then by average latency. A single fast
        # sample is meaningless on a throttled line -- 3/3 success is what matters.
        $scored += [pscustomobject]@{ IP = $a.IP; Ok = $ok; Avg = $avg }
        Write-Host ("{0,-16} ok={1}/3 avg={2,-6} retest={3}" -f $a.IP, $ok, $avg, ($codes -join ' '))
    }

    $best = $scored | Sort-Object -Property @{ Expression = 'Ok'; Descending = $true },
                                            @{ Expression = 'Avg'; Descending = $false } |
            Select-Object -First 1

    Write-Host ''
    Write-Host ("selected: {0}  (ok={1}/3, avg={2}s)" -f $best.IP, $best.Ok, $best.Avg)
    return $best
}

function Invoke-Apply {
    param([string]$Ip)

    Write-Section "apply $Ip to hosts"

    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'ERROR: Administrator rights required to write the hosts file.'
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$HostsPath.bak-$stamp"
    Copy-Item $HostsPath $backup -Force
    Write-Host "backup -> $backup"

    $lines = [IO.File]::ReadAllLines($HostsPath)
    $out = New-Object System.Collections.Generic.List[string]
    $seenGithub = $false
    $seenWww = $false

    foreach ($l in $lines) {
        # www first: drop duplicates instead of emitting a second entry
        if ($l -match '^\s*[\d\.]+\s+www\.github\.com\s*$') {
            if (-not $seenWww) {
                $out.Add("$Ip`twww.github.com")
                $seenWww = $true
            }
            continue
        }
        if ($l -match '^\s*[\d\.]+\s+github\.com\s*$') {
            if (-not $seenGithub) {
                $out.Add("$Ip`tgithub.com")
                $seenGithub = $true
                if (-not $seenWww) {
                    $out.Add("$Ip`twww.github.com")
                    $seenWww = $true
                }
            }
            continue
        }
        $out.Add($l)
    }

    if (-not $seenGithub) {
        $out.Add('')
        $out.Add('# GitHub direct-connect pin')
        $out.Add("$Ip`tgithub.com")
        if (-not $seenWww) { $out.Add("$Ip`twww.github.com") }
    }

    [IO.File]::WriteAllLines($HostsPath, $out, [Text.Encoding]::ASCII)
    ipconfig /flushdns | Out-Null
    Write-Host 'hosts written, DNS cache flushed'

    Write-Section 'verify (4 attempts)'
    1..4 | ForEach-Object {
        $r = & curl.exe -s -o NUL -m 10 -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}s" "https://github.com/" 2>$null
        Write-Host ("try{0}: {1}" -f $_, $r)
    }

    Write-Host ''
    Write-Host 'NEXT: fully quit the browser (all msedge.exe/chrome.exe processes) or'
    Write-Host '      open edge://net-internals/#dns and click "Clear host cache".'
    Write-Host '      Browsers keep their own DNS cache; ipconfig /flushdns is not enough.'
}

# ---------------------------------------------------------------- entry
if (-not (Test-Command 'curl.exe')) {
    Write-Output 'ERROR: curl.exe not found (Windows 10 1803+ ships it). Install curl or use another client.'
    exit 1
}

Show-ProxyState

Write-Section 'effective resolution (hosts file included)'
foreach ($d in $Domains) { Show-DnsState $d }

$hostsInfo = Get-Item $HostsPath -ErrorAction SilentlyContinue
if ($hostsInfo) {
    Write-Output ''
    Write-Output ("hosts LastWriteTime: " + $hostsInfo.LastWriteTime)
    $managed = Get-Content $HostsPath | Where-Object { $_ -match 'GitHub520|GitHub Host Start|SwitchHosts|FastGithub' }
    if ($managed) {
        Write-Output 'WARNING: a third-party managed block is present in hosts:'
        $managed | ForEach-Object { Write-Output ('    ' + $_) }
        Write-Output '         It may be rewritten by an updater. Re-check after any update.'
    }
}

switch ($Mode) {
    'Diagnose' {
        Invoke-Diagnose | Out-Null
    }
    'Scan' {
        Invoke-Scan | Out-Null
    }
    'Apply' {
        $best = Invoke-Scan
        if ($best) { Invoke-Apply -Ip $best.IP }
    }
}

Write-Section 'legend'
Write-Output 'REACHABLE     IP works'
Write-Output 'IP_DEAD       SYN dropped / slow timeout -> changing IP in hosts WILL help'
Write-Output 'SNI_BLOCKED   fast TLS reset -> hostname filtered, changing IP will NEVER help'
Write-Output 'WRONG_SERVICE IP alive but not serving this hostname (e.g. api-only node)'
Write-Output ''
