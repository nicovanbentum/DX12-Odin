package main

import "core:c"
import "core:math/linalg/hlsl"
import "vendor:sdl2"
import "vendor:directx/d3d12"
import "third_party/imgui"
import "third_party/imgui/imgui_impl_dx12"
import "third_party/imgui/imgui_impl_sdl2"

Renderer :: struct {
    m_pending_mesh_uploads : [dynamic]Entity,
    m_pending_texture_uploads : [dynamic]TextureUpload
}

create_or_grow_buffer :: proc(device : ^GPUDevice, buffer : GPUBufferID, desc : GPUBufferDesc) -> GPUBufferID 
{
    current_buffer := buffer

    if current_buffer.m_valid == 1 {
        if desc.size > gpu_get_buffer(device, current_buffer).m_desc.size {
            old_buffer := current_buffer
            current_buffer = gpu_create_buffer(device, desc)
            gpu_release_buffer(device, old_buffer)
        }
    }
    else do current_buffer = gpu_create_buffer(device, desc)

    return current_buffer
}

renderer_upload_materials :: proc(renderer : ^Renderer, device : ^GPUDevice, cmds : ^CommandList, scene : ^Scene) {
    materials : []Material = scene_get_component_array(scene, Material).components[:]
    if len(materials) == 0 do materials = { DefaultMaterial }

    RT_Material :: struct {
        mMetallic : f32,
        mRoughness : f32,
        mAlbedoTexture : u32,
        mNormalsTexture : u32,
        mEmissiveTexture : u32,
        mMetallicTexture : u32,
        mRoughnessTexture : u32,
        mPad0 : u32,
        mAlbedo : [4]f32,
        mEmissive : [4]f32
    }

    rt_materials : [dynamic]RT_Material
    reserve(&rt_materials, len(materials))

    for &material in materials {
        append(&rt_materials, RT_Material {
            mAlbedo = material.albedo,
            mEmissive = material.emissive,
            mMetallic = material.metallic,
            mRoughness = material.roughness,
            mAlbedoTexture = gpu_get_texture(device, GPUTextureID(material.textures[.ALBEDO].gpu_handle)).m_descriptor.m_index,
            mNormalsTexture = gpu_get_texture(device, GPUTextureID(material.textures[.NORMALS].gpu_handle)).m_descriptor.m_index,
            mEmissiveTexture = gpu_get_texture(device, GPUTextureID(material.textures[.EMISSIVE].gpu_handle)).m_descriptor.m_index,
            mMetallicTexture = gpu_get_texture(device, GPUTextureID(material.textures[.METALLIC].gpu_handle)).m_descriptor.m_index,
            mRoughnessTexture = gpu_get_texture(device, GPUTextureID(material.textures[.ROUGHNESS].gpu_handle)).m_descriptor.m_index,
        })
    }

    scene.materials_buffer = create_or_grow_buffer(device, scene.materials_buffer, GPUBufferDesc {
        size   = u64(size_of(RT_Material) * len(rt_materials)),
        stride = size_of(RT_Material),
        usage  = .SHADER_READ_ONLY,
        debug_name = "MaterialsBuffer"
    })

    materials_buffer := gpu_get_buffer(device, scene.materials_buffer)
    gpu_stage_buffer(device, cmds.m_cmds, materials_buffer, 0, raw_data(rt_materials), u32(materials_buffer.m_desc.size))
}

