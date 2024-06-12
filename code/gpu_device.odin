package main

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

FRAME_COUNT :: 2
CBUFFER_ALIGNMENT :: 256
BABUFFER_ALIGNMENT :: 4

RTV_HEAP_SIZE :: 0xFF
DSV_HEAP_SIZE :: 0xFF
CLEAR_HEAP_SIZE :: 0xFF
SAMPLER_HEAP_SIZE :: 2043
RESOURCE_HEAP_SIZE :: 1000000 - CLEAR_HEAP_SIZE
ROOT_SIGNATURE_SIZE :: 64 * size_of(windows.DWORD)
ROOT_CONSTANTS_SIZE :: ROOT_SIGNATURE_SIZE - 3 * 2 * size_of(windows.DWORD)

BIND_SLOT :: enum 
{
    CBV0, SRV0, SRV1
}

RenderTargetBinder :: struct
{
    m_rtv_incr : u32,
    m_rtv_heap : ^d3d12.IDescriptorHeap,
    m_dsv_heap : ^d3d12.IDescriptorHeap,
    m_rtv_handle : d3d12.CPU_DESCRIPTOR_HANDLE,
    m_dsv_handle : d3d12.CPU_DESCRIPTOR_HANDLE
}

RenderTargetBinding :: struct
{
    m_resource : ^d3d12.IResource,
    m_description : d3d12.RENDER_TARGET_VIEW_DESC,
}

DepthStencilBinding :: struct
{
    m_resource : ^d3d12.IResource,
    m_description : d3d12.DEPTH_STENCIL_VIEW_DESC
}

StagingBuffer :: struct
{
    size : u32,
    capacity : u32,
    frame_id : u32,
    retired : bool,
    buffer_id : GPUBufferID,
    mapped_ptr : rawptr
}

GPUDevice :: struct
{
    m_device : ^d3d12.IDevice5,
    m_adapter : ^dxgi.IAdapter1,
    m_copy_queue : ^d3d12.ICommandQueue,
    m_compute_queue : ^d3d12.ICommandQueue,
    m_graphics_queue : ^d3d12.ICommandQueue,
    m_root_signature : ^d3d12.IRootSignature,
    m_staging_buffers : [dynamic]StagingBuffer,
    m_render_target_binder : RenderTargetBinder,
    m_buffer_pool : GPUResourcePool(GPUBuffer, GPUBufferID),
    m_texture_pool : GPUResourcePool(GPUTexture, GPUTextureID),
    m_descriptor_pool : [d3d12.DESCRIPTOR_HEAP_TYPE]GPUDescriptorPool
}

