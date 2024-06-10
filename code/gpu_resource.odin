package main

import "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

TEXTURE_SWIZZLE_RGBA :: 0b11100100
TEXTURE_SWIZZLE_RRRR :: 0b00000000
TEXTURE_SWIZZLE_GGGG :: 0b01010101
TEXTURE_SWIZZLE_BBBB :: 0b10101010
TEXTURE_SWIZZLE_AAAA :: 0b11111111

unswizzle_single_channel :: proc(swizzle: u8, channel: u8) -> u8 
{ 
    return ( ( swizzle >> ( channel * 2 ) ) & 0b00000011 ); 
}

unswizzle_all_channels :: proc(swizzle : u8) -> (r: u8, g: u8, b: u8, a: u8) 
{ 
    r = unswizzle_single_channel(swizzle, 0) 
    g = unswizzle_single_channel(swizzle, 1) 
    b = unswizzle_single_channel(swizzle, 2) 
    a = unswizzle_single_channel(swizzle, 3) 
    return r, g, b, a
}

unswizzle :: proc {unswizzle_single_channel, unswizzle_all_channels}

D3D12_SHADER_COMPONENT_MAPPING_ALWAYS_SET_BIT_AVOIDING_ZEROMEM_MISTAKES :: (1<<(d3d12.SHADER_COMPONENT_MAPPING_SHIFT*4)) 
D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING :: proc(Src0: u32, Src1: u32, Src2: u32, Src3: u32) -> u32
{
    return ((((Src0)&d3d12.SHADER_COMPONENT_MAPPING_MASK) | 
    (((Src1)&d3d12.SHADER_COMPONENT_MAPPING_MASK)<<d3d12.SHADER_COMPONENT_MAPPING_SHIFT) | 
    (((Src2)&d3d12.SHADER_COMPONENT_MAPPING_MASK)<<(d3d12.SHADER_COMPONENT_MAPPING_SHIFT*2)) | 
    (((Src3)&d3d12.SHADER_COMPONENT_MAPPING_MASK)<<(d3d12.SHADER_COMPONENT_MAPPING_SHIFT*3)) | 
    D3D12_SHADER_COMPONENT_MAPPING_ALWAYS_SET_BIT_AVOIDING_ZEROMEM_MISTAKES))
}

D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING :: proc() -> u32 
{ 
    return D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(0,1,2,3)
}

GPUResource :: struct
{
    m_resource : ^d3d12.IResource
}

GPUResourceKind :: enum
{
    BUFFER,
    TEXTURE
}

GPUBufferUsage :: enum
{
    GENERAL, 
    UPLOAD,
    READBACK,
    INDEX_BUFFER,
    VERTEX_BUFFER,
    SHADER_READ_ONLY,
    SHADER_READ_WRITE,
    INDIRECT_ARGUMENTS,
    ACCELERATION_STRUCTURE
}

GPUTextureUsage :: enum
{
    GENERAL,
    SHADER_READ_ONLY,
    SHADER_READ_WRITE,
    RENDER_TARGET,
    DEPTH_STENCIL_TARGET
}

GPUBufferDesc :: struct
{
    format : dxgi.FORMAT,
    size : u64,
    stride : u32,
    usage : GPUBufferUsage,
    mapped : bool,
    swizzle : u8,
    debug_name : string
}

GPUTextureDesc :: struct 
{
    format : dxgi.FORMAT,
    width : u64,
    height : u32,
    depth_or_layers : u16,
    base_mip : u32,
    mips : u16,
    usage : GPUTextureUsage,
    debug_name : string
}

GPUBuffer :: struct 
{
    using resource : GPUResource,
    m_desc : GPUBufferDesc,
    m_descriptor : GPUDescriptorID,
    m_mapped_ptr : rawptr
}

GPUTexture :: struct 
{
    using resource : GPUResource,
    m_desc : GPUTextureDesc,
    m_descriptor : GPUDescriptorID
}

