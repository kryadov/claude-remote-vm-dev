# Windows (PowerShell) helper: SSH into the VM using values from rd.env.
#   .\connect.ps1
#   .\connect.ps1 -Tui
#   .\connect.ps1 <project> [source]
#   .\connect.ps1 backend -Session login-timeout -Type bugfix
param(
    [Parameter(Position = 0)] [string]$Project,
    [Parameter(Position = 1)] [string]$Source,
    [string]$Session = "default",
    [ValidateSet("feature", "bugfix")] [string]$Type,
    [string]$Base,
    [string]$Branch,
    [switch]$Tui
)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $here "rd.env"
if (-not (Test-Path $envFile)) {
    Write-Error "Create rd.env first (copy from rd.env.example)."
    exit 1
}

$cfg = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
        $val = $matches[2].Trim().Trim('"').Trim("'")
        $val = $val -replace '\$\{?HOME\}?', $env:USERPROFILE
        $cfg[$matches[1]] = $val
    }
}

function ConvertTo-BashLiteral([string]$Value) {
    $singleQuote = [string][char]39
    $replacement = $singleQuote + '"' + $singleQuote + '"' + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $replacement) + $singleQuote
}

function Join-BashCommand([string[]]$Arguments) {
    return (($Arguments | ForEach-Object { ConvertTo-BashLiteral $_ }) -join ' ')
}

$target = "$($cfg.VM_USER)@$($cfg.VM_IP)"
if ($Tui) {
    if ($Project) {
        Write-Error "-Tui takes no other arguments."
        exit 2
    }
    ssh -t -i $cfg.SSH_KEY $target "bash -lc rd-tui"
} elseif ($Project) {
    $start = @("rd-start", $Project)
    if ($Source) { $start += $Source }
    if ($Session -ne "default") { $start += @("--session", $Session) }
    if ($PSBoundParameters.ContainsKey("Type")) { $start += @("--type", $Type) }
    if ($Base) { $start += @("--base", $Base) }
    if ($Branch) { $start += @("--branch", $Branch) }

    $attach = @("rd-attach", $Project)
    if ($Session -ne "default") { $attach += @("--session", $Session) }
    $remoteCommand = (Join-BashCommand $start) + " && " + (Join-BashCommand $attach)
    $loginCommand = "bash -lc " + (ConvertTo-BashLiteral $remoteCommand)
    ssh -t -i $cfg.SSH_KEY $target $loginCommand
} else {
    ssh -i $cfg.SSH_KEY $target
}
