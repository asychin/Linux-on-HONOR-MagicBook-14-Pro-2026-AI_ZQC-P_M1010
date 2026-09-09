@echo off
setlocal
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
set "OUT=%~dp0bin"
if not exist "%CSC%" (
  echo C# compiler not found: %CSC% 1>&2
  exit /b 1
)
if not exist "%OUT%" mkdir "%OUT%"
"%CSC%" /nologo /platform:x64 /optimize+ /out:"%OUT%\HonorWmiRead.exe" "%~dp0Program.cs"
if errorlevel 1 exit /b %errorlevel%
echo %OUT%\HonorWmiRead.exe
