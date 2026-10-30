<#
.SYNOPSIS
    Antigravity No-TUN Proxy Diagnostics & Status Verifier
.DESCRIPTION
    Checks whether version.dll is loaded by running Antigravity processes,
    inspects deployed config.json, and tests local SOCKS5 tunnel reachability.
#>

[CmdletBinding()]
param()

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================ Antigravity No-TUN Proxy Diagnostics ================" -ForegroundColor Magenta

# 1. Process Module Inspection
$ideProcs = Get-Process "Antigravity IDE" -ErrorAction SilentlyContinue
$clientProcs = Get-Process "Antigravity" -ErrorAction SilentlyContinue

Write-Host "`n[1/3] Process Hook Status:" -ForegroundColor Cyan

if ($ideProcs) {
    $ideMod = $ideProcs[0].Modules | Where-Object { $_.ModuleName -eq "version.dll" }
    if ($ideMod.FileName -like "*Programs\Antigravity IDE*") {
        Write-Host "  - Antigravity IDE: [HOOK ACTIVE] Loaded: $($ideMod.FileName)" -ForegroundColor Green
    } else {
        Write-Host "  - Antigravity IDE: [DIRECT / UNHOOKED] Loaded: $($ideMod.FileName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  - Antigravity IDE: Process not currently running." -ForegroundColor Gray
}

if ($clientProcs) {
    $clientMod = $clientProcs[0].Modules | Where-Object { $_.ModuleName -eq "version.dll" }
    if ($clientMod.FileName -like "*Programs\antigravity*") {
        Write-Host "  - Antigravity Client: [HOOK ACTIVE] Loaded: $($clientMod.FileName)" -ForegroundColor Green
    } else {
        Write-Host "  - Antigravity Client: [DIRECT / UNHOOKED] Loaded: $($clientMod.FileName) (Restart needed)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  - Antigravity Client: Process not currently running." -ForegroundColor Gray
}

# 2. Config File Status
Write-Host "`n[2/3] Configuration Files:" -ForegroundColor Cyan
$paths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE\config.json"),
    (Join-Path $env:LOCALAPPDATA "Programs\antigravity\config.json")
)

$detectedPort = 7897
foreach ($p in $paths) {
    if (Test-Path $p) {
        $c = Get-Content $p -Raw | ConvertFrom-Json
        $detectedPort = $c.proxy.port
        Write-Host "  - $(Split-Path (Split-Path $p -Parent) -Leaf)\config.json: Present (Port: $($c.proxy.port), Type: $($c.proxy.type))" -ForegroundColor Green
    } else {
        Write-Host "  - $($p): Not found." -ForegroundColor Yellow
    }
}

# 3. SOCKS5 Connectivity
Write-Host "`n[3/3] SOCKS5 Connectivity (127.0.0.1:$detectedPort):" -ForegroundColor Cyan
$testDomains = @("daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com")

function Test-Socks5Tunnel($proxyHost, $proxyPort, $destHost, $destPort) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.ReceiveTimeout = 4000
        $client.SendTimeout = 4000
        $async = $client.BeginConnect($proxyHost, $proxyPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($async)
        $stream = $client.GetStream()

        $handshake = [byte[]](0x05, 0x01, 0x00)
        $stream.Write($handshake, 0, $handshake.Length)
        $res = New-Object byte[] 2
        if ($stream.Read($res, 0, 2) -lt 2 -or $res[0] -ne 0x05 -or $res[1] -ne 0x00) {
            $client.Close()
            return $false
        }

        $domainBytes = [System.Text.Encoding]::ASCII.GetBytes($destHost)
        $portBytes = [BitConverter]::GetBytes([uint16]$destPort)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($portBytes) }

        $req = New-Object byte[] (4 + 1 + $domainBytes.Length + 2)
        $req[0] = 0x05
        $req[1] = 0x01
        $req[2] = 0x00
        $req[3] = 0x03
        $req[4] = [byte]$domainBytes.Length
        [Array]::Copy($domainBytes, 0, $req, 5, $domainBytes.Length)
        [Array]::Copy($portBytes, 0, $req, (5 + $domainBytes.Length), 2)

        $stream.Write($req, 0, $req.Length)
        $resp = New-Object byte[] 10
        $read = $stream.Read($resp, 0, 10)
        $client.Close()

        return ($read -ge 4 -and $resp[1] -eq 0x00)
    } catch {
        $client.Close()
        return $false
    }
}

foreach ($d in $testDomains) {
    $ok = Test-Socks5Tunnel "127.0.0.1" $detectedPort $d 443
    if ($ok) {
        Write-Host "  - $d`:443 -> [PASS] SOCKS5 connection ok" -ForegroundColor Green
    } else {
        Write-Host "  - $d`:443 -> [FAIL] Could not connect via 127.0.0.1:$detectedPort" -ForegroundColor Red
    }
}

Write-Host "`n================ Diagnostic Complete ================" -ForegroundColor Magenta
