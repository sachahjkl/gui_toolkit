@echo off
:: Builds an example with the Odin compiler (https://odin-lang.org). Output: build\<example>.exe
::   build.bat [fidget|todo|smoke] [debug]        (default: fidget, optimized)
setlocal
cd /D "%~dp0"
set "EX=%1"
if "%EX%"=="" set "EX=fidget"
if not exist build mkdir build
:: exe icon: examples\<name>\<name>.rc when present (needs rc.exe from the Windows SDK, found by Odin)
set "RES="
if exist "examples\%EX%\%EX%.rc" set "RES=-resource:examples/%EX%/%EX%.rc"
if "%2"=="debug" (
  odin build examples/%EX% -out:build/%EX%.exe -debug -vet -subsystem:windows %RES%
) else (
  odin build examples/%EX% -out:build/%EX%.exe -o:speed -vet -subsystem:windows %RES%
)
if errorlevel 1 exit /b 1
echo built build\%EX%.exe