gpu_device_init :: proc(using in_device : ^GPUDevice)
{
    when ODIN_DEBUG 
    {
        debug_interface : ^d3d12.IDebug1
        if windows.SUCCEEDED(d3d12.GetDebugInterface(d3d12.IDebug1_UUID, (^rawptr)(&debug_interface)))
        {
            debug_interface->EnableDebugLayer()
            debug_interface->SetEnableGPUBasedValidation(true)
            debug_interface->SetEnableSynchronizedCommandQueueValidation(true)
        }
    }

    factory_flags : dxgi.CREATE_FACTORY
    when ODIN_DEBUG do factory_flags = { dxgi.CREATE_FACTORY_FLAG.DEBUG }

    factory : ^dxgi.IFactory6
    panic_if_failed(dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory6_UUID, (^rawptr)(&factory)))

    panic_if_failed(factory->EnumAdapterByGpuPreference(0, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&m_adapter)))

    // TODO: move to _12_2 for ray tracing
    panic_if_failed(d3d12.CreateDevice((^dxgi.IUnknown)(m_adapter), ._12_1, d3d12.IDevice5_UUID, (^rawptr)(&m_device)))

    copy_queue_desc := d3d12.COMMAND_QUEUE_DESC { Type = .COPY }
    direct_queue_desc := d3d12.COMMAND_QUEUE_DESC { Type = .DIRECT }
    compute_queue_desc := d3d12.COMMAND_QUEUE_DESC { Type = .COMPUTE }

    panic_if_failed(m_device->CreateCommandQueue(&copy_queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&m_copy_queue)))
    panic_if_failed(m_device->CreateCommandQueue(&compute_queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&m_compute_queue)))
    panic_if_failed(m_device->CreateCommandQueue(&direct_queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&m_graphics_queue)))

    gpu_descriptor_pool_create(&m_descriptor_pool[.RTV], in_device, .RTV, RTV_HEAP_SIZE, {})
    gpu_descriptor_pool_create(&m_descriptor_pool[.DSV], in_device, .DSV, DSV_HEAP_SIZE, {})
    gpu_descriptor_pool_create(&m_descriptor_pool[.SAMPLER], in_device, .SAMPLER, SAMPLER_HEAP_SIZE, { .SHADER_VISIBLE })
    gpu_descriptor_pool_create(&m_descriptor_pool[.CBV_SRV_UAV], in_device, .CBV_SRV_UAV, RESOURCE_HEAP_SIZE, { .SHADER_VISIBLE })

    ROOT_PARAMETERS := [?]d3d12.ROOT_PARAMETER1 {
        d3d12.ROOT_PARAMETER1 { 
            ParameterType = ._32BIT_CONSTANTS, 
            Constants = { ShaderRegister = 0 /* b0 */, Num32BitValues = ROOT_CONSTANTS_SIZE / size_of(windows.DWORD) }
        },
        d3d12.ROOT_PARAMETER1 { ParameterType = .CBV, Descriptor = {ShaderRegister = 1 /* b1 */ } },
        d3d12.ROOT_PARAMETER1 { ParameterType = .SRV, Descriptor = {ShaderRegister = 0 /* t0 */ } },
        d3d12.ROOT_PARAMETER1 { ParameterType = .SRV, Descriptor = {ShaderRegister = 1 /* t1 */ } }
    }

    root_sig_desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
        Version = ._1_1,
        Desc_1_1 = {
            NumParameters = len(ROOT_PARAMETERS),
            pParameters = raw_data(&ROOT_PARAMETERS),
            NumStaticSamplers = len(STATIC_SAMPLER_DESC),
            pStaticSamplers = raw_data(&STATIC_SAMPLER_DESC),
            Flags = { .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT, .CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED }
        }
    }

    error : ^d3d12.IBlob = nil
    signature : ^d3d12.IBlob = nil
    hresult := d3d12.SerializeVersionedRootSignature(&root_sig_desc, &signature, &error)
    if error != nil do windows.OutputDebugStringA(windows.LPCSTR(error->GetBufferPointer()))

    panic_if_failed(hresult)
    panic_if_failed(m_device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&m_root_signature)))

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC { Type = .RTV, NumDescriptors = d3d12.SIMULTANEOUS_RENDER_TARGET_COUNT }
    panic_if_failed(m_device->CreateDescriptorHeap(&rtv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&m_render_target_binder.m_rtv_heap)))
    
    m_render_target_binder.m_rtv_incr = m_device->GetDescriptorHandleIncrementSize(.RTV)

    dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC { Type = .DSV, NumDescriptors = 1 }    
    panic_if_failed(m_device->CreateDescriptorHeap(&dsv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&m_render_target_binder.m_dsv_heap)))

    m_render_target_binder.m_rtv_heap->GetCPUDescriptorHandleForHeapStart(&m_render_target_binder.m_rtv_handle)
    m_render_target_binder.m_dsv_heap->GetCPUDescriptorHandleForHeapStart(&m_render_target_binder.m_dsv_handle)
}

gpu_bind_device_defaults :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList)
{
    in_cmd_list.m_cmds->IASetPrimitiveTopology(.TRIANGLELIST)

    descriptor_heaps : [2]^d3d12.IDescriptorHeap = 
    {
        in_device.m_descriptor_pool[.SAMPLER].m_heap,
        in_device.m_descriptor_pool[.CBV_SRV_UAV].m_heap
    }

    in_cmd_list.m_cmds->SetDescriptorHeaps(len(descriptor_heaps), raw_data(&descriptor_heaps))

    in_cmd_list.m_cmds->SetComputeRootSignature(in_device.m_root_signature)
    in_cmd_list.m_cmds->SetGraphicsRootSignature(in_device.m_root_signature)
}

