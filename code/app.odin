package main

import "core:c"
import "core:os"
import "core:io"
import "core:fmt"
import "core:math"
import "core:time"
import "core:thread"
import "core:strings"
import "core:sys/windows"
import "core:path/filepath"
import "core:encoding/json"

import imgui "third_party/imgui"
import "third_party/imgui/imgui_impl_sdl2"
import "third_party/imgui/imgui_impl_dx12"

import sdl "vendor:sdl2"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

@export D3D12SDKVersion : u32 = 600
@export D3D12SDKPath : cstring = ".\\"

WINDOW_WIDTH :: 1920
WINDOW_HEIGHT :: 1080
BACKBUFFER_COUNT :: 2
SWAPCHAIN_FORMAT :: dxgi.FORMAT.B8G8R8A8_UNORM

BLACK4X4_DDS := #load("../assets/system/black4x4.dds", []u8)
WHITE4X4_DDS := #load("../assets/system/white4x4.dds", []u8)
NORMAL4X4_DDS := #load("../assets/system/normal4x4.dds", []u8)

CommandList :: struct
{
    m_cmds : ^d3d12.IGraphicsCommandList4,
    m_allocator : ^d3d12.ICommandAllocator
}

BackBufferData :: struct
{
    m_fence_value : u64,
    m_copy_cmd_list : CommandList,
    m_direct_cmd_list : CommandList,
    m_swapchain_backbuffer : ^d3d12.IResource
}

TextureUpload :: struct
{
    m_mip : u32,
    m_texture : GPUTextureID,
    m_data : []u8
}

App :: struct
{
    m_device : GPUDevice,
    m_config : AppConfig,
    m_running : bool,
    m_frame_index : u32,
    m_frame_counter : u64,
    m_fence : ^d3d12.IFence,
    m_fence_event : dxgi.HANDLE,
    m_window : ^sdl.Window,
    m_swapchain : ^dxgi.ISwapChain3,
    m_render_graph : RenderGraph,
    m_texture_uploads : [dynamic]TextureUpload,
    m_backbuffer_data : [BACKBUFFER_COUNT]BackBufferData,
}

app_get_backbuffer_data :: proc(in_app : ^App) -> ^BackBufferData 
{
    return &in_app.m_backbuffer_data[in_app.m_frame_index]
}

AppConfig :: struct
{
    m_name : string,
    m_display : i8,
    m_vsync : i32,
    m_recent_files : [dynamic]string
}

