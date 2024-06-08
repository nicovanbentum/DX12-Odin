package main

import "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

panic_if_failed :: proc(result : windows.HRESULT) 
{
    if !windows.SUCCEEDED(result) do panic("HRESULT FAILED")
}

gpu_set_debug_name :: proc(in_resource : ^d3d12.IResource, in_name : cstring)
{
    // in_resource.SetName(in_resource, in_name)
}



cd3dx12_viewport :: proc(in_resource : ^d3d12.IResource, in_mip := 0) -> d3d12.VIEWPORT
{
    desc : d3d12.RESOURCE_DESC
    in_resource->GetDesc(&desc)

    return d3d12.VIEWPORT {
        TopLeftX = 0,
        TopLeftY = 0,
        Width = f32(desc.Width),
        Height = f32(desc.Height),
        MinDepth = d3d12.MIN_DEPTH,
        MaxDepth = d3d12.MAX_DEPTH
    }
}

cd3dx12_buffer_desc :: proc(in_width : u64, in_flags : d3d12.RESOURCE_FLAGS = {}, in_alignment : u64 = 0) -> d3d12.RESOURCE_DESC 
{
    return d3d12.RESOURCE_DESC { 
        Dimension = .BUFFER, 
        Alignment = in_alignment, 
        Width = in_width, 
        Height = 1, 
        DepthOrArraySize = 1, 
        MipLevels = 1,
        Format = .UNKNOWN,
        SampleDesc = dxgi.SAMPLE_DESC { 1, 0 },
        Flags = in_flags,
        Layout = .ROW_MAJOR
    }
}

cd3dx12_texture_desc :: proc(
    in_dimension : d3d12.RESOURCE_DIMENSION,
    in_format : dxgi.FORMAT, 
    in_width : u64, 
    in_height : u32, 
    in_arraysize : u16, 
    in_mips : u16, 
    in_sample_count : u32, 
    in_sample_quality : u32, 
    in_flags : d3d12.RESOURCE_FLAGS = {},
    in_layout : d3d12.TEXTURE_LAYOUT = d3d12.TEXTURE_LAYOUT.UNKNOWN,
    in_alignment : u64 = 0
) -> d3d12.RESOURCE_DESC
{
    return d3d12.RESOURCE_DESC { 
        Dimension = in_dimension, 
        Alignment = in_alignment, 
        Width = in_width, 
        Height = in_height, 
        DepthOrArraySize = in_arraysize, 
        MipLevels = in_mips,
        Format = in_format,
        SampleDesc = dxgi.SAMPLE_DESC { in_sample_count, in_sample_quality },
        Flags = in_flags,
        Layout = in_layout
    }
}

cd3dx12_texture2d_desc :: proc(
    in_format : dxgi.FORMAT, 
    in_width : u64, 
    in_height : u32, 
    in_arraysize : u16 = 1, 
    in_mips : u16 = 0, 
    in_sample_count : u32 = 1, 
    in_sample_quality : u32 = 0,
    in_flags : d3d12.RESOURCE_FLAGS = {},
    in_layout : d3d12.TEXTURE_LAYOUT = d3d12.TEXTURE_LAYOUT.UNKNOWN,
    in_alignment : u64 = 0
) -> d3d12.RESOURCE_DESC
{
    return cd3dx12_texture_desc(.TEXTURE2D, in_format, in_width, in_height, max(in_arraysize, 1), in_mips, max(in_sample_count, 1), in_sample_quality, in_flags, in_layout, in_alignment)
}

cd3dx12_barrier_transition :: proc(in_resource : ^d3d12.IResource, in_before_state : d3d12.RESOURCE_STATES, in_after_state : d3d12.RESOURCE_STATES, in_subresource : u32 = 0) -> d3d12.RESOURCE_BARRIER
{
    return d3d12.RESOURCE_BARRIER {
        Type = .TRANSITION,
        Transition = d3d12.RESOURCE_TRANSITION_BARRIER {
            pResource = in_resource,
            StateBefore = in_before_state,
            StateAfter = in_after_state,
            Subresource = in_subresource
        }
    }
}

CD3DX12_BLEND_DESC :: proc() -> d3d12.BLEND_DESC
{
    result := d3d12.BLEND_DESC {
        AlphaToCoverageEnable = windows.FALSE, 
        IndependentBlendEnable = windows.FALSE,
    }

    for &desc in result.RenderTarget do desc = d3d12.RENDER_TARGET_BLEND_DESC {
        windows.FALSE, windows.FALSE, .ONE, .ZERO, .ADD, .ONE, .ZERO, .ADD, .NOOP, 0xFF
    }

    return result
}

CD3DX12_RASTERIZER_DESC :: proc() -> d3d12.RASTERIZER_DESC
{
    return d3d12.RASTERIZER_DESC {
        FillMode = .SOLID,
        CullMode = .BACK,
        FrontCounterClockwise = windows.FALSE,
        DepthBias = d3d12.DEFAULT_DEPTH_BIAS,
        DepthBiasClamp = d3d12.DEFAULT_DEPTH_BIAS_CLAMP,
        SlopeScaledDepthBias = d3d12.DEFAULT_SLOPE_SCALED_DEPTH_BIAS,
        DepthClipEnable = windows.TRUE,
        MultisampleEnable = windows.FALSE,
        AntialiasedLineEnable = windows.FALSE,
        ForcedSampleCount = 0,
        ConservativeRaster = .OFF
    }
}

