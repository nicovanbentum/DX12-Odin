@echo off

if not exist .\\build mkdir .\\build

xcopy "code\\third_party\\SDL2.dll" /D /Y "build\\SDL2.dll"
xcopy "code\\third_party\\dxil.dll" /D /Y "build\\dxil.dll"
xcopy "code\\third_party\\D3D12Core.dll" /F /D /Y "build\\D3D12Core.dll"
xcopy "code\\third_party\\D3D12Core.pdb" /F /D /Y "build\\D3D12Core.pdb"
xcopy "code\\third_party\\d3d12SDKLayers.dll" /F /D /Y "build\\d3d12SDKLayers.dll"
xcopy "code\\third_party\\d3d12SDKLayers.pdb" /F /D /Y "build\\d3d12SDKLayers.pdb"

odin run code %1 -out:build\\RK-Odin.exe