GPUResourceID :: bit_field u32 
{
    m_index : u32 | 20,
    m_generation : u32 | 12
}

GPUBufferID :: distinct GPUResourceID
GPUTextureID :: distinct GPUResourceID
GPUDescriptorID :: distinct GPUResourceID

GPUResourcePool :: struct($Resource: typeid, $ResourceID : typeid)
{
    m_generations : [dynamic]u16,
    m_free_indices : [dynamic]u32,
    m_storage : [dynamic]Resource
}

GPUDescriptorPool :: struct 
{
    using m_pool : GPUResourcePool(GPUResource, GPUDescriptorID),
    m_heap : ^d3d12.IDescriptorHeap,
    m_heap_ptr : d3d12.CPU_DESCRIPTOR_HANDLE,
    m_heap_incr : u32,
}

gpu_descriptor_pool_create :: proc(using in_pool : ^GPUDescriptorPool, in_device : ^GPUDevice, in_type : d3d12.DESCRIPTOR_HEAP_TYPE, in_count : int, in_flags : d3d12.DESCRIPTOR_HEAP_FLAGS)
{
    gpu_resource_pool_reserve(&m_pool, in_count)

    desc := d3d12.DESCRIPTOR_HEAP_DESC {
        Type = in_type,
        NumDescriptors = u32(in_count),
        Flags = in_flags
    }

    heap_type_debug_names : [d3d12.DESCRIPTOR_HEAP_TYPE] windows.wstring = {
        .CBV_SRV_UAV = windows.L("CBV_SRV_UAV"),
	    .SAMPLER = windows.L("SAMPLER"),
	    .RTV = windows.L("RTV"),
	    .DSV = windows.L("DSV")
    }

    panic_if_failed(in_device.m_device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&m_heap)));
    m_heap->SetName(heap_type_debug_names[in_type])
    
    m_heap->GetCPUDescriptorHandleForHeapStart(&m_heap_ptr)
    m_heap_incr = in_device.m_device->GetDescriptorHandleIncrementSize(in_type)

}

gpu_resource_pool_add :: proc(using in_pool : ^GPUResourcePool($Resource, $ResourceID), in_resource : Resource) -> ResourceID
{
    id : ResourceID
    if len(m_free_indices) == 0 
    {
        append(&m_storage, in_resource)
        append(&m_generations, 0)

        id.m_index = u32(len(m_storage) - 1)
        id.m_generation = 0
    }
    else
    {
        id.m_index = m_free_indices[len(m_free_indices) - 1]
        id.m_generation = u32(m_generations[id.m_index])

        m_storage[id.m_index] = in_resource
        pop(&m_free_indices)
    }
     return id
}

gpu_resource_pool_remove :: proc(using in_pool : ^GPUResourcePool($Resource, $ResourceID), in_id : GPUResourceID) 
{
    m_generations[in_id.m_index] += 1
    append(m_free_indices, in_id.m_index)
}

gpu_resource_pool_clear :: proc(using in_pool : ^GPUResourcePool($Resource, $ResourceID)) 
{
    clear(&m_free_indices)
    clear(&m_generations)
    clear(&m_storage)
}

gpu_resource_pool_reserve :: proc(using in_pool : ^GPUResourcePool($Resource, $ResourceID), in_size : int) 
{
    reserve_dynamic_array(&m_free_indices, in_size)
    reserve_dynamic_array(&m_generations, in_size)
    reserve_dynamic_array(&m_storage, in_size)
}

gpu_buffer_desc_equal :: proc(in_desc1 : GPUBufferDesc, in_desc2 : GPUBufferDesc) -> bool
{
    return in_desc1.format == in_desc2.format && 
            in_desc1.size == in_desc2.size &&
            in_desc1.stride == in_desc2.stride &&
            in_desc1.usage == in_desc2.usage &&
            in_desc1.mapped == in_desc2.mapped &&
            in_desc1.swizzle == in_desc2.swizzle;
}

