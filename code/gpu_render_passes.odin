package main

import "core:fmt"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

RenderPass :: struct($T : typeid)
{
    m_name : string,
    m_data : T,
    m_exec : proc(device : ^GPUDevice, cmd_list : ^d3d12.IGraphicsCommandList, data : ^T)
}

AnyRenderPass :: union
{
    GBufferRenderPass,
    DefaultTexturesPass,
    FinalComposeRenderPass
}

exec_render_pass :: proc(in_device : ^GPUDevice, in_cmd_list : ^d3d12.IGraphicsCommandList, in_pass : ^AnyRenderPass)
{
    switch &pass in in_pass 
    {
        case GBufferRenderPass : pass.m_exec(in_device, in_cmd_list, &pass.m_data)
        case DefaultTexturesPass : pass.m_exec(in_device, in_cmd_list, &pass.m_data)
        case FinalComposeRenderPass : pass.m_exec(in_device, in_cmd_list, &pass.m_data)
    }
}

DefaultTexturesData :: struct
{
    m_white_texture : RenderGraphResourceID,
    m_black_texture : RenderGraphResourceID
}

DefaultTexturesPass :: RenderPass(DefaultTexturesData)

GBufferRenderPassData :: struct
{
    m_render_texture : RenderGraphResourceID,
    m_depth_stencil_texture : RenderGraphResourceID
}

GBufferRenderPass :: RenderPass(GBufferRenderPassData)

FinalComposeRenderPassData :: struct
{
    m_output_texture : RenderGraphResourceID,
    m_input_texture : RenderGraphResourceViewID,
    m_bloom_texture : RenderGraphResourceViewID
}

FinalComposeRenderPass :: RenderPass(FinalComposeRenderPassData)

add_gbuffer_pass :: proc(using in_render_graph : ^RenderGraph) -> GBufferRenderPassData
{
    render_texture := gpu_rg_create_texture(&m_builder, GPUTextureDesc{
        format = .R32G32B32A32_FLOAT,
        width  = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        usage  = .RENDER_TARGET,
        debug_name = "RT_GBufferColor"
    })

    depth_texture := gpu_rg_create_texture(&m_builder, GPUTextureDesc{
        format = .D32_FLOAT_S8X24_UINT,
        width  = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        usage  = .DEPTH_STENCIL_TARGET,
        debug_name = "RT_GBufferDepth"
    })

    return gpu_rg_add_pass(in_render_graph, GBufferRenderPass { 
        m_data = {
            m_render_texture = gpu_rg_create_texture(&m_builder, GPUTextureDesc{
                format = .R32G32B32A32_FLOAT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                debug_name = "RT_GBufferColor"
            }),
            m_depth_stencil_texture = gpu_rg_create_texture(&m_builder, GPUTextureDesc{
                format = .D32_FLOAT_S8X24_UINT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .DEPTH_STENCIL_TARGET,
                debug_name = "RT_GBufferDepth"
            })
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^d3d12.IGraphicsCommandList, data : ^GBufferRenderPassData) {
            //clear_color := [4]f32 {0.0, 0.0, 0.0, 0.0}
            //gpu_clear_render_target(in_device, in_cmd_list, 0, &clear_color)
            //gpu_clear_depth_stencil_target(in_device, in_cmd_list, 1.0, 0)
            fmt.println("exec gbuffer pass")
            
        }
    })
}

add_default_textures_pass :: proc(using in_render_graph : ^RenderGraph, in_device : ^GPUDevice, in_black_texture : GPUTextureID, in_white_texture : GPUTextureID) -> DefaultTexturesData
{
    return gpu_rg_add_pass(in_render_graph, DefaultTexturesPass{ 
        m_name = "DEFAULT TEXTURES PASS",
        m_data = {
            m_white_texture = gpu_rg_import(&m_builder, in_white_texture),
            m_black_texture = gpu_rg_import(&m_builder, in_black_texture)
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^d3d12.IGraphicsCommandList, data : ^DefaultTexturesData) {}
    })
}

add_compose_pass :: proc(using in_render_graph : ^RenderGraph, in_bloom_texture : RenderGraphResourceID, in_input_texture : RenderGraphResourceID) -> FinalComposeRenderPassData
{
    return gpu_rg_add_pass(in_render_graph, FinalComposeRenderPass{
        m_name = "COMPOSE PASS",
        m_data = {
            m_output_texture = gpu_rg_create(&m_builder, GPUTextureDesc{
                format = .R16G16B16A16_FLOAT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                debug_name = "RT_ComposeOutput"
            }),
            m_input_texture = gpu_rg_read(&m_builder, in_input_texture),
            m_bloom_texture = gpu_rg_read(&m_builder, in_bloom_texture)
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^d3d12.IGraphicsCommandList, data : ^FinalComposeRenderPassData) {
            // in_cmd_list->DrawInstanced(3, 1, 0, 0)
        }
    })
}