CD3DX12_DEPTH_STENCIL_DESC :: proc() -> d3d12.DEPTH_STENCIL_DESC
{
    return d3d12.DEPTH_STENCIL_DESC {
        DepthEnable = windows.TRUE,
        DepthWriteMask = .ALL,
        DepthFunc = .LESS,
        StencilEnable = windows.FALSE,
        StencilReadMask = d3d12.DEFAULT_STENCIL_READ_MASK,
        StencilWriteMask = d3d12.DEFAULT_STENCIL_WRITE_MASK,
        FrontFace = d3d12.DEPTH_STENCILOP_DESC { .KEEP, .KEEP, .KEEP, .ALWAYS },
        BackFace = d3d12.DEPTH_STENCILOP_DESC { .KEEP, .KEEP, .KEEP, .ALWAYS },
    }
}

depth_to_srv_format :: proc(in_format : dxgi.FORMAT) -> dxgi.FORMAT
{
    #partial switch (in_format)
    {
        case .D16_UNORM: return .R16_FLOAT;
        case .D32_FLOAT: return .R32_FLOAT;
        case .D24_UNORM_S8_UINT: return .R24_UNORM_X8_TYPELESS;
        case .D32_FLOAT_S8X24_UINT: return .R32_FLOAT_X8X24_TYPELESS;
    }

    return in_format;
}

bits_per_pixel :: proc(in_format : dxgi.FORMAT) -> u64
{
    #partial switch (in_format)
    {
        case .R32G32B32A32_TYPELESS, .R32G32B32A32_FLOAT, .R32G32B32A32_UINT, .R32G32B32A32_SINT:
            return 128

        case .R32G32B32_TYPELESS, .R32G32B32_FLOAT, .R32G32B32_UINT, .R32G32B32_SINT:
            return 96

        case .R16G16B16A16_TYPELESS,
             .R16G16B16A16_FLOAT,
             .R16G16B16A16_UNORM,
             .R16G16B16A16_UINT,
             .R16G16B16A16_SNORM,
             .R16G16B16A16_SINT,
             .R32G32_TYPELESS,
             .R32G32_FLOAT,
             .R32G32_UINT,
             .R32G32_SINT,
             .R32G8X24_TYPELESS,
             .D32_FLOAT_S8X24_UINT,
             .R32_FLOAT_X8X24_TYPELESS,
             .X32_TYPELESS_G8X24_UINT,
             .Y416,
             .Y210,
             .Y216:
            return 64

        case .R10G10B10A2_TYPELESS,
             .R10G10B10A2_UNORM,
             .R10G10B10A2_UINT,
             .R11G11B10_FLOAT,
             .R8G8B8A8_TYPELESS,
             .R8G8B8A8_UNORM,
             .R8G8B8A8_UNORM_SRGB,
             .R8G8B8A8_UINT,
             .R8G8B8A8_SNORM,
             .R8G8B8A8_SINT,
             .R16G16_TYPELESS,
             .R16G16_FLOAT,
             .R16G16_UNORM,
             .R16G16_UINT,
             .R16G16_SNORM,
             .R16G16_SINT,
             .R32_TYPELESS,
             .D32_FLOAT,
             .R32_FLOAT,
             .R32_UINT,
             .R32_SINT,
             .R24G8_TYPELESS,
             .D24_UNORM_S8_UINT,
             .R24_UNORM_X8_TYPELESS,
             .X24_TYPELESS_G8_UINT,
             .R9G9B9E5_SHAREDEXP,
             .R8G8_B8G8_UNORM,
             .G8R8_G8B8_UNORM,
             .B8G8R8A8_UNORM,
             .B8G8R8X8_UNORM,
             .R10G10B10_XR_BIAS_A2_UNORM,
             .B8G8R8A8_TYPELESS,
             .B8G8R8A8_UNORM_SRGB,
             .B8G8R8X8_TYPELESS,
             .B8G8R8X8_UNORM_SRGB,
             .AYUV,
             .Y410,
             .YUY2:
            return 32

        case .P010, .P016:
            return 24

        case .R8G8_TYPELESS,
             .R8G8_UNORM,
             .R8G8_UINT,
             .R8G8_SNORM,
             .R8G8_SINT,
             .R16_TYPELESS,
             .R16_FLOAT,
             .D16_UNORM,
             .R16_UNORM,
             .R16_UINT,
             .R16_SNORM,
             .R16_SINT,
             .B5G6R5_UNORM,
             .B5G5R5A1_UNORM,
             .A8P8,
             .B4G4R4A4_UNORM:
            return 16

        case .NV12, ._420_OPAQUE, .NV11:
            return 12

        case .R8_TYPELESS,
             .R8_UNORM,
             .R8_UINT,
             .R8_SNORM,
             .R8_SINT,
             .A8_UNORM,
             .BC2_TYPELESS,
             .BC2_UNORM,
             .BC2_UNORM_SRGB,
             .BC3_TYPELESS,
             .BC3_UNORM,
             .BC3_UNORM_SRGB,
             .BC5_TYPELESS,
             .BC5_UNORM,
             .BC5_SNORM,
             .BC6H_TYPELESS,
             .BC6H_UF16,
             .BC6H_SF16,
             .BC7_TYPELESS,
             .BC7_UNORM,
             .BC7_UNORM_SRGB,
             .AI44,
             .IA44,
             .P8:
            return 8

        case .R1_UNORM:
            return 1

        case .BC1_TYPELESS,
             .BC1_UNORM,
             .BC1_UNORM_SRGB,
             .BC4_TYPELESS,
             .BC4_UNORM,
             .BC4_SNORM:
            return 4
    }

    return 0
}