$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rd-connect-" + [guid]::NewGuid())
try {
    $helperDir = Join-Path $testRoot "helper"
    $binDir = Join-Path $testRoot "bin"
    New-Item -ItemType Directory -Force $helperDir, $binDir | Out-Null
    Copy-Item (Join-Path $root "connect.ps1") (Join-Path $helperDir "connect.ps1")
    @'
VM_IP="192.0.2.10"
VM_USER="developer"
SSH_KEY="C:\keys\example.key"
'@ | Set-Content -Encoding utf8 (Join-Path $helperDir "rd.env")
    @'
@echo off
echo %* > "%SSH_LOG%"
'@ | Set-Content -Encoding ascii (Join-Path $binDir "ssh.cmd")

    $log = Join-Path $testRoot "ssh.log"
    $env:SSH_LOG = $log
    $oldPath = $env:PATH
    $env:PATH = "$binDir;$oldPath"
    try {
        & (Join-Path $helperDir "connect.ps1") -Project backend -Session search -Type bugfix

        $command = Get-Content -Raw $log
        if ($command -notmatch 'rd-start.*backend.*--session.*search.*--type.*bugfix') {
            throw "connect.ps1 did not forward named-session start options: $command"
        }
        if ($command -notmatch 'rd-attach.*backend.*--session.*search') {
            throw "connect.ps1 did not attach the named session: $command"
        }

        & (Join-Path $helperDir "connect.ps1") -Tui

        $command = Get-Content -Raw $log
        if ($command -notmatch '-t .*bash -lc rd-tui') {
            throw "connect.ps1 -Tui did not run rd-tui over ssh: $command"
        }
    } finally {
        $env:PATH = $oldPath
    }
    Write-Output "connect.ps1 tests passed"
} finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
