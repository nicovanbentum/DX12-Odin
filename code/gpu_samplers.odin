package main

import "vendor:directx/d3d12"

SamplerIndex :: enum 
{
    POINT_WRAP,
    MIN_MAG_MIP_POINT_WRAP,
    MIN_MAG_MIP_POINT_CLAMP,
    MIN_MAG_MIP_LINEAR_WRAP,
    MIN_MAG_MIP_LINEAR_CLAMP,
    ANISOTROPIC_WRAP,
    ANISOTROPIC_CLAMP
}

STATIC_SAMPLER_DESC : [SamplerIndex] d3d12.STATIC_SAMPLER_DESC = {
    .POINT_WRAP = d3d12.STATIC_SAMPLER_DESC {
        .MIN_MAG_MIP_POINT,  .WRAP, .WRAP, .WRAP,
        0.0, d3d12.MAX_MAXANISOTROPY, .NEVER, .TRANSPARENT_BLACK, 0.0, 1.0, u32(SamplerIndex.POINT_WRAP), 0,
        .ALL
    },
    
    .MIN_MAG_MIP_POINT_WRAP = d3d12.STATIC_SAMPLER_DESC {
        .MIN_MAG_MIP_POINT,  .WRAP, .WRAP, .WRAP,
        0.0, d3d12.MAX_MAXANISOTROPY, .NEVER, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.MIN_MAG_MIP_POINT_WRAP), 0,
        .ALL
    },
    
    .MIN_MAG_MIP_POINT_CLAMP = d3d12.STATIC_SAMPLER_DESC {
        .MIN_MAG_MIP_POINT,  .CLAMP, .CLAMP, .CLAMP,
        0.0, d3d12.MAX_MAXANISOTROPY, .NEVER, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.MIN_MAG_MIP_POINT_CLAMP), 0,
        .ALL
    },
    
    .MIN_MAG_MIP_LINEAR_WRAP = d3d12.STATIC_SAMPLER_DESC {
        .MIN_MAG_MIP_LINEAR,  .WRAP, .WRAP, .WRAP,
        0.0, d3d12.MAX_MAXANISOTROPY, .ALWAYS, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.MIN_MAG_MIP_LINEAR_WRAP), 0,
        .ALL
    },
    
    .MIN_MAG_MIP_LINEAR_CLAMP = d3d12.STATIC_SAMPLER_DESC {
        .MIN_MAG_MIP_LINEAR,  .CLAMP, .CLAMP, .CLAMP,
        0.0, d3d12.MAX_MAXANISOTROPY, .ALWAYS, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.MIN_MAG_MIP_LINEAR_CLAMP), 0,
        .ALL
    },
    
    .ANISOTROPIC_WRAP = d3d12.STATIC_SAMPLER_DESC {
        .ANISOTROPIC, .WRAP, .WRAP, .WRAP,
        0.0, d3d12.MAX_MAXANISOTROPY, .ALWAYS, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.ANISOTROPIC_WRAP), 0,
        .ALL
    },
    
    .ANISOTROPIC_CLAMP = d3d12.STATIC_SAMPLER_DESC {
        .ANISOTROPIC,  .CLAMP, .CLAMP, .CLAMP,
        0.0, d3d12.MAX_MAXANISOTROPY, .NEVER, .TRANSPARENT_BLACK, 0.0, d3d12.FLOAT32_MAX, u32(SamplerIndex.ANISOTROPIC_CLAMP), 0,
        .ALL
    }
}