gpu_bind_render_targets :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_render_targets : []RenderTargetBinding, in_depth_target : ^DepthStencilBinding)
{
    using in_device;

    rtv_handle := in_device.m_render_target_binder.m_rtv_handle
    for &render_target in in_render_targets
    {
        desc := &render_target.m_description
        if render_target.m_description.ViewDimension == .UNKNOWN || render_target.m_description.Format == .UNKNOWN do desc = nil

        m_device->CreateRenderTargetView(render_target.m_resource, desc, rtv_handle)

        rtv_handle.ptr += uint(in_device.m_render_target_binder.m_rtv_incr)
    }

    dsv_handle := &in_device.m_render_target_binder.m_dsv_handle

    if in_depth_target != nil
    {
        desc := &in_depth_target.m_description
        if in_depth_target.m_description.ViewDimension == .UNKNOWN || in_depth_target.m_description.Format == .UNKNOWN do desc = nil

        dsv_handle := in_device.m_render_target_binder.m_dsv_handle
        m_device->CreateDepthStencilView(in_depth_target.m_resource, desc, dsv_handle)
    }
    else do dsv_handle = nil

    in_cmd_list.m_cmds->OMSetRenderTargets(u32(len(in_render_targets)), &in_device.m_render_target_binder.m_rtv_handle, true, dsv_handle)
}

gpu_clear_render_target :: proc(in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_index : u32, in_color : ^[4]f32)
{
    handle := d3d12.CPU_DESCRIPTOR_HANDLE { in_device.m_render_target_binder.m_rtv_handle.ptr + uint(in_index * in_device.m_render_target_binder.m_rtv_incr) }
    in_cmd_list.m_cmds->ClearRenderTargetView(handle, in_color, 0, nil)
}

gpu_clear_depth_stencil_target :: proc(device : ^GPUDevice, cmds : ^CommandList, depth : ^f32, stencil : ^u8 = nil)
{
    handle := d3d12.CPU_DESCRIPTOR_HANDLE { device.m_render_target_binder.m_dsv_handle.ptr }

    clear_flags : d3d12.CLEAR_FLAGS = {}
    if depth != nil do clear_flags |=  { .DEPTH }
    if stencil != nil do clear_flags |= { .STENCIL }

    cmds.m_cmds->ClearDepthStencilView(handle, clear_flags, depth^, stencil^, 0, nil)
}

gpu_device_destroy :: proc(using in_device : ^GPUDevice) 
{
    m_device->Release()
    m_adapter->Release()
    m_copy_queue->Release()
    m_graphics_queue->Release()
    m_root_signature->Release()
    gpu_resource_pool_clear(&m_buffer_pool)
    gpu_resource_pool_clear(&m_texture_pool)
    for &pool in m_descriptor_pool do gpu_resource_pool_clear(&pool.m_pool)
}

gpu_get_cpu_descriptor_handle :: proc(in_descriptor_pool : ^GPUDescriptorPool, in_descriptor : GPUDescriptorID) -> d3d12.CPU_DESCRIPTOR_HANDLE
{
    handle := d3d12.CPU_DESCRIPTOR_HANDLE {}
    in_descriptor_pool.m_heap->GetCPUDescriptorHandleForHeapStart(&handle)
    return d3d12.CPU_DESCRIPTOR_HANDLE { handle.ptr + uint(in_descriptor.m_index * in_descriptor_pool.m_heap_incr) }
}

gpu_get_gpu_descriptor_handle :: proc(in_descriptor_pool : ^GPUDescriptorPool, in_descriptor : GPUDescriptorID) -> d3d12.GPU_DESCRIPTOR_HANDLE
{
    handle := d3d12.GPU_DESCRIPTOR_HANDLE {}
    in_descriptor_pool.m_heap->GetGPUDescriptorHandleForHeapStart(&handle)
    return d3d12.GPU_DESCRIPTOR_HANDLE { handle.ptr + u64(in_descriptor.m_index * in_descriptor_pool.m_heap_incr) }
}

gpu_create_uav :: proc(using in_device : ^GPUDevice, in_resource : GPUResource, in_desc : ^d3d12.UNORDERED_ACCESS_VIEW_DESC) -> GPUDescriptorID
{
    heap := &m_descriptor_pool[d3d12.DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV]
    descriptor := gpu_resource_pool_add(&heap.m_pool, in_resource)
    descriptor_handle := gpu_get_cpu_descriptor_handle(heap, descriptor)

    m_device->CreateUnorderedAccessView(in_resource.m_resource, nil, in_desc, descriptor_handle)

    return descriptor
}

gpu_create_srv :: proc(using in_device : ^GPUDevice, in_resource : GPUResource, in_desc : ^d3d12.SHADER_RESOURCE_VIEW_DESC) -> GPUDescriptorID
{
    heap := &m_descriptor_pool[d3d12.DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV]
    descriptor := gpu_resource_pool_add(&heap.m_pool, in_resource)
    descriptor_handle := gpu_get_cpu_descriptor_handle(heap, descriptor)

    m_device->CreateShaderResourceView(in_resource.m_resource, in_desc, descriptor_handle)
    
    return descriptor
}

