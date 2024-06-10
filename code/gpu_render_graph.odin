package main

import "core:fmt"
import "core:mem"
import "core:container/small_array"
import "vendor:directx/dxgi"
import "vendor:directx/d3d12"

RenderGraphResourceID :: distinct u32
RenderGraphResourceViewID :: distinct u32

RenderGraphBufferDesc :: struct 
{
    m_id : Maybe(GPUBufferID),
    m_desc : GPUBufferDesc
}

RenderGraphTextureDesc :: struct 
{
    m_id : Maybe(GPUTextureID),
    m_desc : GPUTextureDesc
}

RenderGraphResourceDesc :: union 
{
    RenderGraphBufferDesc, 
    RenderGraphTextureDesc
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

RenderPassKind :: enum 
{
    GRAPHICS, COMPUTE
}

RenderPassDesc :: struct($T : typeid)
{
    m_name : string,
    m_data : T,
    m_exec : proc(device : ^GPUDevice, cmd_list : ^CommandList, resources : ^RenderGraphResources, data : ^T)
}

RenderPass :: struct
{
    m_desc : AnyRenderPassDesc,
    m_kind : RenderPassKind,
    m_external : bool,
    m_depth_target_format : dxgi.FORMAT,
    m_render_target_formats : [dynamic]dxgi.FORMAT,
    m_exit_barriers : [dynamic]d3d12.RESOURCE_BARRIER,
    m_entry_barriers : [dynamic]d3d12.RESOURCE_BARRIER,
    m_created_resources : [dynamic]RenderGraphResourceID,
    m_read_resources : [dynamic]RenderGraphResourceViewID,
    m_written_resources : [dynamic]RenderGraphResourceViewID
}

RenderGraph :: struct
{
    m_builder : RenderGraphBuilder,
    m_resources : RenderGraphResources,
    m_render_passes : [dynamic]RenderPass
}

gpu_rg_create :: proc{gpu_rg_create_texture, gpu_rg_create_buffer}
gpu_rg_import :: proc{gpu_rg_import_texture, gpu_rg_import_buffer}

gpu_rg_create_texture :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_desc : GPUTextureDesc) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphTextureDesc { m_desc = in_desc })
    graph_resource_id := RenderGraphResourceID(len(in_builder.m_resource_descs) - 1)

    append(&render_pass.m_created_resources, graph_resource_id)
    
    return graph_resource_id
}

gpu_rg_create_buffer :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_desc : GPUBufferDesc) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphBufferDesc { m_desc = in_desc })
    graph_resource_id := RenderGraphResourceID(len(in_builder.m_resource_descs) - 1)

    append(&render_pass.m_created_resources, graph_resource_id)

    return graph_resource_id
}

gpu_rg_import_texture :: proc(in_device : ^GPUDevice, in_builder : ^RenderGraphBuilder, in_id : GPUTextureID) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphTextureDesc { m_id = in_id, m_desc =  gpu_get_texture(in_device, in_id).m_desc })

    graph_resource_id := len(in_builder.m_resource_descs) - 1

    return RenderGraphResourceID(graph_resource_id)
}

gpu_rg_import_buffer :: proc(in_device : ^GPUDevice, in_builder : ^RenderGraphBuilder, in_id : GPUBufferID) -> RenderGraphResourceID
{
    append(&in_builder.m_resource_descs, RenderGraphBufferDesc { m_id = in_id, m_desc = gpu_get_buffer(in_device, in_id).m_desc })

    graph_resource_id := len(in_builder.m_resource_descs) - 1

    return RenderGraphResourceID(graph_resource_id)
}

gpu_rg_read :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_resource_id : RenderGraphResourceID) -> RenderGraphResourceViewID
{
    desc := RenderGraphResourceViewDesc {
        m_graph_resource_id = in_resource_id,
        m_resource_view_desc = in_builder.m_resource_descs[in_resource_id]
    }

    switch &type in desc.m_resource_view_desc {
        case RenderGraphBufferDesc : type.m_desc.usage = .SHADER_READ_ONLY
        case RenderGraphTextureDesc : type.m_desc.usage = .SHADER_READ_ONLY
    }

    append(&in_builder.m_resource_view_descs, desc)
    graph_resource_id := RenderGraphResourceViewID(len(in_builder.m_resource_view_descs) - 1)

    append(&render_pass.m_read_resources, graph_resource_id)

    return graph_resource_id
}