renderer_upload_instances :: proc(renderer : ^Renderer, device : ^GPUDevice, cmds : ^CommandList, scene : ^Scene) {
    mesh_array : ^ComponentArray(Mesh) = scene_get_component_array(scene, Mesh)
    material_array : ^ComponentArray(Material) = scene_get_component_array(scene, Material)
    transform_array : ^ComponentArray(Transform) = scene_get_component_array(scene, Transform)

    
    if len(mesh_array.components) == 0 do return
    
    RT_Instance :: struct {
        index_buffer : u32,
        vertex_buffer : u32,
        material_index : u32,
        local_to_world_transform : hlsl.float4x4,
        world_to_local_transform : hlsl.float4x4
    }
    
    rt_instances : [dynamic]RT_Instance
    reserve(&rt_instances, len(mesh_array.components))
    
    for &mesh, index in mesh_array.components {
        entity : Entity = mesh_array.entities[index]
        transform : ^Transform = component_array_get(transform_array, entity)
        if transform == nil do continue

        append(&rt_instances, RT_Instance{
            index_buffer = gpu_get_buffer(device, GPUBufferID(mesh.index_buffer)).m_descriptor.m_index,
            vertex_buffer = gpu_get_buffer(device, GPUBufferID(mesh.vertex_buffer)).m_descriptor.m_index,
            material_index = mesh.material if component_array_contains(material_array, Entity(mesh.material)) else 0,
            local_to_world_transform = transform.world_transform,
            world_to_local_transform = hlsl.inverse(transform.world_transform)
        })
    }

    scene.instances_buffer = create_or_grow_buffer(device, scene.instances_buffer, GPUBufferDesc {
        size   = u64(size_of(RT_Instance) * len(rt_instances)),
        stride = size_of(RT_Instance),
        usage  = .SHADER_READ_ONLY,
        debug_name = "InstancesBuffer"
    })

    instances_buffer := gpu_get_buffer(device, scene.instances_buffer)
    gpu_stage_buffer(device, cmds.m_cmds, instances_buffer, 0, raw_data(rt_instances), u32(instances_buffer.m_desc.size))
}

renderer_flush_uploads :: proc(renderer : ^Renderer, device : ^GPUDevice, cmds : ^CommandList, scene : ^Scene) {
    for texture_upload in renderer.m_pending_texture_uploads {
        texture := gpu_get_texture(device, texture_upload.m_texture)
        gpu_stage_texture(device, cmds.m_cmds, texture, texture_upload.m_mip, raw_data(texture_upload.m_data))
    }

    for entity in renderer.m_pending_mesh_uploads {
        mesh := scene_get_component(scene, entity, Mesh)
        if mesh == nil do continue

        indices_size := len(mesh.indices) * size_of(u32)
        vertices_size := len(mesh.vertices) * size_of(f32)
    
        if indices_size == 0 || vertices_size == 0 do continue

        gpu_index_buffer := gpu_get_buffer(device, GPUBufferID(mesh.index_buffer))
        gpu_vertex_buffer := gpu_get_buffer(device, GPUBufferID(mesh.vertex_buffer))

        gpu_stage_buffer(device, cmds.m_cmds, gpu_index_buffer, 0, raw_data(mesh.indices), u32(indices_size))
        gpu_stage_buffer(device, cmds.m_cmds, gpu_vertex_buffer, 0, raw_data(mesh.vertices), u32(vertices_size))

        barriers := [2]d3d12.RESOURCE_BARRIER {
            cd3dx12_barrier_transition(gpu_index_buffer.m_resource, {.COPY_DEST}, d3d12.RESOURCE_STATE_GENERIC_READ),
            cd3dx12_barrier_transition(gpu_vertex_buffer.m_resource, {.COPY_DEST}, d3d12.RESOURCE_STATE_GENERIC_READ),
        }

        cmds.m_cmds->ResourceBarrier(len(barriers), raw_data(barriers[:]))
    }

    clear(&renderer.m_pending_mesh_uploads)
    clear(&renderer.m_pending_texture_uploads)
}

gpu_create_mesh_buffers :: proc(device : ^GPUDevice, mesh : ^Mesh, entity : Entity) {
    indices_size := len(mesh.indices) * size_of(u32)
    vertices_size := len(mesh.vertices) * size_of(f32)

    if indices_size == 0 || vertices_size == 0 do return

    index_buffer := gpu_create_buffer(device, GPUBufferDesc {
        size   = u64(indices_size),
        stride = size_of(u32) * 3,
        usage  = .INDEX_BUFFER,
        debug_name = "IndexBuffer"
    })

    vertex_buffer := gpu_create_buffer(device, GPUBufferDesc {
        size   = u64(vertices_size), 
        stride = size_of(Vertex),
        usage  = .VERTEX_BUFFER,
        debug_name = "VertexBuffer"
    })

    mesh.index_buffer = u32(index_buffer)
    mesh.vertex_buffer = u32(vertex_buffer)
}

