# 🤖 AI Agent Implementation Runbook / 系统指导规范

> **Audience**: AI Coding Agents, Pair Programmers (Antigravity Agent, Claude Code, Cursor, Copilot, Codex, OpenCode, etc.)  
> **Mission**: Resolve Antigravity connection timeouts (`daily-cloudcode-pa.googleapis.com:443`, `context deadline exceeded`, `Authentication Required`) **without forcing the user to enable system-wide TUN mode or install Proxifier**.

---

## 🎯 Task Context & Root Cause for AI

When a user in a restricted network region encounters:
```text
Authentication Required: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": context deadline exceeded
```
- **The True Cause**: Antigravity's core backend processes (`language_server.exe` / `agy.exe`) do not automatically inherit Windows system proxy settings or browser HTTP proxies.
- **The Solution**: Windows dynamic DLL search-order hijacking. Placing a proxy-injecting `version.dll` and `config.json` next to the main executables forces socket calls from whitelisted processes directly into the local SOCKS5 proxy port.
- **Architecture Trap**: Antigravity exists in **two separate distributions** on Windows:
  1. **Antigravity IDE** (VS Code base): `%LOCALAPPDATA%\Programs\Antigravity IDE\` (Main: `Antigravity IDE.exe`, Core: `agy.exe` / `language_server_windows_x64.exe`)
  2. **Antigravity Desktop Client**: `%LOCALAPPDATA%\Programs\antigravity\` (Main: `Antigravity.exe`, Core: `resources\bin\language_server.exe`)
  *⚠️ AI Agent Alert: Deploying to only one path will leave the other completely unproxied! Always check and deploy to both if they exist.*

---

## 🛠️ Deterministic 5-Step Agent Execution Workflow

When tasked with fixing Antigravity network or deploying this proxy, follow these deterministic steps:

### Step 1: Detect Application Paths
Run PowerShell to locate existing Antigravity installations:
```powershell
$idePath = Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE"
$clientPath = Join-Path $env:LOCALAPPDATA "Programs\antigravity"

Write-Host "IDE Exists: $(Test-Path $idePath)"
Write-Host "Client Exists: $(Test-Path $clientPath)"
```

### Step 2: Detect Active Local Proxy Port
Inspect active local listeners to identify the user's proxy client (Clash, Mihomo, V2RayN, Sing-box, Xray, etc.):
```powershell
$commonPorts = @(7897, 7890, 10808, 10809, 2080, 2081)
$detectedPort = 7897

$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0') } |
    Select-Object -ExpandProperty LocalPort

foreach ($p in $commonPorts) {
    if ($listeners -contains $p) {
        $detectedPort = $p
        break
    }
}
Write-Host "Detected Proxy Port: $detectedPort"
```

### Step 3: Deploy Files with Detected Port
Clone or download this repository, then execute `deploy.ps1` with the detected port:
```powershell
powershell -ExecutionPolicy Bypass -File deploy.ps1 -Port $detectedPort -Target All
```

#### Alternative: Manual Deployment via Agent Tools
If running scripts directly is restricted, you can read `config.json`, update `"proxy": { "port": <detectedPort> }`, and copy files using file write tools:
1. Ensure `target_processes` includes:
   `["agy.exe", "agy", "Antigravity IDE.exe", "Antigravity IDE", "Antigravity.exe", "language_server_windows_x64.exe", "language_server_windows", "language_server.exe", "node.exe", "git.exe", "gh.exe"]`
2. Copy `version.dll` and `config.json` to `%LOCALAPPDATA%\Programs\Antigravity IDE\`
3. Copy `version.dll` and `config.json` to `%LOCALAPPDATA%\Programs\antigravity\`

### Step 4: Verify SOCKS5 Connectivity
Verify the tunnel before advising the user:
```powershell
powershell -ExecutionPolicy Bypass -File verify.ps1
```
Or execute a Python one-liner to verify socket handshake:
```python
import socket, struct
s = socket.socket()
s.settimeout(3.0)
s.connect(('127.0.0.1', 7897)) # replace with detectedPort
s.sendall(b'\x05\x01\x00')
assert s.recv(2) == b'\x05\x00', 'Handshake failed'
req = b'\x05\x01\x00\x03\x1fdaily-cloudcode-pa.googleapis.com' + struct.pack('>H', 443)
s.sendall(req)
res = s.recv(10)
assert len(res) >= 4 and res[1] == 0, 'SOCKS5 connect failed'
print('SOCKS5 Tunnel: VERIFIED')
s.close()
```

### Step 5: Inform User to Restart
Because Windows loads `version.dll` only once when a process starts:
- Tell the user:
  > "已成功配置免 TUN 代理文件。请**彻底关闭并重新启动** Antigravity 客户端 / IDE（托盘图标需退出），新打开的进程将自动加载代理 Hook。"

---

## 🚨 Critical Troubleshooting Patterns for AI

| Symptom / Log Output | Root Cause | AI Remediation Action |
| :--- | :--- | :--- |
| `User location is not supported for the API use` | Proxy tunnel is working, but the proxy node IP is in an unsupported country or detected as a datacenter ASN. | **Do NOT modify DLL or configs.** Tell user to switch their proxy node to a residential/ISP node in a supported region (US, JP, SG, TW, etc.). |
| `Process cannot access version.dll because it is being used by another process` | Antigravity is currently running, locking the binary. | Check file hash first: if identical, skip copying. If different, prompt user to close Antigravity or execute with `-Restart`. |
| `Authentication Required` persists after restart | Port mismatch or proxy client protocol error. | Verify if the user's client uses SOCKS5 on that port. If the port only supports HTTP, modify `config.json` `"proxy": { "type": "http" }`. |
| AGY CLI in external PowerShell fails | External terminal was not launched by IDE/App. | Tell user to run `$env:ALL_PROXY = "socks5://127.0.0.1:<port>"` in their standalone terminal. |
