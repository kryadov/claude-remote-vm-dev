# Windows (PowerShell) helper: list Claude Code sessions on the VM (reads rd.env).
# Usage:  .\sessions.ps1
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $here "rd.env"
if (-not (Test-Path $envFile)) {
    Write-Error "Create rd.env first (copy from rd.env.example)."
    exit 1
}

# Parse simple KEY="value" lines from rd.env.
$cfg = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
        $val = $matches[2].Trim().Trim('"').Trim("'")
        $val = $val -replace '\$\{?HOME\}?', $env:USERPROFILE
        $cfg[$matches[1]] = $val
    }
}

ssh -i $cfg.SSH_KEY "$($cfg.VM_USER)@$($cfg.VM_IP)" "bash -lc rd-list"