gpu_texture_desc_equal :: proc(in_desc1 : GPUTextureDesc, in_desc2 : GPUTextureDesc) -> bool
{
    return in_desc1.format == in_desc2.format && 
            in_desc1.width == in_desc2.width &&
            in_desc1.height == in_desc2.height &&
            in_desc1.usage == in_desc2.usage &&
            in_desc1.depth_or_layers == in_desc2.depth_or_layers &&
            in_desc1.base_mip == in_desc2.base_mip &&
            in_desc1.mips == in_desc2.mips;
}

gpu_buffer_usage_to_resource_states :: proc(in_usage : GPUBufferUsage) -> d3d12.RESOURCE_STATES
{
    switch (in_usage)
    {
        case .GENERAL : return d3d12.RESOURCE_STATE_COMMON
        case .VERTEX_BUFFER : return { d3d12.RESOURCE_STATE.VERTEX_AND_CONSTANT_BUFFER }
        case .INDEX_BUFFER : return { d3d12.RESOURCE_STATE.INDEX_BUFFER}
        case .UPLOAD : return d3d12.RESOURCE_STATE_COMMON
        case .SHADER_READ_ONLY : return { .NON_PIXEL_SHADER_RESOURCE, .PIXEL_SHADER_RESOURCE }
        case .SHADER_READ_WRITE : return { d3d12.RESOURCE_STATE.UNORDERED_ACCESS }
        case .ACCELERATION_STRUCTURE : return { d3d12.RESOURCE_STATE.RAYTRACING_ACCELERATION_STRUCTURE }
        case .INDIRECT_ARGUMENTS : return { d3d12.RESOURCE_STATE.INDIRECT_ARGUMENT }
        case .READBACK : return { d3d12.RESOURCE_STATE.COPY_DEST }
    }

    return {}
}

gpu_texture_usage_to_resource_states :: proc(in_usage : GPUTextureUsage) -> d3d12.RESOURCE_STATES
{
    switch (in_usage)
    {
        case .GENERAL : return d3d12.RESOURCE_STATE_COMMON
        case .RENDER_TARGET : return { .RENDER_TARGET }
        case .DEPTH_STENCIL_TARGET : return { .DEPTH_WRITE }
        case .SHADER_READ_ONLY : return { .NON_PIXEL_SHADER_RESOURCE, .PIXEL_SHADER_RESOURCE }
        case .SHADER_READ_WRITE : return { .UNORDERED_ACCESS }
    }

    return {}
}

gpu_usage_to_resource_states :: proc{ gpu_buffer_usage_to_resource_states, gpu_texture_usage_to_resource_states }

gpu_buffer_usage_to_initial_state :: proc(in_usage : GPUBufferUsage) -> d3d12.RESOURCE_STATES
{
    initial_state := gpu_usage_to_resource_states(in_usage)
    if in_usage == .SHADER_READ_ONLY do initial_state = d3d12.RESOURCE_STATE_COMMON
    return initial_state
}

gpu_texture_usage_to_initial_state :: proc(in_usage : GPUTextureUsage) -> d3d12.RESOURCE_STATES
{
    initial_state := d3d12.RESOURCE_STATE_COMMON

    #partial switch (in_usage) 
    {
        case .DEPTH_STENCIL_TARGET : initial_state = { .DEPTH_WRITE }
        case .RENDER_TARGET : initial_state = { .RENDER_TARGET }
        case .SHADER_READ_WRITE : initial_state = { .UNORDERED_ACCESS }
    }

    return initial_state
}

gpu_usage_to_initial_state :: proc{ gpu_buffer_usage_to_initial_state, gpu_texture_usage_to_initial_state }

