<#
.SYNOPSIS
    Antigravity Universal No-TUN Proxy Deployer & Verifier
.DESCRIPTION
    Deploys version.dll and tuned config.json to Antigravity IDE and/or Antigravity Client
    to route API traffic through local SOCKS5 proxy without requiring TUN mode or Proxifier.
    Compatible with human execution and automated AI Agent workflows.
.PARAMETER Port
    Local SOCKS5 proxy port (default: auto-detected, fallback to 7897).
.PARAMETER Target
    Target application: 'All' (both IDE & Client), 'IDE', or 'Client'.
.PARAMETER CustomPath
    Optional custom installation path for Antigravity.
.PARAMETER Restart
    Whether to automatically close running Antigravity processes to apply changes immediately.
.PARAMETER SkipTest
    Skip SOCKS5 proxy connectivity test to Google APIs.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy.ps1
    powershell -ExecutionPolicy Bypass -File deploy.ps1 -Port 7890 -Target All
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [int]$Port = 0,

    [ValidateSet('All', 'IDE', 'Client')]
    [string]$Target = 'All',

    [string]$CustomPath = '',

    [switch]$Restart,

    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = "." }

$dllSource = Join-Path $scriptDir "version.dll"
$configSource = Join-Path $scriptDir "config.json"

if (-not (Test-Path $dllSource)) {
    Write-Error "Missing version.dll in script directory: $scriptDir"
    exit 1
}
if (-not (Test-Path $configSource)) {
    Write-Error "Missing config.json in script directory: $scriptDir"
    exit 1
}

# ==============================================================================
# 1. Port Auto-Detection
# ==============================================================================
$commonPorts = @(7897, 7890, 10808, 10809, 2080, 2081)

if ($Port -le 0) {
    Write-Host "[*] Auto-detecting local proxy port..." -ForegroundColor Cyan
    try {
        $activeListeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | 
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') } |
            Select-Object -ExpandProperty LocalPort
        
        foreach ($cp in $commonPorts) {
            if ($activeListeners -contains $cp) {
                $Port = $cp
                Write-Host "  -> Detected active local proxy listener on port: $Port" -ForegroundColor Green
                break
            }
        }
    } catch {
        # Fallback if Get-NetTCPConnection is unavailable
    }

    if ($Port -le 0) {
        $Port = 7897
        Write-Host "  -> No active proxy port found in common list. Defaulting to: $Port" -ForegroundColor Yellow
    }
} else {
    Write-Host "[*] Using specified proxy port: $Port" -ForegroundColor Cyan
}

# ==============================================================================
# 2. Target Directories Resolution
# ==============================================================================
$targets = @()

$defaultIdePath = Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE"
$defaultClientPath = Join-Path $env:LOCALAPPDATA "Programs\antigravity"

