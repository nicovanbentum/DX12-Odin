package main

import "core:fmt"
import "core:sys/windows"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

AnyRenderPassDesc :: union
{
    GBufferPassDesc,
    DefaultPassDesc,
    ComposePassDesc,
    PreImGuiRenderPassDesc
}

exec_render_pass :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_scene : ^Scene, in_resources : ^RenderGraphResources, in_pass : ^AnyRenderPassDesc)
{
    switch &pass in in_pass 
    {
        case DefaultPassDesc : pass.m_exec(in_device, in_cmd_list, in_scene, in_resources, &pass.m_data)
        case GBufferPassDesc : pass.m_exec(in_device, in_cmd_list, in_scene, in_resources, &pass.m_data)
        case ComposePassDesc : pass.m_exec(in_device, in_cmd_list, in_scene, in_resources, &pass.m_data)
        case PreImGuiRenderPassDesc : pass.m_exec(in_device, in_cmd_list, in_scene, in_resources, &pass.m_data)
    }
}

GBufferRenderPassData :: struct
{
    m_pipeline : ^d3d12.IPipelineState,
    m_render_texture : RenderGraphResourceID,
    m_motion_texture : RenderGraphResourceID,
    m_selection_texture : RenderGraphResourceID,
    m_depth_stencil_texture : RenderGraphResourceID
}

GBufferPassDesc :: RenderPassDesc(GBufferRenderPassData)

add_gbuffer_pass :: proc(using rg : ^RenderGraph, device : ^GPUDevice) -> GBufferRenderPassData
{
    render_pass := RenderPass { m_kind = .GRAPHICS }

    render_pass_desc := GBufferPassDesc { 
        m_name = "GBUFFER PASS",
        m_data = {
            m_render_texture = gpu_rg_create_texture(&m_builder, &render_pass, GPUTextureDesc {
                format = .R32G32B32A32_FLOAT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                mips = 1,
                depth_or_layers = 1,
                debug_name = "RT_GBufferColor"
            }),
            m_motion_texture = gpu_rg_create_texture(&m_builder, &render_pass, GPUTextureDesc {
                format = .R32G32_FLOAT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                mips = 1,
                depth_or_layers = 1,
                debug_name = "RT_GBufferVelocity"
            }),
            m_selection_texture = gpu_rg_create_texture(&m_builder, &render_pass, GPUTextureDesc {
                format = .R32_UINT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                mips = 1,
                depth_or_layers = 1,
                debug_name = "RT_GBufferSelection"
            }),
            m_depth_stencil_texture = gpu_rg_create_texture(&m_builder, &render_pass, GPUTextureDesc {
                format = .D32_FLOAT_S8X24_UINT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .DEPTH_STENCIL_TARGET,
                mips = 1,
                depth_or_layers = 1,
                debug_name = "RT_GBufferDepth"
            })
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_scene : ^Scene, in_resources : ^RenderGraphResources, data : ^GBufferRenderPassData) 
        {
            clear_color : [4]f32 = {0.0, 0.0, 0.0, 0.0}
            gpu_clear_render_target(in_device, in_cmd_list, 0, &clear_color) // clear render texture
            gpu_clear_render_target(in_device, in_cmd_list, 1, &clear_color) // clear velocity texture
            gpu_clear_render_target(in_device, in_cmd_list, 2, &clear_color) // clear selection texture

            clear_depth_value : f32 = 1.0
            clear_stencil_value : u8 = 0
            gpu_clear_depth_stencil_target(in_device, in_cmd_list, &clear_depth_value, &clear_stencil_value)

            in_cmd_list.m_cmds->SetPipelineState(data.m_pipeline)

            mesh_array := scene_get_component_array(in_scene, Mesh)

            for &mesh, index in mesh_array.components 
            {
                entity := mesh_array.entities[index]
                transform := scene_get_component(in_scene, entity, Transform)
                if transform == nil do continue

                index_buffer := gpu_get_buffer(in_device, GPUBufferID(mesh.index_buffer))
                index_buffer_view := d3d12.INDEX_BUFFER_VIEW {
                    Format = dxgi.FORMAT.R32_UINT,
                    SizeInBytes = u32(len(mesh.indices) * size_of(u32)),
                    BufferLocation = index_buffer.m_resource->GetGPUVirtualAddress()
                }

                GBufferRootConstants :: struct {
                    instances_buffer : u32,
                    materials_buffer : u32,
                    instance_index : u32,
                    entity : u32,
                }

                root_constants := GBufferRootConstants {
                    materials_buffer = gpu_get_buffer(in_device, in_scene.materials_buffer).m_descriptor.m_index,
                    instances_buffer = gpu_get_buffer(in_device, in_scene.instances_buffer).m_descriptor.m_index,
                    instance_index = mesh_array.sparse[entity.index],
                    entity = u32(entity)
                }

                in_cmd_list.m_cmds->SetGraphicsRoot32BitConstants(0, size_of(GBufferRootConstants) / size_of(u32), &root_constants, 0)
                in_cmd_list.m_cmds->IASetIndexBuffer(&index_buffer_view)
                in_cmd_list.m_cmds->DrawIndexedInstanced(u32(len(mesh.indices)), 1, 0, 0, 0)
            }
        }
    }

    gpu_rg_render_target(&rg.m_builder, &render_pass, render_pass_desc.m_data.m_render_texture)
    gpu_rg_render_target(&rg.m_builder, &render_pass, render_pass_desc.m_data.m_motion_texture)
    gpu_rg_render_target(&rg.m_builder, &render_pass, render_pass_desc.m_data.m_selection_texture)
    gpu_rg_depth_stencil_target(&rg.m_builder, &render_pass, render_pass_desc.m_data.m_depth_stencil_texture)

    shaders := &g_compiled_shaders[SystemShaders.GBUFFER_SHADER]
    pso_state := gpu_create_graphics_pipeline_state_desc(device, render_pass, shaders.m_vertex_shader_blob[:], shaders.m_pixel_shader_blob[:])

    panic_if_failed(device.m_device->CreateGraphicsPipelineState(&pso_state, d3d12.IPipelineState_UUID, (^rawptr)(&render_pass_desc.m_data.m_pipeline)))
    render_pass_desc.m_data.m_pipeline->SetName(raw_data(windows.utf8_to_utf16(render_pass_desc.m_name)))

    return gpu_rg_add_pass(rg, render_pass, render_pass_desc)
}

