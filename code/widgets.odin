package main

import "core:strings"
import "core:sys/windows"
import "third_party/imgui"

Vertex :: struct 
{
    pos     : [3]f32,
    uv      : [2]f32,
    normal  : [3]f32,
    tangent : [3]f32
}

Triangle :: struct
{
    i0, i1, i2 : u32
}

imgui_draw_menubar :: proc(app : ^App, active_entity : ^Entity) 
{
    if imgui.BeginMainMenuBar() 
    {
        defer imgui.EndMainMenuBar()

        if imgui.BeginMenu("File")
        {
            defer imgui.EndMenu()

            if imgui.MenuItem("New scene") {}

            if imgui.MenuItem("Open scene..")
            {
                if file_path, ok := os_save_file_dialog(windows.L("JSON File (*.json)\x00"), windows.L("json")); ok {
                    scene_open_from_json(&app.m_scene, file_path)
                }
            }

            if imgui.MenuItem("Save scene..", "CTRL + S")
            {
                if file_path, ok := os_save_file_dialog(windows.L("JSON File (*.json)\x00"), windows.L("json")); ok {
                    scene_save_to_json(&app.m_scene, file_path)
                }
            }

            if imgui.MenuItem("Import scene..") {}

            if imgui.BeginMenu("Recent scenes")
            {
                defer imgui.EndMenu()
            }

            if imgui.MenuItem("Save screenshot..") {}

            if imgui.MenuItem("Exit", "Escape") {}
        }

        if imgui.BeginMenu("Edit")
        {
            defer imgui.EndMenu()

            if imgui.MenuItem("Delete", "DELETE") {}
            if imgui.MenuItem("Duplicate", "CTRL+D") {}
        }

        if imgui.BeginMenu("Window") 
        {
            defer imgui.EndMenu()
        }

        if imgui.BeginMenu("Add")
        {
            defer imgui.EndMenu()

            if imgui.MenuItem("Empty", "CTRL+E")
            {
                new_entity := scene_create_entity(&app.m_scene)
                scene_add_component(&app.m_scene, new_entity, Name, Name{}).name = "New Entity"
                scene_add_component(&app.m_scene, new_entity, Transform, Transform{})
                active_entity^ = new_entity
            }

            imgui.Separator()

            if imgui.MenuItem("Material")
            {
                new_entity := scene_create_entity(&app.m_scene)
                new_entity_name := scene_add_component(&app.m_scene, new_entity, Name, Name{})
                new_entity_material := scene_add_component(&app.m_scene, new_entity, Material, Material{})
                new_entity_name.name = "Material"
            }

            imgui.Separator()

            if imgui.BeginMenu("Shapes")
            {
                defer imgui.EndMenu()

                if imgui.MenuItem("Cube")
                {
                    new_entity := scene_create_entity(&app.m_scene)
                    new_entity_mesh := scene_add_component(&app.m_scene, new_entity, Mesh, Mesh{})
                    new_entity_name := scene_add_component(&app.m_scene, new_entity, Name, Name{})
                    new_entity_transform := scene_add_component(&app.m_scene, new_entity, Transform, Transform{})

                    new_entity_name.name = "New Cube"

                    vertices := [8]Vertex {
                        Vertex{{-0.5, -0.5,  0.5}, {}, {}, {}},
                        Vertex{{ 0.5, -0.5,  0.5}, {}, {}, {}},
                        Vertex{{ 0.5,  0.5,  0.5}, {}, {}, {}},
                        Vertex{{-0.5,  0.5,  0.5}, {}, {}, {}},
                        Vertex{{-0.5, -0.5, -0.5}, {}, {}, {}},
                        Vertex{{ 0.5, -0.5, -0.5}, {}, {}, {}},
                        Vertex{{ 0.5,  0.5, -0.5}, {}, {}, {}},
                        Vertex{{-0.5,  0.5, -0.5}, {}, {}, {}}
                    }

                    triangles := [12]Triangle {
                        Triangle{0, 1, 2}, Triangle{2, 3, 0},
                        Triangle{1, 5, 6}, Triangle{6, 2, 1},
                        Triangle{7, 6, 5}, Triangle{5, 4, 7},
                        Triangle{4, 0, 3}, Triangle{3, 7, 4},
                        Triangle{4, 5, 1}, Triangle{1, 0, 4},
                        Triangle{3, 2, 6}, Triangle{6, 7, 3}
                    }
                    
                    for vertex in vertices {
                        append(&new_entity_mesh.positions, vertex.pos)
                        append(&new_entity_mesh.texcoords, vertex.uv)
                        append(&new_entity_mesh.normals, vertex.normal)
                    }

                    for triangle in triangles {
                        append(&new_entity_mesh.indices, triangle.i0)
                        append(&new_entity_mesh.indices, triangle.i1)
                        append(&new_entity_mesh.indices, triangle.i2)
                    }

                    gpu_create_mesh_buffers(&app.m_device, new_entity_mesh, new_entity)
                    append(&app.m_renderer.m_pending_mesh_uploads, new_entity)
                }
            }
        }

        if imgui.BeginMenu("Tools")
        {
            defer imgui.EndMenu()
        }

        if imgui.BeginMenu("Help")
        {
            defer imgui.EndMenu()
        }
    }
}