app_init :: proc(using in_app : ^App) -> bool
{
    config_path :: "config.json"

    if file_data, ok := os.read_entire_file(config_path); ok {
        defer delete(file_data)
        json.unmarshal(file_data, &m_config)
    }
    
    sdl.Init(sdl.INIT_VIDEO)

    window_name := strings.clone_to_cstring(m_config.m_name)
    defer delete(window_name)

    m_window = sdl.CreateWindow(
        window_name,
        sdl.WINDOWPOS_CENTERED_DISPLAY(i32(m_config.m_display)),
        sdl.WINDOWPOS_CENTERED_DISPLAY(i32(m_config.m_display)), 
        WINDOW_WIDTH, WINDOW_HEIGHT, 
        {/*sdl.WindowFlag.RESIZABLE*/}
    )

    compile_system_shaders()

    gpu_device_init(&m_device)

    panic_if_failed(m_device.m_device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&m_fence)))
    m_fence_event = windows.CreateEventW(nil, windows.FALSE, windows.FALSE, nil)

    swapchain_desc := dxgi.SWAP_CHAIN_DESC1 {
        Width       = WINDOW_WIDTH,
        Height      = WINDOW_HEIGHT,
        Format      = SWAPCHAIN_FORMAT,
        SampleDesc  = dxgi.SAMPLE_DESC { Count = 1},
        BufferUsage = { dxgi.USAGE_FLAG.RENDER_TARGET_OUTPUT },
        BufferCount = BACKBUFFER_COUNT,
        SwapEffect  = .FLIP_DISCARD,
        Flags       = { .ALLOW_TEARING }
    }

    sdl_wm_info : sdl.SysWMinfo
    sdl.GetVersion(&sdl_wm_info.version)
    sdl.GetWindowWMInfo(m_window, &sdl_wm_info)

    hwnd : dxgi.HWND = (dxgi.HWND)(sdl_wm_info.info.win.window)

    factory : ^dxgi.IFactory6
    panic_if_failed(dxgi.CreateDXGIFactory2({.DEBUG}, dxgi.IFactory6_UUID, (^rawptr)(&factory)))

    swapchain : ^dxgi.ISwapChain1
    panic_if_failed(factory->CreateSwapChainForHwnd(m_device.m_graphics_queue, hwnd, &swapchain_desc, nil, nil, &swapchain))
    panic_if_failed(swapchain->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&m_swapchain)))

    panic_if_failed(factory->MakeWindowAssociation(hwnd, {.NO_WINDOW_CHANGES}))

    for &bb_data, index in m_backbuffer_data {
        panic_if_failed(m_device.m_device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&bb_data.m_copy_cmd_list.m_allocator)))
        panic_if_failed(m_device.m_device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&bb_data.m_direct_cmd_list.m_allocator)))
        panic_if_failed(m_device.m_device->CreateCommandList1(0x00, .DIRECT, {}, d3d12.IGraphicsCommandList4_UUID, (^rawptr)(&bb_data.m_copy_cmd_list)))
        panic_if_failed(m_device.m_device->CreateCommandList1(0x00, .DIRECT, {}, d3d12.IGraphicsCommandList4_UUID, (^rawptr)(&bb_data.m_direct_cmd_list)))

        m_swapchain->GetBuffer(u32(index), d3d12.IResource_UUID, (^rawptr)(&bb_data.m_swapchain_backbuffer))
    }

    vertex_buffer_id := gpu_create_buffer(&m_device, GPUBufferDesc { size = size_of(f32) * 12})
    index_buffer_id := gpu_create_buffer(&m_device, GPUBufferDesc { size = size_of(u32) * 12})

    create_texture_from_dds_info :: proc(in_device : ^GPUDevice, in_info : ^DDS_FILE_INFO, in_srgb : bool, in_name : string) -> GPUTextureID
    {
        if in_info.magicNumber != DDS_MAGIC_NUMBER do panic("INVALID DDS SEND HELP")

        dds_format := in_info.header.ddspf.FourCC
        dxgi_format := in_srgb ? dxgi.FORMAT.BC3_UNORM_SRGB : dxgi.FORMAT.BC3_UNORM
        
        switch dds_format {
            case u32(DDS_FORMAT_ATI2) : dxgi_format = dxgi.FORMAT.BC5_UNORM
        }

        if in_info.header.ddspf.FourCC == u32(DDS_FORMAT_DX10) {
            dds_extended_info := cast(^DDS_FILE_INFO_EXTENDED)(in_info)
            dxgi_format = dxgi.FORMAT(dds_extended_info.header10.dxgiFormat)
        }

        return gpu_create_texture(in_device, GPUTextureDesc {
            format = dxgi_format,
            width  = u64(in_info.header.dwWidth),
            height = u32(in_info.header.dwHeight),
            mips   = u16(in_info.header.dwMipMapCount),
            usage  = .SHADER_READ_ONLY,
            debug_name = in_name
        })
    }

    black_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(BLACK4X4_DDS)), false, "black4x4")
    white_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(WHITE4X4_DDS)), false, "white4x4")
    normal_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(NORMAL4X4_DDS)), false, "normal4x4")

    append(&m_texture_uploads, TextureUpload { m_texture = black_texture, m_data = BLACK4X4_DDS })
    append(&m_texture_uploads, TextureUpload { m_texture = white_texture, m_data = WHITE4X4_DDS })
    append(&m_texture_uploads, TextureUpload { m_texture = normal_texture, m_data = NORMAL4X4_DDS })

    default_textures := add_default_textures_pass(&m_render_graph, &m_device, black_texture, white_texture)
    //gbuffer_pass_data := add_gbuffer_pass(&m_render_graph);
    compose_pass_data := add_compose_pass(&m_render_graph, default_textures.m_black_texture, default_textures.m_white_texture)

    imgui.CHECKVERSION()
    imgui.CreateContext()
    imgui.StyleColorsDark()
    imgui_impl_sdl2.InitForD3D(m_window)

    pixels : ^c.uchar
    width, height : c.int
    imgui.FontAtlas_GetTexDataAsAlpha8(imgui.GetIO().Fonts, &pixels, &width, &height);

    font_texture_id := gpu_create_texture(&m_device, GPUTextureDesc { 
        format = .R8_UNORM,
        width  = u64(width),
        height = u32(height),
        usage  = .SHADER_READ_ONLY,
        debug_name = "ImguiFontTexture"
    })

    font_texture := gpu_get_texture(&m_device, font_texture_id)
    font_srv_cpu_handle := gpu_get_cpu_descriptor_handle(&m_device.m_descriptor_pool[.CBV_SRV_UAV], font_texture.m_descriptor)
    font_srv_gpu_handle := gpu_get_gpu_descriptor_handle(&m_device.m_descriptor_pool[.CBV_SRV_UAV], font_texture.m_descriptor)
    
    resource_heap := m_device.m_descriptor_pool[d3d12.DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV].m_heap
    err := imgui_impl_dx12.Init(m_device.m_device, FRAME_COUNT, .B8G8R8A8_UNORM, resource_heap, font_srv_cpu_handle, font_srv_gpu_handle) 
    err |= imgui_impl_dx12.CreateDeviceObjects()

    return err;
}