DefaultTexturesData :: struct
{
    m_white_texture : RenderGraphResourceID,
    m_black_texture : RenderGraphResourceID
}

DefaultPassDesc :: RenderPassDesc(DefaultTexturesData)

add_default_textures_pass :: proc(using in_render_graph : ^RenderGraph, in_device : ^GPUDevice, in_black_texture : GPUTextureID, in_white_texture : GPUTextureID) -> DefaultTexturesData
{
    render_pass := RenderPass { m_kind = .GRAPHICS }

    render_pass_desc := DefaultPassDesc { 
        m_name = "DEFAULT TEXTURES PASS",
        m_data = {
            m_white_texture = gpu_rg_import(in_device, &m_builder, in_white_texture),
            m_black_texture = gpu_rg_import(in_device, &m_builder, in_black_texture)
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_scene : ^Scene, in_resources : ^RenderGraphResources, data : ^DefaultTexturesData) {}
    }

    return gpu_rg_add_pass(in_render_graph, render_pass, render_pass_desc)
}

ComposeSettings :: struct
{
    mExposure : f32,
    mVignetteScale : f32,
    mVignetteBias : f32,
    mVignetteInner : f32,
    mVignetteOuter : f32,
    mBloomBlendFactor : f32,
    mChromaticAberrationStrength : f32
}

ComposeRootConstants :: struct
{
    mBloomTexture : u32,
    mInputTexture : u32,
    mPad0 : u32,
    mPad1 : u32,
    mSettings : ComposeSettings,
};

FinalComposeRenderPassData :: struct
{
    m_settings : ComposeSettings,
    m_pipeline : ^d3d12.IPipelineState,
    m_output_texture : RenderGraphResourceID,
    m_input_texture : RenderGraphResourceViewID,
    m_bloom_texture : RenderGraphResourceViewID
}

ComposePassDesc :: RenderPassDesc(FinalComposeRenderPassData)

