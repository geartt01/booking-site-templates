@echo off
rem Preview the built sites at http://localhost:8787/ . Stop with Ctrl+C.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