init_imgui :: proc(in_device : ^GPUDevice, in_window : ^sdl2.Window) -> bool {
    imgui.CHECKVERSION()
    imgui.CreateContext()
    imgui.StyleColorsDark()
    imgui_impl_sdl2.InitForD3D(in_window)

    io := imgui.GetIO()
    font_data := #load("../assets/system/Inter-Medium.ttf", []u8)
    font := imgui.FontAtlas_AddFontFromMemoryTTF(io.Fonts, raw_data(font_data), i32(len(font_data)), 15.0)

    all_fonts := io.Fonts.Fonts
    all_fonts_ptr : [^]^imgui.Font = all_fonts.Data

    if all_fonts.Size > 0 {
        io.FontDefault = all_fonts_ptr[all_fonts.Size - 1]
    }

    imgui.FontAtlas_Build(io.Fonts)
    io.Fonts.TexID = nil

    style := imgui.GetStyle()

    style.Colors[imgui.Col.Text] = imgui.Vec4{1.00, 1.00, 1.00, 1.00}
    style.Colors[imgui.Col.TextDisabled] = imgui.Vec4{0.50, 0.50, 0.50, 1.00}
    style.Colors[imgui.Col.WindowBg] = imgui.Vec4{0.14, 0.14, 0.14, 1.00}
    style.Colors[imgui.Col.ChildBg] = imgui.Vec4{1.00, 1.00, 1.00, 0.00}
    style.Colors[imgui.Col.PopupBg] = imgui.Vec4{0.10, 0.10, 0.10, 0.94}
    style.Colors[imgui.Col.Border] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.BorderShadow] = imgui.Vec4{0.00, 0.00, 0.00, 0.00}
    style.Colors[imgui.Col.FrameBg] = imgui.Vec4{0.06, 0.06, 0.06, 0.84}
    style.Colors[imgui.Col.FrameBgHovered] = imgui.Vec4{0.19, 0.19, 0.19, 0.84}
    style.Colors[imgui.Col.FrameBgActive] = imgui.Vec4{0.07, 0.07, 0.07, 0.67}
    style.Colors[imgui.Col.TitleBg] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.TitleBgActive] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.TitleBgCollapsed] = imgui.Vec4{0.00, 0.00, 0.00, 0.51}
    style.Colors[imgui.Col.MenuBarBg] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.ScrollbarBg] = imgui.Vec4{0.02, 0.02, 0.02, 0.53}
    style.Colors[imgui.Col.ScrollbarGrab] = imgui.Vec4{0.31, 0.31, 0.31, 1.00}
    style.Colors[imgui.Col.ScrollbarGrabHovered] = imgui.Vec4{0.41, 0.41, 0.41, 1.00}
    style.Colors[imgui.Col.ScrollbarGrabActive] = imgui.Vec4{0.51, 0.51, 0.51, 1.00}
    style.Colors[imgui.Col.CheckMark] = imgui.Vec4{0.00, 0.88, 0.00, 1.00}
    style.Colors[imgui.Col.SliderGrab] = imgui.Vec4{0.51, 0.51, 0.51, 1.00}
    style.Colors[imgui.Col.SliderGrabActive] = imgui.Vec4{0.86, 0.86, 0.86, 1.00}
    style.Colors[imgui.Col.Button] = imgui.Vec4{0.22, 0.22, 0.22, 1.00}
    style.Colors[imgui.Col.ButtonHovered] = imgui.Vec4{0.00, 0.38, 0.77, 1.00}
    style.Colors[imgui.Col.ButtonActive] = imgui.Vec4{0.42, 0.42, 0.42, 1.00}
    style.Colors[imgui.Col.Header] = imgui.Vec4{0.18, 0.18, 0.18, 1.00}
    style.Colors[imgui.Col.HeaderHovered] = imgui.Vec4{0.00, 0.38, 0.77, 1.00}
    style.Colors[imgui.Col.HeaderActive] = imgui.Vec4{0.00, 0.00, 0.00, 1.00}
    style.Colors[imgui.Col.Separator] = imgui.Vec4{0.06, 0.06, 0.06, 0.94}
    style.Colors[imgui.Col.SeparatorHovered] = imgui.Vec4{0.72, 0.72, 0.72, 0.38}
    style.Colors[imgui.Col.SeparatorActive] = imgui.Vec4{0.51, 0.51, 0.51, 1.00}
    style.Colors[imgui.Col.ResizeGrip] = imgui.Vec4{0.91, 0.91, 0.91, 0.25}
    style.Colors[imgui.Col.ResizeGripHovered] = imgui.Vec4{0.81, 0.81, 0.81, 0.67}
    style.Colors[imgui.Col.ResizeGripActive] = imgui.Vec4{0.46, 0.46, 0.46, 0.95}
    style.Colors[imgui.Col.Tab] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.TabHovered] = imgui.Vec4{0.00, 0.38, 0.77, 1.00}
    style.Colors[imgui.Col.TabActive] = imgui.Vec4{0.14, 0.14, 0.14, 1.00}
    style.Colors[imgui.Col.TabUnfocused] = imgui.Vec4{0.08, 0.08, 0.08, 1.00}
    style.Colors[imgui.Col.TabUnfocusedActive] = imgui.Vec4{0.14, 0.14, 0.14, 1.00}
    style.Colors[imgui.Col.DockingPreview] = imgui.Vec4{0.26, 0.59, 0.98, 0.70}
    style.Colors[imgui.Col.DockingEmptyBg] = imgui.Vec4{0.20, 0.20, 0.20, 1.00}
    style.Colors[imgui.Col.PlotLines] = imgui.Vec4{0.61, 0.61, 0.61, 1.00}
    style.Colors[imgui.Col.PlotLinesHovered] = imgui.Vec4{1.00, 0.43, 0.35, 1.00}
    style.Colors[imgui.Col.PlotHistogram] = imgui.Vec4{0.73, 0.60, 0.15, 1.00}
    style.Colors[imgui.Col.PlotHistogramHovered] = imgui.Vec4{1.00, 0.60, 0.00, 1.00}
    style.Colors[imgui.Col.TableHeaderBg] = imgui.Vec4{0.87, 0.87, 0.87, 0.35}
    style.Colors[imgui.Col.TableBorderStrong] = imgui.Vec4{1.00, 1.00, 1.00, 0.90}
    style.Colors[imgui.Col.TableBorderLight] = imgui.Vec4{0.60, 0.60, 0.60, 1.00}
    style.Colors[imgui.Col.TableRowBg] = imgui.Vec4{1.00, 1.00, 1.00, 0.70}
    style.Colors[imgui.Col.TableRowBgAlt] = imgui.Vec4{0.80, 0.80, 0.80, 0.20}
    style.Colors[imgui.Col.TextSelectedBg] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}
    style.Colors[imgui.Col.DragDropTarget] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}
    style.Colors[imgui.Col.NavHighlight] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}
    style.Colors[imgui.Col.NavWindowingHighlight] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}
    style.Colors[imgui.Col.NavWindowingDimBg] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}
    style.Colors[imgui.Col.ModalWindowDimBg] = imgui.Vec4{0.80, 0.80, 0.80, 0.35}

    style.TabRounding = 2.0
    style.GrabRounding = 0.0
    style.PopupRounding = 0.0
    style.ChildRounding = 0.0
    style.FrameRounding = 4.0
    style.WindowRounding = 0.0
    style.ScrollbarRounding = 0.0
    style.FrameBorderSize = 1.0
    style.ChildBorderSize = 0.0
    style.WindowBorderSize = 0.0

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