gpu_create_buffer_descriptor :: proc(using in_device : ^GPUDevice, in_buffer_id : GPUBufferID, in_desc : GPUBufferDesc)
{
    buffer := gpu_get_buffer(in_device, in_buffer_id)
    buffer.m_desc.usage = in_desc.usage

    switch (in_desc.usage)
    {
        case .READBACK: break
        case .SHADER_READ_WRITE: 
        {
            uav_desc := gpu_buffer_desc_to_uav_desc(in_desc)
            buffer.m_descriptor = gpu_create_uav(in_device, buffer, &uav_desc)
        }
        case .UPLOAD, .GENERAL, .INDEX_BUFFER, .VERTEX_BUFFER, .SHADER_READ_ONLY, .INDIRECT_ARGUMENTS, .ACCELERATION_STRUCTURE: 
        {
            srv_desc := gpu_buffer_desc_to_srv_desc(in_desc)

            if in_desc.usage == .ACCELERATION_STRUCTURE 
            {
                srv_desc.RaytracingAccelerationStructure.Location = buffer.m_resource->GetGPUVirtualAddress()
                // resource must be nil, since the resource location comes from a GPUVA in desc 
                resource := GPUResource { m_resource = nil }
                buffer.m_descriptor = gpu_create_srv(in_device, resource, &srv_desc)
            }
            else if in_desc.format != .UNKNOWN || in_desc.stride > 0
            {
                buffer.m_descriptor = gpu_create_srv(in_device, buffer, &srv_desc)
            }
        }
    }
}

gpu_create_texture_descriptor :: proc(using in_device : ^GPUDevice, in_texture_id : GPUTextureID, in_desc : GPUTextureDesc)
{
    texture := gpu_get_texture(in_device, in_texture_id)
    texture.m_desc.usage = in_desc.usage

    switch (in_desc.usage)
    {
        case .SHADER_READ_ONLY: 
        {
            srv_desc := gpu_texture_desc_to_srv_desc(in_desc)
            texture.m_descriptor = gpu_create_srv(in_device, texture.resource, &srv_desc)            
        }
        case .SHADER_READ_WRITE:
        {
            uav_desc := gpu_texture_desc_to_uav_desc(in_desc)
            texture.m_descriptor = gpu_create_uav(in_device, texture.resource, &uav_desc)
        }
        case .GENERAL, .DEPTH_STENCIL_TARGET, .RENDER_TARGET: break
    }
}

gpu_create_buffer :: proc(using in_device : ^GPUDevice, in_desc : GPUBufferDesc) -> GPUBufferID
{
    buffer := GPUBuffer { m_desc = in_desc }

    heap_properties : d3d12.HEAP_PROPERTIES = { Type = in_desc.mapped ? d3d12.HEAP_TYPE.UPLOAD : d3d12.HEAP_TYPE.DEFAULT }

    if in_desc.usage == GPUBufferUsage.READBACK {
        heap_properties.Type = .READBACK
    }
    else if in_desc.usage == GPUBufferUsage.UPLOAD {
        heap_properties.Type = .UPLOAD
    }

    heap_flags : d3d12.HEAP_FLAGS = {}

    resource_desc := cd3dx12_buffer_desc(in_desc.size)

    #partial switch (in_desc.usage)
    {
        case .VERTEX_BUFFER, .INDEX_BUFFER : {
            if !in_desc.mapped do resource_desc.Flags = { .ALLOW_UNORDERED_ACCESS }
        }
        case .SHADER_READ_WRITE, .ACCELERATION_STRUCTURE : {
            resource_desc.Flags = { .ALLOW_UNORDERED_ACCESS }
        }
    }

    initial_state := gpu_usage_to_initial_state(in_desc.usage)

    // TODO: create D3D12MA bindings
    panic_if_failed(m_device->CreateCommittedResource(&heap_properties, heap_flags, &resource_desc, initial_state, nil, d3d12.IResource1_UUID, (^rawptr)(&buffer.m_resource)))

    buffer_id : GPUBufferID = gpu_resource_pool_add(&in_device.m_buffer_pool, buffer)

    gpu_create_buffer_descriptor(in_device, buffer_id, in_desc)

    return buffer_id
}

