package main

import "core:fmt"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

RenderGraphResourceID :: distinct u32
RenderGraphResourceViewID :: distinct u32

RenderGraphResourceDesc :: struct
{
    m_resource_id : union {GPUTextureID, GPUBufferID},
    m_resource_desc : union {GPUBufferDesc, GPUTextureDesc}
}

RenderGraphResourceViewDesc :: struct
{
    m_graph_resource_id : RenderGraphResourceID,
    m_resource_view_desc : RenderGraphResourceDesc
}

RenderGraphResource :: struct
{
    m_id : union {GPUBufferID, GPUTextureID},
    m_imported : bool,
}

RenderGraphResources :: struct
{
    m_resources : [dynamic]RenderGraphResource,
    m_resource_views : [dynamic]RenderGraphResource
}

RenderGraphBuilder :: struct
{
    m_render_graph : ^RenderGraph,
    m_render_passes : [dynamic]u32,
    m_resource_descs : [dynamic]RenderGraphResourceDesc,
    m_resource_view_descs : [dynamic]RenderGraphResourceViewDesc
}

RenderGraph :: struct
{
    m_builder : RenderGraphBuilder,
    m_resources : RenderGraphResources,
    m_render_passes : [dynamic]AnyRenderPass
}

gpu_rg_create_texture :: proc(in_builder : ^RenderGraphBuilder, in_desc : GPUTextureDesc) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphResourceDesc { m_resource_desc = in_desc })

    graph_resource_id := len(in_builder.m_resource_descs) - 1

    return RenderGraphResourceID(graph_resource_id)
}

gpu_rg_create_buffer :: proc(in_builder : ^RenderGraphBuilder, in_desc : GPUBufferDesc) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphResourceDesc { m_resource_desc = in_desc })

    graph_resource_id := len(in_builder.m_resource_descs) - 1

    return RenderGraphResourceID(graph_resource_id)
}

gpu_rg_create :: proc{gpu_rg_create_texture}


gpu_rg_import :: proc(in_builder : ^RenderGraphBuilder, in_resource : GPUTextureID) -> RenderGraphResourceID
{
    return 0
}


gpu_rg_read :: proc(in_builder : ^RenderGraphBuilder, in_resource : RenderGraphResourceID) -> RenderGraphResourceViewID
{
    return 0
}

gpu_rg_render_target :: proc(in_builder : ^RenderGraphBuilder, in_resource : RenderGraphResourceID) -> RenderGraphResourceViewID
{
    return 0
}

gpu_rg_depth_stencil_target :: proc(in_builder : ^RenderGraphBuilder, in_resource : RenderGraphResourceID)  -> RenderGraphResourceViewID
{
    return 0   
}

gpu_rg_add_pass :: proc(in_graph : ^RenderGraph, in_pass : RenderPass($T)) -> T
{
    append(&in_graph.m_render_passes, in_pass)
    pass := in_graph.m_render_passes[len(in_graph.m_render_passes)-1]
    data := pass.(type_of(in_pass))
    return data.m_data
}

gpu_rg_compile :: proc(in_graph : ^RenderGraph, in_device : ^GPUDevice)
{
    ResourceType :: enum
    {
        BUFFER, TEXTURE
    }

    GraphEdge :: struct
    {
        subresource : u32,
        render_pass_index : u32,
        state : d3d12.RESOURCE_STATES
    }

    GraphNode :: struct
    {
        resource_type : ResourceType,
        base_subresource : u32,
        subresource_count : u32,
    }

    render_graph : map[RenderGraphResourceID]GraphNode

    for resource, resource_id in in_graph.m_resources.m_resources 
    {
        graph_node := render_graph[RenderGraphResourceID(resource_id)]

         switch type in resource.m_id 
         {
            case GPUBufferID: {

                buffer := gpu_get_buffer(in_device, resource.m_id.(GPUBufferID))
                graph_node.base_subresource = 0
                graph_node.subresource_count = 1
            }
            case GPUTextureID: 
            {
                texture := gpu_get_texture(in_device, resource.m_id.(GPUTextureID))
                graph_node.base_subresource = texture.m_desc.base_mip
                graph_node.subresource_count = u32(texture.m_desc.mips * texture.m_desc.depth_or_layers)
            }
        }
    }

    for render_pass, render_pass_index in in_graph.m_render_passes {

    }
}

