@echo off
REM Double-click this file to run the compiler.
REM It just launches the PowerShell script sitting next to it, bypassing
REM the "scripts are disabled" policy for this one run only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compile-tortoise-wow.ps1"
