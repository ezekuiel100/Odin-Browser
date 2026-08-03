@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul

set IMGUI_DIR=%~dp0imgui
set BACKENDS=%~dp0imgui\backends
set SDL2_INC=%~dp0backend_deps\SDL2\include
set SDL2_BIN=%~dp0backend_deps\SDL2-bin
set OUT_LIB=%~dp0imgui_windows_x64.lib
set OBJ_DIR=%~dp0obj_sdl2
set FORCE_H=%~dp0force_c_api.h

mkdir "%OBJ_DIR%" 2>nul
cd /d "%OBJ_DIR%"

echo Compilando imgui_impl_sdl2.cpp...
cl /O2 /I"%IMGUI_DIR%" /I"%SDL2_INC%" /FI"%FORCE_H%" /c "%BACKENDS%\imgui_impl_sdl2.cpp"
if errorlevel 1 goto fail

echo Compilando imgui_impl_sdlrenderer2.cpp...
cl /O2 /I"%IMGUI_DIR%" /I"%SDL2_INC%" /FI"%FORCE_H%" /c "%BACKENDS%\imgui_impl_sdlrenderer2.cpp"
if errorlevel 1 goto fail

echo Removendo objetos antigos do lib...
lib "%OUT_LIB%" /REMOVE:"%OBJ_DIR%\imgui_impl_sdl2.obj" 2>nul
lib "%OUT_LIB%" /REMOVE:"%OBJ_DIR%\imgui_impl_sdlrenderer2.obj" 2>nul

echo Adicionando novos objetos ao lib...
lib "%OUT_LIB%" "%OBJ_DIR%\imgui_impl_sdl2.obj" "%OBJ_DIR%\imgui_impl_sdlrenderer2.obj"
if errorlevel 1 goto fail

echo Sucesso!
goto end

:fail
echo FALHOU.
exit /b 1

:end
