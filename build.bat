@echo off
:: Builds an example with the Odin compiler (https://odin-lang.org). Output: build\<example>.exe
::   build.bat [fidget|todo|smoke] [debug]        (default: fidget, optimized)
setlocal
cd /D "%~dp0"
set "EX=%1"
if "%EX%"=="" set "EX=fidget"
if not exist build mkdir build
if exist "examples\%EX%\data" copy /y "examples\%EX%\data\*" build >nul
if "%2"=="debug" (
  odin build examples/%EX% -out:build/%EX%.exe -debug -vet -subsystem:windows
) else (
  odin build examples/%EX% -out:build/%EX%.exe -o:speed -vet -subsystem:windows
)
if errorlevel 1 exit /b 1
echo built build\%EX%.exe