gpu_buffer_desc_to_uav_desc :: proc(in_desc : GPUBufferDesc) -> d3d12.UNORDERED_ACCESS_VIEW_DESC
{
    uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC { Format = in_desc.format, ViewDimension = .BUFFER }

    if in_desc.stride == 0 &&  in_desc.format == .R32_TYPELESS
    {
        // Raw buffer
        assert(in_desc.size >= 4)
        uav_desc.Buffer.Flags = { .RAW }
        uav_desc.Buffer.NumElements = u32(in_desc.size / size_of(u32))
    }
    else if in_desc.stride > 0 && in_desc.format == .UNKNOWN
    {
        // Structured buffer
        assert(in_desc.size > 0);
        uav_desc.Buffer.StructureByteStride = in_desc.stride;
        uav_desc.Buffer.NumElements = u32(in_desc.size / u64(in_desc.stride));
    }
    else if in_desc.format != .UNKNOWN
    {
        // Typed buffer
        format_size := bits_per_pixel(in_desc.format)
        assert(in_desc.size > 0 && format_size > 0 && format_size%8 == 0);
        uav_desc.Buffer.NumElements = u32(in_desc.size / ( format_size / 8 ));
    }

    // defined both a stride and format, bad time!
    assert((in_desc.stride > 0 && in_desc.format != .UNKNOWN) == false);

    // defined neither a stride or a format, bad time!
    assert(in_desc.stride > 0 || in_desc.format != .UNKNOWN);

    return uav_desc
}

gpu_buffer_desc_to_srv_desc :: proc(in_desc : GPUBufferDesc) -> d3d12.SHADER_RESOURCE_VIEW_DESC
{
    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC { Format = in_desc.format, ViewDimension = .BUFFER };
    srv_desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING();

    if in_desc.stride == 0 && in_desc.format == .R32_TYPELESS
    {
        // Raw (ByteAddress) buffer 
        assert(in_desc.size >= 4)
        srv_desc.Buffer.Flags = { .RAW }
        srv_desc.Buffer.NumElements = u32(in_desc.size / size_of(u32))
    }
    else if (in_desc.stride > 0 && in_desc.format == .UNKNOWN) 
    {
        // Structured buffer
        assert(in_desc.size > 0)
        srv_desc.Buffer.StructureByteStride = in_desc.stride
        srv_desc.Buffer.NumElements = u32(in_desc.size / u64(in_desc.stride))
    }
    else if in_desc.format != .UNKNOWN
    {
        // Typed buffer
        format_size := bits_per_pixel(srv_desc.Format)
        assert(in_desc.size > 0 && format_size > 0 && format_size%8 == 0)
        srv_desc.Buffer.NumElements = u32(in_desc.size / ( format_size / 8 ))
    }

    if in_desc.usage == .ACCELERATION_STRUCTURE
    {
        srv_desc.Format = .UNKNOWN
        srv_desc.ViewDimension = .RAYTRACING_ACCELERATION_STRUCTURE
    }

    return srv_desc
}

gpu_texture_desc_to_srv_desc :: proc(in_desc : GPUTextureDesc) -> d3d12.SHADER_RESOURCE_VIEW_DESC
{
    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
        ViewDimension = .TEXTURE2D,
        Texture2D = { MipLevels = 0xFFFFFFFF },
        Format = depth_to_srv_format(in_desc.format),
        Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING()
    }

    // TODO cube textures
    /*
        switch (in_desc.dimension)
        {
            case 
            {
                srv_desc.ViewDimension = d3d12.SRV_DIMENSION.TEXTURECUBE
                srv_desc.TextureCube.MipLevels = -1
                srv_desc.TextureCube.MostDetailedMip = 0
                srv_desc.TextureCube.ResourceMinLODClamp = 0.0
            } 
        }
    */

    return srv_desc;
}

gpu_texture_desc_to_uav_desc :: proc(in_desc : GPUTextureDesc) -> d3d12.UNORDERED_ACCESS_VIEW_DESC
{
    return d3d12.UNORDERED_ACCESS_VIEW_DESC {
        Format = in_desc.format,
        ViewDimension = .TEXTURE2D,
        Texture2D = { MipSlice = in_desc.base_mip }
    }
}