imgui_draw_outliner :: proc(entity : Entity, scene : ^Scene, active_entity : ^Entity)
{
    open := true
    imgui.Begin("Outliner", &open)
    defer imgui.End()

    for index in 0..<scene.entity.index 
    {
        entity := Entity { valid = 1, index = index }

        imgui.PushIDInt(i32(entity))
        defer imgui.PopID()

        name := scene_get_component(scene, entity, Name)

        if imgui.Selectable(strings.clone_to_cstring(name.name, context.temp_allocator), active_entity^ == entity) {
            active_entity^ = entity
        }
    }

    imgui.Separator()

    imgui.Text("Entity: %i , %i, %i", active_entity.valid, active_entity.index, active_entity.generation)

    imgui.Separator()

    if active_entity.index < scene.entity.index 
    {
        for &component_array in scene.components 
        {
            draw_entity_component(active_entity^, &component_array)
        }
    }

    imgui.Separator()

    if imgui.Button("Add Component", {imgui.GetWindowWidth(), 0}) {

    }
}

draw_name_component :: proc(entity : Entity, name : ^Name)
{
    if !imgui.CollapsingHeader("Name", {.DefaultOpen}) do return

    if imgui.BeginTable("##NameTable", 2, imgui.TableFlags_SizingStretchProp | imgui.TableFlags_BordersInnerV) 
    {
        defer imgui.EndTable()
        imgui.TableNextColumn()
        imgui.AlignTextToFramePadding()
        imgui.Text("Name")
        imgui.TableNextColumn()
        imgui.Text(strings.clone_to_cstring(name.name, context.temp_allocator))
    }
}

draw_transform_component :: proc(entity : Entity, transform : ^Transform)
{
    if !imgui.CollapsingHeader("Transform", {.DefaultOpen}) do return

    imgui.DragFloat3("Scale", &transform.scale)
    imgui.DragFloat3("Position", &transform.position)
}

draw_mesh_component :: proc(entity : Entity, mesh : ^Mesh)
{
    if !imgui.CollapsingHeader("Mesh", {.DefaultOpen}) do return

    byte_size := size_of(Mesh) + size_of(Vertex) * len(mesh.positions)

    imgui.Text("%i.1f Kb", f32(byte_size) / 1024)
    imgui.Text("%i Vertices", len(mesh.positions))
    imgui.Text("%i Triangles", len(mesh.indices) / 3)
}

draw_material_component :: proc(entity : Entity, material : ^Material)
{
    if !imgui.CollapsingHeader("Material", {.DefaultOpen}) do return

    imgui.ColorEdit4("Albedo", &material.albedo, {.Float, .HDR})
    imgui.ColorEdit4("Emissive", &material.emissive, {.Float, .HDR})

    imgui.DragFloat("Metallic", &material.metallic, 0.001, 0.0, 1.0)
    imgui.DragFloat("Roughness", &material.roughness, 0.001, 0.0, 1.0)

    texture_labels := [MaterialTextureKind]cstring {
        .ALBEDO = "Albedo Map       ",
        .NORMALS = "Normal Map       ",
        .EMISSIVE = "Emissive Map    ",
        .METALLIC = "Metallic Map      ",
        .ROUGHNESS = "Roughness Map",
    }

    for &texture, index in material.textures {
        imgui.Text(texture_labels[index])
        imgui.SameLine()

        if imgui.Button("load..") {}
        imgui.SameLine()

        file_text := len(texture.file_path) > 0 ? texture.file_path : "N/A"
        tooltip_text := len(texture.file_path) > 0 ? texture.file_path : "No File Loaded"

        temp_file_text := strings.clone_to_cstring(file_text, context.temp_allocator)
        temp_tooltip_text := strings.clone_to_cstring(tooltip_text, context.temp_allocator)

        imgui.Text(temp_file_text)
        if imgui.IsItemHovered() do imgui.SetTooltip(temp_tooltip_text)
    }
}

draw_entity_component :: proc(entity : Entity, any_component_array : ^AnyComponentArray)
{
    switch &array in any_component_array {
        case ComponentArray(Name) : if component_array_contains(&array, entity) do draw_name_component(entity, component_array_get(&array, entity))
        case ComponentArray(Mesh) : if component_array_contains(&array, entity) do draw_mesh_component(entity, component_array_get(&array, entity))
        case ComponentArray(Material) : if component_array_contains(&array, entity) do draw_material_component(entity, component_array_get(&array, entity))
        case ComponentArray(Transform) : if component_array_contains(&array, entity) do draw_transform_component(entity, component_array_get(&array, entity))
    }
}