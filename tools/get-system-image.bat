@echo off
rem get-system-image.bat: download the TotV system image parts from GitHub, check them
rem and merge them into one ISO (Windows 10/11; uses the built-in curl and PowerShell).
rem
rem   get-system-image.bat              the version below (TOTV_VERSION)
rem   get-system-image.bat 0.2.0        another version
rem
rem Result: totv-system-<version>-x86_64.iso next to this file. Parts already downloaded
rem (with the right size) are not downloaded again. Copy the ISO, or the parts with the
rem .parts file, to a USB stick: the TotV installer finds it there and installs offline.
setlocal EnableExtensions EnableDelayedExpansion

set "TOTV_VERSION=0.2.0"
if not "%~1"=="" set "TOTV_VERSION=%~1"
set "BASE=https://github.com/SoulVoid0/TotV/releases/download/v%TOTV_VERSION%"
set "NAME=totv-system-%TOTV_VERSION%-x86_64.iso"
cd /d "%~dp0"

where curl >nul 2>nul || (echo curl.exe was not found ^(Windows 10 1803 or newer has it^). & goto :fail)

echo === TotV %TOTV_VERSION% system image
echo Downloading the index %NAME%.parts ...
curl -fL --retry 3 -o "%NAME%.parts" "%BASE%/%NAME%.parts" || (echo Could not download the index. Is v%TOTV_VERSION% released? & goto :fail)

set "WHOLE_SIZE="
set "WHOLE_SUM="
for /f "usebackq tokens=1-4" %%a in ("%NAME%.parts") do (
    if "%%a"=="image" (
        set "WHOLE_SIZE=%%b"
        set "WHOLE_SUM=%%c"
    )
)
if not defined WHOLE_SUM (echo The index is not valid. & goto :fail)

set "LIST="
set /a N=0
for /f "usebackq tokens=1-4" %%a in ("%NAME%.parts") do (
    if "%%a"=="part" (
        set /a N+=1
        call :getpart "%%d" %%b %%c || goto :fail
        if defined LIST (set "LIST=!LIST!+"%%d"") else (set "LIST="%%d"")
    )
)
if %N%==0 (echo The index lists no parts. & goto :fail)

echo.
echo Merging %N% parts into %NAME% ...
if exist "%NAME%" del "%NAME%"
copy /b !LIST! "%NAME%" >nul || (echo Merging failed ^(disk full?^). & goto :fail)

echo Checking the merged image (SHA-256, this takes a minute) ...
call :sha256 "%NAME%" SUM
if /i not "!SUM!"=="%WHOLE_SUM%" (echo The merged image is damaged: SHA-256 mismatch. & goto :fail)
for %%f in ("%NAME%") do set "SIZE=%%~zf"
echo.
echo Done: %CD%\%NAME%  (!SIZE! bytes, SHA-256 OK)
echo You can delete the .partNN files now, or keep them for the TotV installer.
pause
exit /b 0

rem --- :getpart NAME SIZE SHA256 --------------------------------------------------------
:getpart
set "PART=%~1"
set "WANT_SIZE=%~2"
set "WANT_SUM=%~3"
set "HAVE_SIZE=0"
if exist "%PART%" for %%f in ("%PART%") do set "HAVE_SIZE=%%~zf"
if "%HAVE_SIZE%"=="%WANT_SIZE%" (
    echo %PART% is already here.
) else (
    echo.
    echo Downloading %PART% ^(%WANT_SIZE% bytes^) ...
    curl -fL --retry 5 --retry-delay 5 -C - -o "%PART%" "%BASE%/%PART%" || (echo Downloading %PART% failed. Run this file again to resume. & exit /b 1)
    for %%f in ("%PART%") do set "HAVE_SIZE=%%~zf"
)
if not "%HAVE_SIZE%"=="%WANT_SIZE%" (echo %PART% has the wrong size; delete it and run this file again. & exit /b 1)
echo Checking %PART% ...
call :sha256 "%PART%" SUM
if /i not "%SUM%"=="%WANT_SUM%" (echo %PART% is damaged ^(SHA-256 mismatch^); delete it and run this file again. & exit /b 1)
exit /b 0

rem --- :sha256 FILE VAR -----------------------------------------------------------------
:sha256
set "%~2="
for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath '%~1').Hash.ToLower()"`) do set "%~2=%%h"
exit /b 0

:fail
echo.
echo FAILED.
pause
exit /b 1
