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

import "third_party/imgui"
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
    m_scene : Scene,
    m_entity : Entity,
    m_running : bool,
    m_frame_index : u32,
    m_frame_counter : u64,
    m_fence : ^d3d12.IFence,
    m_fence_event : dxgi.HANDLE,
    m_window : ^sdl.Window,
    m_swapchain : ^dxgi.ISwapChain3,
    m_renderer : Renderer,
    m_render_graph : RenderGraph,
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
            mips   = max(u16(in_info.header.dwMipMapCount), 1),
            depth_or_layers = max(u16(in_info.header.dwDepth), 1),
            usage  = .SHADER_READ_ONLY,
            debug_name = in_name
        })
    }

    black_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(BLACK4X4_DDS)), false, "black4x4")
    white_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(WHITE4X4_DDS)), false, "white4x4")
    normal_texture := create_texture_from_dds_info(&m_device, cast(^DDS_FILE_INFO)(raw_data(NORMAL4X4_DDS)), false, "normal4x4")

    append(&m_renderer.m_pending_texture_uploads, TextureUpload { m_texture = black_texture, m_data = BLACK4X4_DDS })
    append(&m_renderer.m_pending_texture_uploads, TextureUpload { m_texture = white_texture, m_data = WHITE4X4_DDS })
    append(&m_renderer.m_pending_texture_uploads, TextureUpload { m_texture = normal_texture, m_data = NORMAL4X4_DDS })

    default_textures := add_default_textures_pass(&m_render_graph, &m_device, black_texture, white_texture)
    gbuffer_pass_data := add_gbuffer_pass(&m_render_graph, &m_device)
    compose_pass_data := add_compose_pass(&m_render_graph, &m_device, default_textures.m_black_texture, default_textures.m_white_texture)
    pre_ui_pass_data := add_pre_imgui_pass(&m_render_graph, &m_device, compose_pass_data.m_output_texture)

    gpu_rg_compile(&m_render_graph, &m_device)

    err := init_imgui(&m_device, m_window)

    return err
}

app_update :: proc(using in_app : ^App, in_dt : f32)
{
    imgui_impl_sdl2.NewFrame()
    imgui_impl_dx12.NewFrame()
    imgui.NewFrame()

    imgui_draw_menubar(in_app, &m_entity)        
    imgui_draw_outliner(m_entity, &m_scene, &m_entity)

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

    renderer_flush_uploads(&m_renderer, &m_device, &bb_data.m_copy_cmd_list, &m_scene)

    copy_cmds->Close()

    {
        cmd_lists : [1]^d3d12.ICommandList = { (^d3d12.ICommandList)(copy_cmds) }
        m_device.m_graphics_queue->ExecuteCommandLists(1, raw_data(&cmd_lists))
    }

    // do rendering
    gpu_rg_execute(&m_render_graph, &m_device, &bb_data.m_direct_cmd_list, &m_scene,  m_frame_counter)

    render_imgui(&m_device, &bb_data.m_direct_cmd_list, bb_data.m_swapchain_backbuffer)

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