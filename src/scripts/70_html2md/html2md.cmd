@echo off
where pwsh >nul 2>nul
if %errorlevel%==0 (
	pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0html2md.ps1"
) else (
	echo PowerShell 7 (pwsh) が見つかりません。このスクリプトは PowerShell 6 以降が必要です。
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0html2md.ps1"
)
pause