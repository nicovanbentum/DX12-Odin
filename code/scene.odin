package main

import "core:os"
import "base:runtime"
import "core:strings"
import "core:encoding/json"

Entity :: bit_field u32
{
    valid : u32 | 1,
    index : u32 | 20,
    generation : u32 | 11
}

Name :: struct
{
    name : string
}

Transform :: struct
{
    scale : [3]f32,
    position : [3]f32,
    rotation : [4]f32,
    local_transform : matrix[4,4]f32,
    world_transform : matrix[4,4]f32
}

Mesh :: struct
{
    blas : u32,
    material : u32,
    index_buffer : u32,
    vertex_buffer : u32,
    positions : [dynamic][3]f32,
    texcoords : [dynamic][2]f32,
    normals   : [dynamic][3]f32,
    tangents  : [dynamic][3]f32,
    indices   : [dynamic]u32,
    vertices  : [dynamic]f32
}

Material :: struct
{
    albedo : [4]f32,
    emissive : [4]f32,
    metallic : f32,
    roughness : f32,
    alpha : AlphaMode,
    textures : [MaterialTextureKind]MaterialTexture
}

DefaultMaterial := Material {
    albedo = {1.0, 1.0, 1.0, 1.0},
    emissive = {0.0, 0.0, 0.0, 0.0},
    metallic = 0.0,
    roughness = 1.0,
    alpha = .NONE,
    textures = {}
}

AlphaMode :: enum
{
    NONE,
    MASKED,
    BLEND
}

MaterialTexture :: struct
{
    swizzle : u8,
    gpu_handle : u32,
    file_path : string
}

MaterialTextureKind :: enum
{
    ALBEDO, 
    NORMALS, 
    EMISSIVE, 
    METALLIC, 
    ROUGHNESS
}

ComponentArray :: struct($T : typeid)
{
    sparse : [dynamic]u32,
    entities : [dynamic]Entity,
    components : [dynamic]T
}

ComponentEnum :: enum {
    NAME,
    MESH,
    MATERIAL,
    TRANSFORM
}

ComponentEnumMap := map[typeid]ComponentEnum {
    typeid_of(Name) = .NAME,
    typeid_of(Mesh) = .MESH,
    typeid_of(Material) = .MATERIAL,
    typeid_of(Transform) = .TRANSFORM
}

ComponentMapEnum := [ComponentEnum]typeid {
    .NAME = typeid_of(Name),
    .MESH = typeid_of(Mesh),
    .MATERIAL = typeid_of(Material),
    .TRANSFORM = typeid_of(Transform)
}

AnyComponentArray :: union {
    ComponentArray(Name),
    ComponentArray(Mesh),
    ComponentArray(Material),
    ComponentArray(Transform)
}

Scene :: struct
{
    entity : Entity,
    using rt_scene : RayTracedScene,
    components : [ComponentEnum]AnyComponentArray
}

RayTracedScene :: struct
{
    tlas_buffer : GPUBufferID,
    lights_buffer : GPUBufferID,
    scratch_buffer : GPUBufferID,
    materials_buffer : GPUBufferID,
    instances_buffer : GPUBufferID,
    d3d12_instances_buffer : GPUBufferID
}

is_entity_valid :: proc(entity : Entity) -> bool {
    return entity.valid == 1
}

scene_destroy :: proc(scene : ^Scene)
{
}

scene_save_to_json :: proc(scene : ^Scene, file : string)
{
    str_builder : strings.Builder
    strings.builder_init(&str_builder)
    defer strings.builder_destroy(&str_builder)

    opts := json.Marshal_Options {
        spaces = 2,
        pretty = true,
        use_spaces = true,
        use_enum_names = true
    }

    json.marshal_to_builder(&str_builder, scene^, &opts)
    os.write_entire_file(file, str_builder.buf[:])
}

scene_open_from_json :: proc(scene : ^Scene, file : string)
{
    if file_data, ok := os.read_entire_file(file); ok {
        defer delete(file_data)
        json.unmarshal(file_data, scene)
    }
}

scene_create_entity :: proc(scene : ^Scene) -> Entity
{
    entity := scene.entity
    entity.valid = 1
    scene.entity.index += 1

    return entity
}

scene_has_entity :: proc(scene : ^Scene, entity : Entity) -> bool
{
    return entity.valid == 1 && entity.index < scene.entity.index
}

scene_has_component :: proc(scene : ^Scene, entity : Entity, $T : typeid) -> bool
{
    component_array := scene_get_component_array(scene, T)
    return component_array_contains(component_array, entity)
}

scene_get_component :: proc(scene : ^Scene, entity : Entity, $T : typeid) -> ^T
{
    component_array := scene_get_component_array(scene, T)
    return component_array_get(component_array, entity)
}

scene_add_component :: proc(scene : ^Scene, entity : Entity, $T : typeid, component : T) -> ^T
{
    component_array := scene_get_component_array(scene, T)
    component_array_insert(component_array, entity, component)

    return component_array_get(component_array, entity)
}

scene_get_component_array :: proc(scene : ^Scene, $T : typeid) -> ^ComponentArray(T)
{
    if scene.components[ComponentEnumMap[T]] == nil {
        scene.components[ComponentEnumMap[T]] = ComponentArray(T){}
    }

    any_component_array := &scene.components[ComponentEnumMap[T]]
    return &any_component_array.(ComponentArray(T))
}

scene_get_raw_index :: proc(scene : ^Scene, entity : Entity, $T : typeid) -> int
{
    component_array := scene_get_component_array(scene, T)

    if !component_array_contains(component_array, entity) {
        return -1
    }

    return int(component_array.sparse[entity])
}

component_array_get :: proc(array : ^ComponentArray($T), entity : Entity) -> ^T
{
    return &array.components[array.sparse[entity.index]]
}

component_array_contains :: proc(array : ^ComponentArray($T), entity : Entity) -> bool
{
    if entity.index >= u32(len(array.sparse)) {
        return false
    }
    if array.sparse[entity.index] >= u32(len(array.entities)) {
        return false
    }
    return array.entities[array.sparse[entity.index]] == entity
}

component_array_insert :: proc(array : ^ComponentArray($T), entity : Entity, component : T)
{
    if component_array_contains(array, entity)
{
        existing_component := component_array_get(array, entity)
        existing_component^ = component
        return
    }

    append(&array.entities, entity)

    if u32(len(array.sparse)) <= entity.index {
        resize(&array.sparse, int(entity.index + 1))
    }

    array.sparse[entity.index] = u32(len(array.entities) - 1)
    append(&array.components, component)
}
