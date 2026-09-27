@echo off
setlocal enabledelayedexpansion

rem *** 把 7-Zip 加入 PATH（引号只用于包裹赋值，不进 PATH 值）***
set "PATH=C:\Program Files\7-Zip;%PATH%"

where /q git.exe || (
  echo ERROR: "git.exe" not found
  exit /b 1
)

rem *** 定位 7z.exe / 7za.exe ***
set "SZIP="
if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set "SZIP=%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || (
    echo ERROR: 7-Zip installation or "7za.exe" not found
    exit /b 1
  )
  set "SZIP=7za.exe"
)

rem *** 工具函数：命令存在性检查 ***
where /q curl.exe || (
  echo ERROR: "curl.exe" not found
  exit /b 1
)
where /q cmake.exe || (
  echo ERROR: "cmake.exe" not found
  exit /b 1
)


rem *** Visual Studio 环境 ***
where /q cl.exe || (
  set "__VSCMD_ARG_NO_LOGO=1"
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo ERROR: vswhere.exe not found at "!VSWHERE!"
    exit /b 1
  )
  set "VS="
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath`) do set "VS=%%i"
  if "!VS!" equ "" (
    echo ERROR: Visual Studio installation not found
    exit /b 1
  )
  call "!VS!\VC\Auxiliary\Build\vcvarsall.bat" amd64 || (
    echo ERROR: failed to initialize Visual Studio environment
    exit /b 1
  )
)


rem *** ninja ***
where /q ninja.exe
if errorlevel 1 (
  curl -LOsf https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-win.zip || (
    echo ERROR: failed to download ninja
    exit /b 1
  )
  "%SZIP%" x -bb0 -y ninja-win.zip 1>nul 2>nul || (
    echo ERROR: failed to extract ninja
    exit /b 1
  )
  del ninja-win.zip 1>nul 2>nul
  if not exist "%~dp0ninja.exe" (
    echo ERROR: ninja.exe not found after extraction
    exit /b 1
  )
)
rem 显式使用当前目录下的 ninja.exe，避免依赖 PATH 搜索当前目录
set "NINJA=%~dp0ninja.exe"
if not exist "!NINJA!" set "NINJA=ninja.exe"


rem *** clone aseprite repo ***
if not exist aseprite (
  call git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite
  if errorlevel 1 (
    echo ERROR: failed to clone repo
    exit /b 1
  )
) else (
  call git -C aseprite fetch --tags
  if errorlevel 1 (
    echo ERROR: failed to fetch repo
    exit /b 1
  )
)


rem *** 取最新 tag ***
if "%ASEPRITE_VERSION%" equ "" (
  set "ASEPRITE_VERSION="
  for /F "delims=" %%v in ('git -C aseprite tag --sort=-v:refname') do (
    if not defined ASEPRITE_VERSION set "ASEPRITE_VERSION=%%v"
  )
)
if not defined ASEPRITE_VERSION (
  echo ERROR: could not determine ASEPRITE_VERSION
  exit /b 1
)

echo building !ASEPRITE_VERSION!


rem *** 更新本地 aseprite 到选定 tag ***
call git -C aseprite clean --quiet -fdx
call git -C aseprite submodule foreach --recursive git clean -xfd

call git -C aseprite fetch --quiet --depth=1 --no-tags origin "!ASEPRITE_VERSION!:refs/remotes/origin/!ASEPRITE_VERSION!"
if errorlevel 1 (
  echo ERROR: failed to fetch repo
  exit /b 1
)

call git -C aseprite reset --quiet --hard "origin/!ASEPRITE_VERSION!"
if errorlevel 1 (
  echo ERROR: failed to update repo
  exit /b 1
)

call git -C aseprite submodule update --init --recursive
if errorlevel 1 (
  echo ERROR: failed to update submodules
  exit /b 1
)

rem *** 修正版本号 ***
where /q python.exe
if errorlevel 1 (
  echo ERROR: "python.exe" not found
  exit /b 1
)
python -c "import sys,pathlib; p=pathlib.Path('aseprite/src/ver/CMakeLists.txt'); v=p.read_text(); nv=v.replace('1.x-dev', sys.argv[1]); p.write_text(nv); sys.exit(0 if nv!=v else 1)" "!ASEPRITE_VERSION:~1!"
if errorlevel 1 (
  echo ERROR: failed to patch src/ver/CMakeLists.txt
  exit /b 1
)


rem *** download skia ***
set "SKIA_VERSION="
if exist "aseprite\laf\misc\skia-tag.txt" (
  set /p SKIA_VERSION=<aseprite\laf\misc\skia-tag.txt
) else (
  echo !ASEPRITE_VERSION! | findstr /i "beta" >nul
  if errorlevel 1 (
    set "SKIA_VERSION=m102-861e4743af"
  ) else (
    set "SKIA_VERSION=m124-08a5439a6b"
  )
)
if not defined SKIA_VERSION (
  echo ERROR: could not determine SKIA_VERSION
  exit /b 1
)

rem 用"关键文件存在"作为缓存校验，而不是只看目录
if not exist "skia-!SKIA_VERSION!\out\Release-x64\skia.lib" (
  if exist "skia-!SKIA_VERSION!" rd /s /q "skia-!SKIA_VERSION!"
  mkdir "skia-!SKIA_VERSION!"
  pushd "skia-!SKIA_VERSION!"
  curl -sfLO "https://github.com/aseprite/skia/releases/download/!SKIA_VERSION!/Skia-Windows-Release-x64.zip"
  if errorlevel 1 (
    echo ERROR: failed to download skia
    popd
    exit /b 1
  )
  "%SZIP%" x -y Skia-Windows-Release-x64.zip
  if errorlevel 1 (
    echo ERROR: failed to extract skia
    popd
    exit /b 1
  )
  del Skia-Windows-Release-x64.zip 1>nul 2>nul
  popd
)


rem *** build aseprite ***
if exist build rd /s /q build

cmake.exe                                                     ^
  -G Ninja                                                    ^
  -S aseprite                                                 ^
  -B build                                                    ^
  -DCMAKE_BUILD_TYPE=Release                                  ^
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW                          ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded                  ^
  -DENABLE_CCACHE=OFF                                         ^
  -DOPENSSL_USE_STATIC_LIBS=TRUE                              ^
  -DLAF_BACKEND=skia                                          ^
  -DSKIA_DIR="%CD%\skia-!SKIA_VERSION!"                       ^
  -DSKIA_LIBRARY_DIR="%CD%\skia-!SKIA_VERSION!\out\Release-x64"
if errorlevel 1 (
  echo ERROR: failed to configure build
  exit /b 1
)

"!NINJA!" -C build
if errorlevel 1 (
  echo ERROR: build failed
  exit /b 1
)


rem *** create output folder ***
set "OUTDIR=aseprite-!ASEPRITE_VERSION!"
if exist "!OUTDIR!" rd /s /q "!OUTDIR!"
mkdir "!OUTDIR!"
if errorlevel 1 (
  echo ERROR: failed to create output folder
  exit /b 1
)

echo # This file is here so Aseprite behaves as a portable program >"!OUTDIR!\aseprite.ini"

xcopy /E /Q /Y "aseprite\docs" "!OUTDIR!\docs\" >nul
if errorlevel 1 (
  echo ERROR: failed to copy docs
  exit /b 1
)

copy /Y "build\bin\aseprite.exe" "!OUTDIR!\" >nul
if errorlevel 1 (
  echo ERROR: failed to copy aseprite.exe
  exit /b 1
)

xcopy /E /Q /Y "build\bin\data" "!OUTDIR!\data\" >nul
if errorlevel 1 (
  echo ERROR: failed to copy data
  exit /b 1
)

if defined GITHUB_WORKFLOW (
  if not exist github mkdir github
  move "!OUTDIR!" github\ >nul
  if defined GITHUB_OUTPUT (
    echo ASEPRITE_VERSION=!ASEPRITE_VERSION!>>"%GITHUB_OUTPUT%"
  )
)

endlocal
exit /b 0