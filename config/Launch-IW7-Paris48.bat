@echo off
setlocal
cd /d "%~dp0"
if not exist "iw7-paris48.exe" (
  echo Install the matching client update beside this launcher first.
  pause
  exit /b 1
)
start "" "%~dp0iw7-paris48.exe" -noupdate -nosteam -cpMode -paris-capacity-64 -paris-capacity-production %*
