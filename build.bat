@echo off
rem Builds the cross-platform core package (CompositorCore, see docs\cross-platform.md)
rem on Windows. Everything stays under output\: SwiftPM intermediates in output\.build,
rem SwiftPM's cache in output\.cache, copied build products in output\bin, logs next to
rem them.
rem
rem Usage:
rem   build.bat            build release (the default)
rem   build.bat debug      build debug
rem   build.bat test       also build and run the test suite
setlocal

cd /d "%~dp0"

set "OUTPUT_DIR=output"
set "SCRATCH_DIR=%OUTPUT_DIR%\.build"
set "CACHE_DIR=%OUTPUT_DIR%\.cache"
set "BIN_DIR=%OUTPUT_DIR%\bin"
set "BUILD_LOG=%OUTPUT_DIR%\build.log"
set "TEST_LOG=%OUTPUT_DIR%\test.log"

set "CONFIG=release"
set "RUN_TESTS="

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="release" (set "CONFIG=release" & shift & goto :parse_args)
if /i "%~1"=="debug" (set "CONFIG=debug" & shift & goto :parse_args)
if /i "%~1"=="test" (set "RUN_TESTS=1" & shift & goto :parse_args)
echo error: unknown argument "%~1" (expected release, debug or test)
exit /b 1
:args_done

where swift >nul 2>nul
if errorlevel 1 (
    echo error: swift is not in PATH - install a toolchain from https://www.swift.org/install/
    echo and run this script from a Swift command line environment.
    exit /b 1
)

if not exist "%SCRATCH_DIR%" mkdir "%SCRATCH_DIR%"
if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

swift --version > "%BUILD_LOG%" 2>&1

set "SWIFT_FLAGS=-c %CONFIG% --scratch-path %SCRATCH_DIR% --cache-path %CACHE_DIR%"

echo Building CompositorCore (%CONFIG%), intermediates in %SCRATCH_DIR%
swift build %SWIFT_FLAGS% >> "%BUILD_LOG%" 2>&1
if errorlevel 1 (
    type "%BUILD_LOG%"
    echo error: build failed, see %BUILD_LOG%
    exit /b 1
)
type "%BUILD_LOG%"

for /f "delims=" %%p in ('swift build %SWIFT_FLAGS% --show-bin-path') do set "BIN_PATH=%%p"
echo Copying build products from %BIN_PATH% to %BIN_DIR%
if exist "%BIN_PATH%\*.a" copy /y "%BIN_PATH%\*.a" "%BIN_DIR%" >nul
if exist "%BIN_PATH%\*.lib" copy /y "%BIN_PATH%\*.lib" "%BIN_DIR%" >nul
if exist "%BIN_PATH%\*.dll" copy /y "%BIN_PATH%\*.dll" "%BIN_DIR%" >nul
if exist "%BIN_PATH%\*.exe" copy /y "%BIN_PATH%\*.exe" "%BIN_DIR%" >nul
if exist "%BIN_PATH%\*.pdb" copy /y "%BIN_PATH%\*.pdb" "%BIN_DIR%" >nul
if exist "%BIN_PATH%\Modules" xcopy /e /i /y "%BIN_PATH%\Modules" "%BIN_DIR%\Modules" >nul

if defined RUN_TESTS (
    echo Running tests, log in %TEST_LOG%
    swift test %SWIFT_FLAGS% > "%TEST_LOG%" 2>&1
    if errorlevel 1 (
        type "%TEST_LOG%"
        echo error: tests failed, see %TEST_LOG%
        exit /b 1
    )
    type "%TEST_LOG%"
)

echo Done. Build products are in %BIN_DIR%.
endlocal