render_imgui :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_backbuffer : ^d3d12.IResource) {
    gpu_bind_device_defaults(in_device, in_cmd_list)

    bb_before_barrier := cd3dx12_barrier_transition(in_backbuffer, d3d12.RESOURCE_STATE_COMMON, {.RENDER_TARGET})
    in_cmd_list.m_cmds->ResourceBarrier(1, &bb_before_barrier)

    bb_viewport := cd3dx12_viewport(in_backbuffer)
    bb_scissor := d3d12.RECT { i32(bb_viewport.TopLeftX), i32(bb_viewport.TopLeftY), i32(bb_viewport.Width), i32(bb_viewport.Height) }

    in_cmd_list.m_cmds->RSSetViewports(1, &bb_viewport)
    in_cmd_list.m_cmds->RSSetScissorRects(1, &bb_scissor)

    gpu_bind_render_targets(in_device, in_cmd_list, {{in_backbuffer, {}}}, nil)

    clear_color := [4]f32 {0.0, 0.0, 0.0, 0.0 }
    gpu_clear_render_target(in_device, in_cmd_list, 0, &clear_color)

    imgui_impl_dx12.RenderDrawData(imgui.GetDrawData(), in_cmd_list.m_cmds)

    bb_after_barrier := cd3dx12_barrier_transition(in_backbuffer, {.RENDER_TARGET}, d3d12.RESOURCE_STATE_COMMON)
    in_cmd_list.m_cmds->ResourceBarrier(1, &bb_after_barrier)
}