add_compose_pass :: proc(using rg : ^RenderGraph, device : ^GPUDevice, bloom_texture : RenderGraphResourceID, input_texture : RenderGraphResourceID) -> FinalComposeRenderPassData
{   
    render_pass := RenderPass {  m_kind = .GRAPHICS }

    render_pass_desc := ComposePassDesc {
        m_name = "COMPOSE PASS",
        m_data = FinalComposeRenderPassData {
            m_output_texture = gpu_rg_create(&m_builder, &render_pass, GPUTextureDesc{
                format = .R16G16B16A16_FLOAT,
                width  = WINDOW_WIDTH,
                height = WINDOW_HEIGHT,
                usage  = .RENDER_TARGET,
                mips = 1,
                depth_or_layers = 1,
                debug_name = "RT_ComposeOutput"
            }),
            m_input_texture = gpu_rg_read(&m_builder, &render_pass, input_texture),
            m_bloom_texture = gpu_rg_read(&m_builder, &render_pass, bloom_texture)
        },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_scene : ^Scene, in_resources : ^RenderGraphResources, data : ^FinalComposeRenderPassData)
        {
            input_texture := gpu_get_texture(in_device, gpu_rg_get_texture_view(in_resources, data.m_input_texture))
            bloom_texture := gpu_get_texture(in_device, gpu_rg_get_texture_view(in_resources, data.m_bloom_texture))
            output_texture := gpu_get_texture(in_device, gpu_rg_get_texture(in_resources, data.m_output_texture))

            in_cmd_list.m_cmds->SetPipelineState(data.m_pipeline)

            vp := cd3dx12_viewport(output_texture.m_resource)
            rect := d3d12.RECT { i32(vp.TopLeftX), i32(vp.TopLeftY), i32(vp.Width), i32(vp.Height) }

            in_cmd_list.m_cmds->RSSetViewports(1, &vp)
            in_cmd_list.m_cmds->RSSetScissorRects(1, &rect)

            root_constants := ComposeRootConstants {
                mBloomTexture = bloom_texture.m_descriptor.m_index,
                mInputTexture = input_texture.m_descriptor.m_index,
                mSettings = data.m_settings
            }

            in_cmd_list.m_cmds->SetGraphicsRoot32BitConstants(0, size_of(ComposeRootConstants) / size_of(u32), &root_constants, 0)
            in_cmd_list.m_cmds->DrawInstanced(3, 1, 0, 0)
        }
    }

    gpu_rg_render_target(&m_builder, &render_pass, render_pass_desc.m_data.m_output_texture)

    shader := &g_compiled_shaders[SystemShaders.FINAL_COMPOSE_SHADER]
    pso_state := gpu_create_graphics_pipeline_state_desc(device, render_pass, shader.m_vertex_shader_blob[:], shader.m_pixel_shader_blob[:])
    pso_state.DepthStencilState.DepthEnable = false
    pso_state.RasterizerState.CullMode = .NONE

    panic_if_failed(device.m_device->CreateGraphicsPipelineState(&pso_state, d3d12.IPipelineState_UUID, (^rawptr)(&render_pass_desc.m_data.m_pipeline)))
    render_pass_desc.m_data.m_pipeline->SetName(raw_data(windows.utf8_to_utf16(render_pass_desc.m_name)))

    return gpu_rg_add_pass(rg, render_pass, render_pass_desc)
}

PreImGuiRenderData :: struct { m_srv : RenderGraphResourceViewID }
PreImGuiRenderPassDesc :: RenderPassDesc(PreImGuiRenderData)

add_pre_imgui_pass :: proc(using rg : ^RenderGraph, device : ^GPUDevice, final_texture : RenderGraphResourceID) -> PreImGuiRenderData
{
    render_pass := RenderPass { m_kind = .GRAPHICS }

    render_pass_desc := PreImGuiRenderPassDesc {
        m_name = "PRE-UI PASS",
        m_data = { m_srv = gpu_rg_read(&rg.m_builder, &render_pass, final_texture) },
        m_exec = proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_scene : ^Scene, in_resources : ^RenderGraphResources, data : ^PreImGuiRenderData) {}
    }

    return gpu_rg_add_pass(rg, render_pass, render_pass_desc)
}