@echo off
:: Shortcut: build.bat [example] [-debug] is tk build (tools/tk). Every other command: odin run tools\tk -- <command>.
odin run "%~dp0tools\tk" -out:"%~dp0build\tk.exe" -- build %*
