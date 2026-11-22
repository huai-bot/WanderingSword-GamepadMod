@echo off
rem Build the xinput1_3 proxy DLL into build\xinput1_3.dll
setlocal
set ROOT=%~dp0..
if "%VCVARS%"=="" set VCVARS=D:\TOOLS\VS\VS\VC\Auxiliary\Build\vcvars64.bat
if not exist "%VCVARS%" (
  echo vcvars64.bat not found. Set VCVARS to your Visual Studio vcvars64.bat path.
  exit /b 1
)
call "%VCVARS%" >nul || exit /b 1
if not exist "%ROOT%\build" mkdir "%ROOT%\build"
pushd "%ROOT%\build"
cl /nologo /LD /O2 /utf-8 /EHsc /W3 /std:c++17 "%ROOT%\src\native\wsmod.cpp" ^
   /link /DEF:"%ROOT%\src\native\xinput1_3.def" user32.lib gdi32.lib winmm.lib ole32.lib windowscodecs.lib /OUT:xinput1_3.dll
set ERR=%ERRORLEVEL%
popd
if not "%ERR%"=="0" ( echo BUILD FAILED & exit /b %ERR% )
echo built %ROOT%\build\xinput1_3.dll