app_update :: proc(using in_app : ^App, in_dt : f32)
{
    imgui_impl_sdl2.NewFrame()
    imgui_impl_dx12.NewFrame()
    imgui.NewFrame()

    imgui.Begin("Test Window")
    imgui.Text("Hellope World!")

    imgui.SliderInt("V-Sync", &m_config.m_vsync, 0, 2)

    imgui.End()

    imgui.ShowMetricsWindow()

    imgui.EndFrame()
    imgui.Render()

    bb_data := app_get_backbuffer_data(in_app)

    if m_fence->GetCompletedValue() < bb_data.m_fence_value {
        panic_if_failed(m_fence->SetEventOnCompletion(bb_data.m_fence_value, m_fence_event))
        windows.WaitForSingleObjectEx(m_fence_event, windows.INFINITE, windows.FALSE)
    }

    copy_cmds := bb_data.m_copy_cmd_list.m_cmds
    graphics_cmds := bb_data.m_direct_cmd_list.m_cmds

    panic_if_failed(bb_data.m_copy_cmd_list.m_allocator->Reset())
    panic_if_failed(bb_data.m_direct_cmd_list.m_allocator->Reset())
    panic_if_failed(copy_cmds->Reset(bb_data.m_copy_cmd_list.m_allocator, nil))
    panic_if_failed(graphics_cmds->Reset(bb_data.m_direct_cmd_list.m_allocator, nil))

    // do uploads
    for upload in m_texture_uploads {
        texture := gpu_get_texture(&m_device, upload.m_texture)
        gpu_stage_texture(&m_device, copy_cmds, texture, upload.m_mip, raw_data(upload.m_data))
    }

    clear(&m_texture_uploads)

    copy_cmds->Close()

    {
        cmd_lists : [1]^d3d12.ICommandList = { (^d3d12.ICommandList)(copy_cmds) }
        m_device.m_graphics_queue->ExecuteCommandLists(1, raw_data(&cmd_lists))
    }

    // do rendering
    for &render_pass in m_render_graph.m_render_passes {
        exec_render_pass(&m_device, graphics_cmds, &render_pass)
    }

    graphics_cmds->IASetPrimitiveTopology(.TRIANGLELIST)

    descriptor_heaps : [2]^d3d12.IDescriptorHeap = 
    {
        m_device.m_descriptor_pool[.SAMPLER].m_heap,
        m_device.m_descriptor_pool[.CBV_SRV_UAV].m_heap
    }

    graphics_cmds->SetDescriptorHeaps(len(descriptor_heaps), raw_data(&descriptor_heaps))

    graphics_cmds->SetGraphicsRootSignature(m_device.m_root_signature)

    bb_before_barrier := cd3dx12_barrier_transition(bb_data.m_swapchain_backbuffer, d3d12.RESOURCE_STATE_COMMON, {.RENDER_TARGET})
    graphics_cmds->ResourceBarrier(1, &bb_before_barrier)

    bb_viewport := cd3dx12_viewport(bb_data.m_swapchain_backbuffer)
    bb_scissor := d3d12.RECT { i32(bb_viewport.TopLeftX), i32(bb_viewport.TopLeftY), i32(bb_viewport.Width), i32(bb_viewport.Height) }

    graphics_cmds->RSSetViewports(1, &bb_viewport)
    graphics_cmds->RSSetScissorRects(1, &bb_scissor)

    clear_color := [4]f32 {0.0, 0.0, 0.0, 0.0 }
    gpu_bind_render_targets(&m_device, graphics_cmds, {{bb_data.m_swapchain_backbuffer, {}}}, nil)
    gpu_clear_render_target(&m_device, graphics_cmds, 0, &clear_color)

    imgui_impl_dx12.RenderDrawData(imgui.GetDrawData(), graphics_cmds)

    bb_after_barrier := cd3dx12_barrier_transition(bb_data.m_swapchain_backbuffer, {.RENDER_TARGET}, d3d12.RESOURCE_STATE_COMMON)
    graphics_cmds->ResourceBarrier(1, &bb_after_barrier)

    graphics_cmds->Close()

    {
        cmd_lists : [1]^d3d12.ICommandList = { (^d3d12.ICommandList)(graphics_cmds) }
        m_device.m_graphics_queue->ExecuteCommandLists(1, raw_data(&cmd_lists))
    }

    present_flags : dxgi.PRESENT
    if m_config.m_vsync == 0 do present_flags = { dxgi.PRESENT_FLAG.ALLOW_TEARING }

    m_swapchain->Present(u32(m_config.m_vsync), present_flags)

    bb_data.m_fence_value += 1
    m_frame_index = m_swapchain->GetCurrentBackBufferIndex();

    panic_if_failed(m_device.m_graphics_queue->Signal(m_fence, app_get_backbuffer_data(in_app).m_fence_value))
}


app_run :: proc(using in_app : ^App)
{
    delta_time := f32(0.0)

    for m_running
    {
        for ev: sdl.Event; sdl.PollEvent(&ev); 
        {
            imgui_impl_sdl2.ProcessEvent(&ev)

            if ev.type == .WINDOWEVENT && ev.window.event == .CLOSE 
            {
                m_running = false
            }
        }

        app_update(in_app, delta_time)
    
        m_frame_counter += 1
    }
}

app_deinit :: proc(using in_app : ^App)
{
    sdl.DestroyWindow(m_window)
}