gpu_create_texture :: proc(using in_device : ^GPUDevice, in_desc : GPUTextureDesc) -> GPUTextureID
{
    texture := GPUTexture { m_desc = in_desc }

    heap_properties := d3d12.HEAP_PROPERTIES { Type = .DEFAULT }

    heap_flags := d3d12.HEAP_FLAGS {}

    resource_desc := cd3dx12_texture2d_desc(in_desc.format, in_desc.width, in_desc.height, in_desc.depth_or_layers, in_desc.mips)

    // usage
    #partial switch (in_desc.usage)
    {
        case .RENDER_TARGET : resource_desc.Flags |= { .ALLOW_RENDER_TARGET }
        case .DEPTH_STENCIL_TARGET : resource_desc.Flags |= { .ALLOW_DEPTH_STENCIL }
        case .SHADER_READ_WRITE : resource_desc.Flags |= { .ALLOW_UNORDERED_ACCESS }
    }

    initial_state := gpu_usage_to_initial_state(in_desc.usage)

    clear_value := d3d12.CLEAR_VALUE {}
    clear_value_ptr : ^d3d12.CLEAR_VALUE = nil

    if in_desc.usage == .DEPTH_STENCIL_TARGET 
    {
        clear_value = d3d12.CLEAR_VALUE {Format = in_desc.format, DepthStencil = {1.0, 0.0} }
        clear_value_ptr = &clear_value
    }
    else if in_desc.usage == .RENDER_TARGET 
    {
        clear_value = d3d12.CLEAR_VALUE { Format = in_desc.format, Color = {0.0, 0.0, 0.0, 0.0}}
        clear_value_ptr = &clear_value
    }

    // TODO: create D3D12MA bindings
    panic_if_failed(m_device->CreateCommittedResource(&heap_properties, heap_flags, &resource_desc, initial_state, clear_value_ptr, d3d12.IResource1_UUID, (^rawptr)(&texture.m_resource)))

    texture.m_resource->SetName(raw_data(windows.utf8_to_utf16(texture.m_desc.debug_name)))

    texture_id := gpu_resource_pool_add(&in_device.m_texture_pool, texture)

    gpu_create_texture_descriptor(in_device, texture_id, in_desc)

    return texture_id
}

gpu_create_buffer_view :: proc(in_device : ^GPUDevice, in_id : GPUBufferID, in_desc : GPUBufferDesc) -> GPUBufferID
{
    buffer := gpu_get_buffer(in_device, in_id)^
    buffer.m_desc = in_desc

    buffer_id := gpu_resource_pool_add(&in_device.m_buffer_pool, buffer)
    gpu_create_buffer_descriptor(in_device, buffer_id, in_desc)

    return buffer_id
}

gpu_create_texture_view :: proc(in_device : ^GPUDevice, in_id : GPUTextureID, in_desc : GPUTextureDesc) -> GPUTextureID
{
    texture := gpu_get_texture(in_device, in_id)^
    texture.m_desc = in_desc

    texture_id := gpu_resource_pool_add(&in_device.m_texture_pool, texture)
    gpu_create_texture_descriptor(in_device, texture_id, in_desc)

    return texture_id
}

gpu_get_buffer :: proc(in_device : ^GPUDevice, in_buffer_id : GPUBufferID) -> ^GPUBuffer
{
    return &in_device.m_buffer_pool.m_storage[in_buffer_id.m_index]
}

gpu_get_texture :: proc(in_device : ^GPUDevice, in_texture_id : GPUTextureID) -> ^GPUTexture
{
    return &in_device.m_texture_pool.m_storage[in_texture_id.m_index]
}

gpu_stage_buffer :: proc(device : ^GPUDevice, cmds : ^d3d12.IGraphicsCommandList, dst_buffer : ^GPUBuffer, offset : u32, data : rawptr, size : u32)
{
    for &buffer in device.m_staging_buffers 
    {
        if buffer.retired && size <= buffer.capacity - buffer.size 
        {
            mem.copy(buffer.mapped_ptr, data, int(size))

            staging_buffer := gpu_get_buffer(device, buffer.buffer_id)
            cmds->CopyBufferRegion(dst_buffer.m_resource, u64(offset), staging_buffer.m_resource, u64(buffer.size), u64(size))
        }
    }

    buffer_id := gpu_create_buffer(device, GPUBufferDesc {
        size  = u64(size),
        usage = .UPLOAD,
        debug_name = "StagingBuffer"
    })

    staging_buffer := gpu_get_buffer(device, buffer_id)

    mapped_ptr : rawptr
    staging_buffer.m_resource->Map(0, nil, &mapped_ptr)
    mem.copy(mapped_ptr, data, int(size))

    assert(dst_buffer.m_desc.size >= u64(size))
    cmds->CopyBufferRegion(dst_buffer.m_resource, u64(offset), staging_buffer.m_resource, 0, u64(size))

    append(&device.m_staging_buffers, StagingBuffer {
        retired   = false,
        //frame_id  = cmds.frame_id,
        buffer_id = buffer_id,
        size      = size,
        capacity  = size
    })
}