if ($CustomPath) {
    if (Test-Path $CustomPath) {
        $targets += [PSCustomObject]@{ Name = "Custom Path"; Path = $CustomPath; ProcessName = "Antigravity*" }
    } else {
        Write-Warning "Specified CustomPath does not exist: $CustomPath"
    }
} else {
    if ($Target -in @('All', 'IDE')) {
        if (Test-Path $defaultIdePath) {
            $targets += [PSCustomObject]@{ Name = "Antigravity IDE"; Path = $defaultIdePath; ProcessName = "Antigravity IDE" }
        }
    }
    if ($Target -in @('All', 'Client')) {
        if (Test-Path $defaultClientPath) {
            $targets += [PSCustomObject]@{ Name = "Antigravity Client"; Path = $defaultClientPath; ProcessName = "Antigravity" }
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Error "No Antigravity installations found on this machine. Specify -CustomPath if installed elsewhere."
    exit 2
}

# ==============================================================================
# 3. Prepare Config Content
# ==============================================================================
$configContent = Get-Content $configSource -Raw -Encoding UTF8 | ConvertFrom-Json
$configContent.proxy.port = [int]$Port
$configJsonString = $configContent | ConvertTo-Json -Depth 10

# ==============================================================================
# 4. Deploy Files
# ==============================================================================
Write-Host "`n[*] Deploying No-TUN proxy files..." -ForegroundColor Cyan

foreach ($t in $targets) {
    Write-Host "  -> Deploying to $($t.Name) ($($t.Path))..." -ForegroundColor White
    $destDll = Join-Path $t.Path "version.dll"
    $destConfig = Join-Path $t.Path "config.json"

    # Backup if exists
    if ((Test-Path $destConfig) -and -not (Test-Path "$destConfig.bak")) {
        Copy-Item $destConfig "$destConfig.bak" -Force
    }
    if ((Test-Path $destDll) -and -not (Test-Path "$destDll.bak")) {
        Copy-Item $destDll "$destDll.bak" -Force
    }

    # Deploy DLL
    $needsCopy = $true
    if (Test-Path $destDll) {
        try {
            $srcHash = (Get-FileHash $dllSource -Algorithm SHA256).Hash
            $destHash = (Get-FileHash $destDll -Algorithm SHA256).Hash
            if ($srcHash -eq $destHash) {
                Write-Host "     [INFO] version.dll is already up-to-date." -ForegroundColor Gray
                $needsCopy = $false
            }
        } catch {
            $needsCopy = $true
        }
    }

    if ($needsCopy) {
        try {
            Copy-Item $dllSource $destDll -Force
            Write-Host "     [SUCCESS] version.dll deployed." -ForegroundColor Green
        } catch {
            Write-Host "     [WARN] Cannot overwrite version.dll because the application is running." -ForegroundColor Yellow
            Write-Host "            Run with -Restart or manually close Antigravity to update version.dll." -ForegroundColor Yellow
        }
    }

    # Deploy Config
    try {
        Set-Content -Path $destConfig -Value $configJsonString -Encoding UTF8 -Force
        Write-Host "     [SUCCESS] config.json deployed (Port: $Port)." -ForegroundColor Green
    } catch {
        Write-Host "     [ERROR] Failed to write config.json: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ==============================================================================
# 5. SOCKS5 Connectivity Test
# ==============================================================================
if (-not $SkipTest) {
    Write-Host "`n[*] Verifying SOCKS5 proxy connectivity (127.0.0.1:$Port)..." -ForegroundColor Cyan
    $testDomains = @("daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com")

    function Test-Socks5Tunnel($proxyHost, $proxyPort, $destHost, $destPort) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $async = $client.BeginConnect($proxyHost, $proxyPort, $null, $null)
            $success = $async.AsyncWaitHandle.WaitOne(3000, $false)
            if (-not $success) {
                $client.Close()
                return $false
            }
            $client.EndConnect($async)
            $stream = $client.GetStream()

            # Handshake: VER=5, NMETHODS=1, METHOD=0 (No Auth)
            $handshake = [byte[]](0x05, 0x01, 0x00)
            $stream.Write($handshake, 0, $handshake.Length)
            $res = New-Object byte[] 2
            $read = $stream.Read($res, 0, 2)
            if ($read -lt 2 -or $res[0] -ne 0x05 -or $res[1] -ne 0x00) {
                $client.Close()
                return $false
            }

            # Connect Request: CMD=1, RSV=0, ATYP=3, DOMAIN, PORT
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
            $read2 = $stream.Read($resp, 0, 10)
            $client.Close()

            if ($read2 -ge 4 -and $resp[1] -eq 0x00) {
                return $true
            } else {
                return $false
            }
        } catch {
            $client.Close()
            return $false
        }
    }

    foreach ($d in $testDomains) {
        $ok = Test-Socks5Tunnel "127.0.0.1" $Port $d 443
        if ($ok) {
            Write-Host "  [PASS] Tunnel to $d`:443 via 127.0.0.1:$Port succeeded." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Failed to establish tunnel to $d`:443. Check if your proxy client is running on port $Port." -ForegroundColor Yellow
        }
    }
}

# ==============================================================================
# 6. Process Management & Next Steps
# ==============================================================================
if ($Restart) {
    Write-Host "`n[*] Restarting Antigravity processes..." -ForegroundColor Cyan
    foreach ($t in $targets) {
        Stop-Process -Name $t.ProcessName -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    Write-Host "  -> Terminated active processes. Please launch Antigravity from your start menu or shortcut." -ForegroundColor Green
} else {
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "[NOTE] Files successfully installed!" -ForegroundColor Green
    Write-Host "To apply the new proxy hook, please COMPLETELY restart your Antigravity App/IDE." -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor Magenta
}

exit 0
