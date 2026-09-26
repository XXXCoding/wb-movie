@echo off
rem 一键部署入口：双击运行（如需参数，用法见 README.md）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
pause