gpu_rg_write :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_resource_id : RenderGraphResourceID) -> RenderGraphResourceViewID
{
    desc := RenderGraphResourceViewDesc {
        m_graph_resource_id = in_resource_id,
        m_resource_view_desc = in_builder.m_resource_descs[in_resource_id]
    }

    switch &view_desc in desc.m_resource_view_desc {
        case RenderGraphBufferDesc : view_desc.m_desc.usage = .SHADER_READ_WRITE
        case RenderGraphTextureDesc : view_desc.m_desc.usage = .SHADER_READ_WRITE
    }

    append(&in_builder.m_resource_view_descs, desc)
    graph_resource_id := RenderGraphResourceViewID(len(in_builder.m_resource_view_descs) - 1)

    append(&render_pass.m_written_resources, graph_resource_id)

    return graph_resource_id
}

gpu_rg_render_target :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_resource_id : RenderGraphResourceID) -> RenderGraphResourceViewID
{
    desc := RenderGraphResourceViewDesc {
        m_graph_resource_id = in_resource_id,
        m_resource_view_desc = in_builder.m_resource_descs[in_resource_id]
    }

    switch &view_desc in desc.m_resource_view_desc 
    {
        case RenderGraphBufferDesc : assert(false, "Can't use a buffer as render target!")
        case RenderGraphTextureDesc : view_desc.m_desc.usage = .RENDER_TARGET
    }

    append(&in_builder.m_resource_view_descs, desc)
    graph_resource_id := RenderGraphResourceViewID(len(in_builder.m_resource_view_descs) - 1)

    append(&render_pass.m_written_resources, graph_resource_id)
    append(&render_pass.m_render_target_formats, desc.m_resource_view_desc.(RenderGraphTextureDesc).m_desc.format)

    return graph_resource_id
}

gpu_rg_depth_stencil_target :: proc(in_builder : ^RenderGraphBuilder, render_pass : ^RenderPass, in_resource_id : RenderGraphResourceID)  -> RenderGraphResourceViewID
{
    desc := RenderGraphResourceViewDesc {
        m_graph_resource_id = in_resource_id,
        m_resource_view_desc = in_builder.m_resource_descs[in_resource_id]
    }

    switch &view_desc in desc.m_resource_view_desc {
        case RenderGraphBufferDesc : assert(false, "Can't use a buffer as depth stencil target!")
        case RenderGraphTextureDesc : view_desc.m_desc.usage = .DEPTH_STENCIL_TARGET
    }

    append(&in_builder.m_resource_view_descs, desc)
    graph_resource_id := RenderGraphResourceViewID(len(in_builder.m_resource_view_descs) - 1)

    append(&render_pass.m_written_resources, graph_resource_id)
    render_pass.m_depth_target_format = desc.m_resource_view_desc.(RenderGraphTextureDesc).m_desc.format

    return graph_resource_id
}

gpu_rg_add_pass :: proc(in_graph : ^RenderGraph, in_pass : RenderPass, in_desc : RenderPassDesc($T)) -> T
{
    render_pass := in_pass
    render_pass.m_desc = in_desc
    append(&in_graph.m_render_passes, render_pass)

    pass := in_graph.m_render_passes[len(in_graph.m_render_passes)-1]
    data := pass.m_desc.(type_of(in_desc))
    return data.m_data
}

