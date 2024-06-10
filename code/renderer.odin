package main

import "core:c"
import "vendor:sdl2"
import "vendor:directx/d3d12"
import "third_party/imgui"
import "third_party/imgui/imgui_impl_dx12"
import "third_party/imgui/imgui_impl_sdl2"

init_imgui :: proc(in_device : ^GPUDevice, in_window : ^sdl2.Window) -> bool
{
    imgui.CHECKVERSION()
    imgui.CreateContext()
    imgui.StyleColorsDark()
    imgui_impl_sdl2.InitForD3D(in_window)

    pixels : ^c.uchar
    width, height : c.int
    imgui.FontAtlas_GetTexDataAsAlpha8(imgui.GetIO().Fonts, &pixels, &width, &height);

    font_texture_id := gpu_create_texture(in_device, GPUTextureDesc { 
        format = .R8_UNORM,
        width  = u64(width),
        height = u32(height),
        mips  = 1,
        depth_or_layers = 1,
        usage  = .SHADER_READ_ONLY,
        debug_name = "ImguiFontTexture"
    })

    font_texture := gpu_get_texture(in_device, font_texture_id)
    font_srv_cpu_handle := gpu_get_cpu_descriptor_handle(&in_device.m_descriptor_pool[.CBV_SRV_UAV], font_texture.m_descriptor)
    font_srv_gpu_handle := gpu_get_gpu_descriptor_handle(&in_device.m_descriptor_pool[.CBV_SRV_UAV], font_texture.m_descriptor)
    
    resource_heap := in_device.m_descriptor_pool[d3d12.DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV].m_heap
    err := imgui_impl_dx12.Init(in_device.m_device, FRAME_COUNT, .B8G8R8A8_UNORM, resource_heap, font_srv_cpu_handle, font_srv_gpu_handle) 
    err |= imgui_impl_dx12.CreateDeviceObjects()

    return err
}

render_imgui :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_backbuffer : ^d3d12.IResource)
{
    gpu_bind_device_defaults(in_device, in_cmd_list)

    bb_before_barrier := cd3dx12_barrier_transition(in_backbuffer, d3d12.RESOURCE_STATE_COMMON, {.RENDER_TARGET})
    in_cmd_list.m_cmds->ResourceBarrier(1, &bb_before_barrier)

    bb_viewport := cd3dx12_viewport(in_backbuffer)
    bb_scissor := d3d12.RECT { i32(bb_viewport.TopLeftX), i32(bb_viewport.TopLeftY), i32(bb_viewport.Width), i32(bb_viewport.Height) }

    in_cmd_list.m_cmds->RSSetViewports(1, &bb_viewport)
    in_cmd_list.m_cmds->RSSetScissorRects(1, &bb_scissor)

    clear_color := [4]f32 {0.0, 0.0, 0.0, 0.0 }
    gpu_bind_render_targets(in_device, in_cmd_list, {{in_backbuffer, {}}}, nil)
    gpu_clear_render_target(in_device, in_cmd_list, 0, &clear_color)

    imgui_impl_dx12.RenderDrawData(imgui.GetDrawData(), in_cmd_list.m_cmds)

    bb_after_barrier := cd3dx12_barrier_transition(in_backbuffer, {.RENDER_TARGET}, d3d12.RESOURCE_STATE_COMMON)
    in_cmd_list.m_cmds->ResourceBarrier(1, &bb_after_barrier)
}