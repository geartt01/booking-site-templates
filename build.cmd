@echo off
rem Builds client sites into dist\. Usage: build.cmd [client-folder-name]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
if "%~1"=="" pause
