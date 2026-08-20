@echo off
REM Windows (cmd) helper: list Claude Code sessions on the VM (reads rd.env).
REM Usage:  sessions.bat   (or double-click)
setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "ENVFILE=%HERE%rd.env"

if not exist "%ENVFILE%" (
    echo Create rd.env first ^(copy from rd.env.example^).
    exit /b 1
)

REM Parse simple KEY="value" lines from rd.env (eol=# skips comment lines).
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENVFILE%") do (
    set "key=%%A"
    set "val=%%B"
    set "val=!val:"=!"
    set "val=!val:${HOME}=%USERPROFILE%!"
    set "val=!val:$HOME=%USERPROFILE%!"
    set "!key!=!val!"
)

if "%SSH_KEY%"=="" ( echo SSH_KEY missing from rd.env & exit /b 1 )

ssh -i "%SSH_KEY%" "%VM_USER%@%VM_IP%" "bash -lc rd-list"

endlocal
