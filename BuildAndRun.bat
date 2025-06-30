@echo off

if not exist .\\build mkdir .\\build

copy "code\\third_party\\SDL2.dll" /Y "build\\SDL2.dll"
copy "code\\third_party\\dxil.dll" /Y "build\\dxil.dll"
copy "code\\third_party\\dxcompiler.dll" /Y "build\\dxcompiler.dll"
copy "code\\third_party\\D3D12Core.dll" /Y "build\\D3D12Core.dll"
copy "code\\third_party\\D3D12Core.pdb" /Y "build\\D3D12Core.pdb"
copy "code\\third_party\\d3d12SDKLayers.dll" /Y "build\\d3d12SDKLayers.dll"
copy "code\\third_party\\d3d12SDKLayers.pdb" /Y "build\\d3d12SDKLayers.pdb"

odin run code %1 -out:build\\RK-Odin.exe