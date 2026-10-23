@echo off
rem Orca agent command override. See orca-agent.ps1 and docs/design.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0orca-agent.ps1" %*