gpu_rg_compile :: proc(using in_graph : ^RenderGraph, in_device : ^GPUDevice)
{
    resource_descriptions : [dynamic]d3d12.RESOURCE_DESC
    reserve(&resource_descriptions, len(m_builder.m_resource_descs))

    for resource_desc in m_builder.m_resource_descs 
    {
        resource : RenderGraphResource = {}

        switch desc in resource_desc 
        {
            case RenderGraphBufferDesc : 
            {
                if desc.m_id != nil 
                {
                    resource.m_id = desc.m_id.(GPUBufferID)
                    resource.m_imported = true
                }
                else do resource.m_id = gpu_create_buffer(in_device, desc.m_desc)
            }
            case RenderGraphTextureDesc :
            {
                if desc.m_id != nil 
                {
                    resource.m_id = desc.m_id.(GPUTextureID)
                    resource.m_imported = true
                }
                else do resource.m_id = gpu_create_texture(in_device, desc.m_desc)
            }
        }

        append(&m_resources.m_resources, resource)
    }

    for descriptor_desc in m_builder.m_resource_view_descs
    {
        resource := m_resources.m_resources[descriptor_desc.m_graph_resource_id]
        resource_desc := m_builder.m_resource_descs[descriptor_desc.m_graph_resource_id]

        new_resource := resource
        device_resource_id := m_resources.m_resources[descriptor_desc.m_graph_resource_id].m_id

        switch id in device_resource_id 
        {
            case GPUBufferID : 
            {
                if !gpu_buffer_desc_equal(descriptor_desc.m_resource_view_desc.(RenderGraphBufferDesc).m_desc, resource_desc.(RenderGraphBufferDesc).m_desc) 
                {
                    new_resource.m_id = gpu_create_buffer_view(in_device, id, descriptor_desc.m_resource_view_desc.(RenderGraphBufferDesc).m_desc)
                }
            }
            case GPUTextureID : 
            {
                if !gpu_texture_desc_equal(descriptor_desc.m_resource_view_desc.(RenderGraphTextureDesc).m_desc, resource_desc.(RenderGraphTextureDesc).m_desc) 
                {
                    new_resource.m_id = gpu_create_texture_view(in_device, id, descriptor_desc.m_resource_view_desc.(RenderGraphTextureDesc).m_desc)
                }
            }
        }

        append(&m_resources.m_resource_views, new_resource)
    }

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
        base_subresource : u32,
        subresource_count : u32,
        edges : [dynamic]GraphEdge
    }

    render_graph : map[RenderGraphResourceID]GraphNode

    // initialize all the graph nodes (all the created/imported resources)
    for resource, resource_id in m_resources.m_resources 
    {
         switch type in resource.m_id 
         {
            case GPUBufferID: 
            {
                render_graph[RenderGraphResourceID(resource_id)] = GraphNode {
                    base_subresource = 0,
                    subresource_count = 1
                }
            }
            case GPUTextureID: 
            {
                texture := gpu_get_texture(in_device, resource.m_id.(GPUTextureID))
                render_graph[RenderGraphResourceID(resource_id)] = GraphNode {
                    base_subresource = texture.m_desc.base_mip,
                    subresource_count = u32(texture.m_desc.mips * texture.m_desc.depth_or_layers)
                }
            }
        }

        graph_node := &render_graph[RenderGraphResourceID(resource_id)]
        assert(graph_node.subresource_count > 0)
    }

    // go through all the written/read views and add edges to nodes
    for render_pass, render_pass_index in m_render_passes 
    {
        connect_edges :: proc(using in_graph : ^RenderGraph, in_device : ^GPUDevice, in_render_graph : ^map[RenderGraphResourceID]GraphNode, in_pass_index : u32, in_resources : []RenderGraphResourceViewID)
        {
            for resource_id in in_resources
            {
                view_desc := m_builder.m_resource_view_descs[resource_id]
                graph_node := &in_render_graph[view_desc.m_graph_resource_id]

                state := d3d12.RESOURCE_STATE_COMMON

                // default for buffers
                subresource_index : u32 = 0
                subresource_count : u32 = 1

                switch desc in view_desc.m_resource_view_desc 
                {
                    case RenderGraphBufferDesc : {
                        buffer := gpu_get_buffer(in_device, m_resources.m_resource_views[resource_id].m_id.(GPUBufferID))
                        state = gpu_buffer_usage_to_resource_states(buffer.m_desc.usage)
                    }

                    case RenderGraphTextureDesc : {
                        texture := gpu_get_texture(in_device, m_resources.m_resource_views[resource_id].m_id.(GPUTextureID))
                        state = gpu_texture_usage_to_resource_states(texture.m_desc.usage)

                        subresource_index = desc.m_desc.base_mip
                        subresource_count = u32(desc.m_desc.mips)
                    }
                }

                for subresource in subresource_index..<subresource_index+subresource_count {
                    append(&graph_node.edges, GraphEdge { subresource = subresource, render_pass_index = u32(in_pass_index), state = state})
                }
            }
        }

        connect_edges(in_graph, in_device, &render_graph, u32(render_pass_index), render_pass.m_read_resources[:])
        connect_edges(in_graph, in_device, &render_graph, u32(render_pass_index), render_pass.m_written_resources[:])

        for resource_id, node in render_graph 
        {
            if len(node.edges) < 2 do continue

            resource_ptr : ^d3d12.IResource = nil

            switch id in m_resources.m_resources[resource_id].m_id 
            {
                case GPUBufferID : resource_ptr = gpu_get_buffer(in_device, id).m_resource
                case GPUTextureID : resource_ptr = gpu_get_texture(in_device, id).m_resource
            }

            assert(resource_ptr != nil)

            tracked_state : [dynamic]d3d12.RESOURCE_STATES
            resize(&tracked_state, int(node.subresource_count))
            for &state in tracked_state do state = node.edges[0].state

            prev_pass_index := node.edges[0].render_pass_index
            uav_barrier_added := false

            for edge_index in 1..<len(node.edges) 
            {
                prev_edge := node.edges[edge_index-1]
                curr_edge := node.edges[edge_index]

                if curr_edge.render_pass_index != prev_edge.render_pass_index {
                    prev_pass_index = prev_edge.render_pass_index
                    uav_barrier_added = false
                }

                prev_pass := &m_render_passes[prev_pass_index]
                curr_pass := &m_render_passes[curr_edge.render_pass_index]

                old_state := &tracked_state[curr_edge.subresource]
                new_state := curr_edge.state

                if d3d12.RESOURCE_STATE.UNORDERED_ACCESS in old_state && d3d12.RESOURCE_STATE.UNORDERED_ACCESS in new_state && !uav_barrier_added 
                {
                    append(&prev_pass.m_exit_barriers, d3d12.RESOURCE_BARRIER { Type = .UAV, UAV = {pResource = resource_ptr}})
                    uav_barrier_added = true
                }

                if old_state^ == new_state do continue

                assert(curr_edge.subresource != prev_edge.subresource || curr_edge.render_pass_index != prev_edge.render_pass_index)

                append(&prev_pass.m_exit_barriers, cd3dx12_barrier_transition(resource_ptr, old_state^, new_state, curr_edge.subresource))

                old_state^ = new_state
            }

            for edge in node.edges 
            {
                pass := &m_render_passes[edge.render_pass_index]

                created := false
                for id in pass.m_created_resources { if id == resource_id do created = true }
                if !created do continue

                old_state := tracked_state[edge.subresource]
                new_state := edge.state

                if old_state == new_state do continue

                append(&pass.m_entry_barriers, cd3dx12_barrier_transition(resource_ptr, old_state, new_state, edge.subresource))
            }
        }
    }
}

