@echo off
REM Windows cmd wrapper around connect.ps1.
REM   connect.bat
REM   connect.bat -Tui
REM   connect.bat backend
REM   connect.bat backend -Session login-timeout -Type bugfix
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1" %*
exit /b %errorlevel%
