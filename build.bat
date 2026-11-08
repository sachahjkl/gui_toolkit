@echo off
:: Shortcut: build.bat [example] [-debug] is tk build (tools/tk). Every other command: odin run tools\tk -- <command>.
cd /D "%~dp0"
if not exist build mkdir build
odin run tools\tk -out:build\tk.exe -keep-executable -- build %*