gpu_rg_bind_render_targets :: proc(using in_graph : ^RenderGraph, in_device : ^GPUDevice, in_cmd_list : ^CommandList, render_pass : RenderPass)
{
    dsv_binding : DepthStencilBinding
    dsv_binding_ptr : ^DepthStencilBinding = nil

    rt_count : u32 = 0
    rt_bindings : [d3d12.SIMULTANEOUS_RENDER_TARGET_COUNT]RenderTargetBinding

    for resource_id in render_pass.m_written_resources
    {
        if type_of(in_graph.m_resources.m_resource_views[resource_id].m_id) == GPUBufferID {
            continue
        }

        texture := gpu_get_texture(in_device, gpu_rg_get_texture_view(&in_graph.m_resources, resource_id))

        switch texture.m_desc.usage 
        {
            case .RENDER_TARGET: 
            {
                rt_bindings[rt_count] = RenderTargetBinding { m_resource = texture.m_resource }
                rt_count += 1
            }
            case .DEPTH_STENCIL_TARGET:
            {
                assert(dsv_binding_ptr == nil)
                dsv_binding = DepthStencilBinding { m_resource = texture.m_resource }
                dsv_binding_ptr = &dsv_binding
            }
            case .GENERAL, .SHADER_READ_ONLY, .SHADER_READ_WRITE: break
        }
    }

    gpu_bind_render_targets(in_device, in_cmd_list, rt_bindings[:rt_count], dsv_binding_ptr)
}

gpu_rg_execute :: proc(using in_graph : ^RenderGraph, in_device : ^GPUDevice, in_cmd_list : ^CommandList, in_frame_counter : u64) 
{
    gpu_bind_device_defaults(in_device, in_cmd_list)

    for &render_pass in m_render_passes 
    {
        if barrier_count := len(render_pass.m_entry_barriers); barrier_count > 0 && in_frame_counter > 0 {
            in_cmd_list.m_cmds->ResourceBarrier(u32(barrier_count), raw_data(render_pass.m_entry_barriers))
        }

        if render_pass.m_kind == .GRAPHICS {
            gpu_rg_bind_render_targets(in_graph, in_device, in_cmd_list, render_pass)
        }

        exec_render_pass(in_device, in_cmd_list, &in_graph.m_resources, &render_pass.m_desc)

        if barrier_count := len(render_pass.m_exit_barriers); barrier_count > 0 {
            in_cmd_list.m_cmds->ResourceBarrier(u32(barrier_count), raw_data(render_pass.m_exit_barriers))
        }

        if render_pass.m_external {
            gpu_bind_device_defaults(in_device, in_cmd_list)
        }
    }
}

gpu_rg_get_buffer :: proc(resources : ^RenderGraphResources, id : RenderGraphResourceID) -> GPUBufferID
{
    return resources.m_resource_views[id].m_id.(GPUBufferID)
}

gpu_rg_get_buffer_view :: proc(resources : ^RenderGraphResources, id : RenderGraphResourceViewID) -> GPUBufferID
{
    return resources.m_resource_views[id].m_id.(GPUBufferID)
}

gpu_rg_get_texture :: proc(resources : ^RenderGraphResources, id : RenderGraphResourceID) -> GPUTextureID
{
    return resources.m_resources[id].m_id.(GPUTextureID)
}

gpu_rg_get_texture_view :: proc(resources : ^RenderGraphResources, id : RenderGraphResourceViewID) -> GPUTextureID
{
    return resources.m_resource_views[id].m_id.(GPUTextureID)
}