gpu_stage_texture :: proc(device : ^GPUDevice, cmds : ^d3d12.IGraphicsCommandList, texture : ^GPUTexture, subresource : u32, data : rawptr)
{
    nr_of_rows : u32 = 0
    row_size, total_size : u64 = 0, 0
    footprint := d3d12.PLACED_SUBRESOURCE_FOOTPRINT {}

    desc : d3d12.RESOURCE_DESC
    texture.m_resource->GetDesc(&desc)
    device.m_device->GetCopyableFootprints(&desc, subresource, 1, 0, &footprint, &nr_of_rows, &row_size, &total_size)

    buffer_id := gpu_create_buffer(device, GPUBufferDesc {
        size = total_size,
        usage = .UPLOAD,
        debug_name = "StagingBuffer"
    })

    buffer := gpu_get_buffer(device, buffer_id)

    mapped_ptr : rawptr
    buffer.m_resource->Map(0, nil, &mapped_ptr)

    base_data_ptr := cast([^]u8)data
    base_mapped_ptr := cast([^]u8)mapped_ptr

    for row in 0..<nr_of_rows 
    {
        copy_src := base_data_ptr[u64(row) * row_size:]
        copy_dst := base_mapped_ptr[u32(footprint.Offset) + row * footprint.Footprint.RowPitch:]
        mem.copy(copy_dst, copy_src, int(row_size))
    }

    src := d3d12.TEXTURE_COPY_LOCATION { pResource = buffer.m_resource, Type = .PLACED_FOOTPRINT, PlacedFootprint = footprint}
    dst := d3d12.TEXTURE_COPY_LOCATION { pResource = texture.m_resource, Type = .SUBRESOURCE_INDEX, SubresourceIndex = subresource }

    cmds->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)

    append(&device.m_staging_buffers, StagingBuffer {
        retired   = false,
        //frame_id  = cmds.frame_id,
        buffer_id = buffer_id,
        size      = u32(total_size),
        capacity  = u32(total_size)
    })

    barrier := cd3dx12_barrier_transition(texture.m_resource, {.COPY_DEST}, d3d12.RESOURCE_STATE_GENERIC_READ, subresource)
    cmds->ResourceBarrier(1, &barrier)
}

gpu_create_graphics_pipeline_state_desc :: proc(in_device : ^GPUDevice, in_pass : RenderPass, in_vs_blob : []u8, in_ps_blob : []u8) -> d3d12.GRAPHICS_PIPELINE_STATE_DESC
{
    pso_state := d3d12.GRAPHICS_PIPELINE_STATE_DESC {
        pRootSignature = in_device.m_root_signature,
        VS = d3d12.SHADER_BYTECODE { raw_data(in_vs_blob), len(in_vs_blob) },
        PS = d3d12.SHADER_BYTECODE { raw_data(in_ps_blob), len(in_ps_blob) },
        BlendState = CD3DX12_BLEND_DESC(),
        SampleMask = 0xFFFFFFFF,
        RasterizerState = CD3DX12_RASTERIZER_DESC(),
        DepthStencilState = CD3DX12_DEPTH_STENCIL_DESC(),
        PrimitiveTopologyType = .TRIANGLE,
        SampleDesc = dxgi.SAMPLE_DESC { Count = 1 }
    }

    pso_state.RasterizerState.FrontCounterClockwise = true

    for format, index in in_pass.m_render_target_formats {
        pso_state.RTVFormats[index] = format
        pso_state.NumRenderTargets = u32(index + 1)
    }

    pso_state.DSVFormat = in_pass.m_depth_target_format

    return pso_state
}

gpu_create_compute_pipeline_state_desc :: proc(in_device : ^GPUDevice, in_pass : RenderPass, in_cs_blob : []u8) -> d3d12.COMPUTE_PIPELINE_STATE_DESC
{
    return d3d12.COMPUTE_PIPELINE_STATE_DESC { pRootSignature = in_device.m_root_signature, CS = d3d12.SHADER_BYTECODE { raw_data(in_cs_blob), len(in_cs_blob) }}
}