@echo off
REM Compile shaders to bytecode
REM Run this on Windows with DirectX SDK or Windows SDK installed

echo Compiling vertex shader...
fxc /T vs_5_0 /E VSMain /O3 /Fo vs_main.cso main.hlsl
if errorlevel 1 (
    echo Failed to compile vertex shader
    exit /b 1
)

echo Compiling pixel shader...
fxc /T ps_5_0 /E PSMain /O3 /Fo ps_main.cso main.hlsl
if errorlevel 1 (
    echo Failed to compile pixel shader
    exit /b 1
)

echo Compiling custom-post and bloom shaders...
fxc /T vs_5_0 /E VSCustomPost /O3 /Fo vs_custom_post.cso main.hlsl || exit /b 1
fxc /T vs_5_0 /E VSFullscreen /O3 /Fo vs_fullscreen.cso main.hlsl || exit /b 1
fxc /T ps_5_0 /E PSGlowExtract /O3 /Fo ps_glow_extract.cso main.hlsl || exit /b 1
fxc /T ps_5_0 /E PSGlowOcclude /O3 /Fo ps_glow_occlude.cso main.hlsl || exit /b 1
fxc /T ps_5_0 /E PSKawaseDown /O3 /Fo ps_kawase_down.cso main.hlsl || exit /b 1
fxc /T ps_5_0 /E PSKawaseUp /O3 /Fo ps_kawase_up.cso main.hlsl || exit /b 1
fxc /T ps_5_0 /E PSGlowComposite /O3 /Fo ps_glow_composite.cso main.hlsl || exit /b 1

echo.
echo Shaders compiled successfully!
echo.
echo Now run: python generate_zig.py
echo Or manually convert .cso files to Zig byte arrays
