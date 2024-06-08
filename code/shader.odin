package main

import "core:os"
import "core:fmt"
import "core:thread"
import "core:strings"
import "core:sys/windows"
import "core:encoding/json"
import "vendor:directx/dxc"

SystemShaders :: enum 
{
    CLEAR_BUFFER_SHADER,
    CLEAR_TEXTURE_SHADER,
    SKY_CUBE_SHADER,
    CONVOLVE_CUBE_SHADER,
    IMGUI_SHADER,
    GRASS_SHADER,
    GBUFFER_SHADER,
    SKINNING_SHADER,
    LIGHTING_SHADER,
    LIGHT_CULL_SHADER,
    DOWNSAMPLE_SHADER,
    TAA_RESOLVE_SHADER,
    FINAL_COMPOSE_SHADER,
    DEBUG_PRIMITIVES_SHADER,
    PROBE_DEBUG_SHADER,
    PROBE_DEBUG_RAYS_SHADER,
    PROBE_TRACE_SHADER,
    PROBE_SAMPLE_SHADER,
    PROBE_UPDATE_DEPTH_SHADER,
    PROBE_UPDATE_IRRADIANCE_SHADER,
    RT_REFLECTIONS_SHADER,
    RT_PATH_TRACE_SHADER,
    RT_AMBIENT_OCCLUSION_SHADER,
    TRACE_SHADOW_RAYS_SHADER,
    CLEAR_SHADOW_TILES_SHADER,
    CLASSIFY_SHADOW_TILES_SHADER,
    DENOISE_SHADOW_TILES_SHADER,
    GBUFFER_DEBUG_DEPTH_SHADER,
    GBUFFER_DEBUG_ALBEDO_SHADER,
    GBUFFER_DEBUG_NORMALS_SHADER,
    GBUFFER_DEBUG_EMISSIVE_SHADER,
    GBUFFER_DEBUG_METALLIC_SHADER,
    GBUFFER_DEBUG_ROUGHNESS_SHADER,
    GBUFFER_DEBUG_VELOCITY_SHADER,
    BLOOM_UPSCALE_SHADER,
    BLOOM_DOWNSCALE_SHADER,
    DEPTH_OF_FIELD_SHADER
}

ShaderKind :: enum
{
    SHADER_VERTEX,
    SHADER_PIXEL,
    SHADER_COMPUTE
}

ShaderProfile :: [ShaderKind]string {
    .SHADER_VERTEX = "vs_6_6",
    .SHADER_PIXEL = "ps_6_6",
    .SHADER_COMPUTE = "cs_6_6"
}

ShaderProgram :: struct 
{
    m_name : string,
    m_defines : string,
    m_vertex_shader_file : string,
    m_pixel_shader_file : string,
    m_compute_shader_file : string
}

ShaderProgramKind :: enum 
{
    SHADER_PROGRAM_INVALID = 0,
    SHADER_PROGRAM_GRAPHICS,
    SHADER_PROGRAM_COMPUTE
}

CompiledShaderProgram :: struct 
{
    m_name : string,
    m_kind : ShaderProgramKind,
    m_vertex_shader_blob : [dynamic]u8,
    m_pixel_shader_blob : [dynamic]u8,
    m_compute_shader_blob : [dynamic]u8
}

g_compiled_shaders : [SystemShaders]CompiledShaderProgram

compile_shader_dxc :: proc(in_filepath : string, in_defines : string, in_kind : ShaderKind, in_source : []byte) -> ^dxc.IBlob
{
    utils : ^dxc.IUtils = nil
    library : ^dxc.ILibrary = nil
    compiler : ^dxc.ICompiler3 = nil
    panic_if_failed(dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, &utils))
    panic_if_failed(dxc.CreateInstance(dxc.Library_CLSID, dxc.ILibrary_UUID, &library))
    panic_if_failed(dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, &compiler))

    include_handler : ^dxc.IIncludeHandler = nil
    panic_if_failed(utils->CreateDefaultIncludeHandler(&include_handler))

    blob : ^dxc.IBlobEncoding = nil
    panic_if_failed(library->CreateBlobWithEncodingFromPinned(&in_source[0], u32(len(in_source)), u32(dxc.CP_UTF8), &blob))

    src_buffer := dxc.Buffer {
        Ptr = blob->GetBufferPointer(), 
        Size = blob->GetBufferSize()
    }

    args := make([dynamic]dxc.wstring, 0, 13)
    defer delete(args)

    shader_profiles := ShaderProfile
    
    append(&args, windows.L("-E"))
    append(&args, windows.L("main"))
    
    append(&args, windows.L("-T"))
    append(&args, windows.utf8_to_wstring(shader_profiles[in_kind]))

    append(&args, windows.L("cs_6_6"))
    
    append(&args, windows.L("-Zi"))
    
    append(&args, windows.L("-I"))
    append(&args, windows.L("assets/system/shaders"))
    
    append(&args, windows.L("-HV"))
    append(&args, windows.L("2021"))
    
    append(&args, windows.L("-Zss"))
    append(&args, windows.utf8_to_wstring(in_filepath))

    append(&args, windows.L("-P"))
    append(&args, windows.L("temp.hlsl")) // I don't see the file being written anywhere and for some reason -P doesnt need an argument in C++, weird
    
    pp_result : ^dxc.IResult
    panic_if_failed(compiler->Compile(&src_buffer, &args[0], u32(len(args)), include_handler, dxc.IResult_UUID, &pp_result))

    hr_status : dxc.HRESULT
    panic_if_failed(pp_result->GetStatus(&hr_status))

    if !windows.SUCCEEDED(hr_status) 
    {
        errors : ^dxc.IBlobUtf8
        panic_if_failed(pp_result->GetOutput(.ERRORS, dxc.IBlobUtf8_UUID, &errors, nil))

        if errors != nil && errors->GetStringLength() > 0 
        {
            error_str := strings.string_from_null_terminated_ptr((^u8)(errors->GetBufferPointer()), int(errors->GetBufferSize()))
            fmt.println(error_str)
        }
    }

    preprocessed_hlsl : ^dxc.IBlobUtf8 = nil
    panic_if_failed(pp_result->GetOutput(.HLSL, dxc.IBlobUtf8_UUID, &preprocessed_hlsl, nil))

    hlsl_buffer := dxc.Buffer {
        Ptr = preprocessed_hlsl->GetBufferPointer(),
        Size = preprocessed_hlsl->GetBufferSize()
    }

    // pop off the -P arguments
    pop(&args)
    pop(&args)

    result : ^dxc.IResult
    panic_if_failed(compiler->Compile(&hlsl_buffer, &args[0], u32(len(args)), include_handler, dxc.IResult_UUID, &result))

    errors : ^dxc.IBlobUtf8
    panic_if_failed(result->GetOutput(.ERRORS, dxc.IBlobUtf8_UUID, &errors, nil))

    if errors != nil && errors->GetStringLength() > 0 
    {
        error_str := strings.string_from_null_terminated_ptr((^u8)(errors->GetBufferPointer()), int(errors->GetBufferSize()))
        fmt.println(error_str)
    }

    shader, pdb : ^dxc.IBlob
    debug_data : ^dxc.IBlobUtf16
    hr_status = result.GetOutput(result, .PDB, dxc.IBlob_UUID, &pdb, &debug_data)
    hr_status = result.GetOutput(result, .OBJECT, dxc.IBlob_UUID, &shader, &debug_data)

    if !windows.SUCCEEDED(hr_status) 
    {
        fmt.println("Compilation for shader failed");
        return nil;
    }

    fmt.printfln("Compiled shader %s successfully.", in_filepath)

    return shader;
}

compile_shader :: proc(in_filepath : string, in_defines : string, in_kind : ShaderKind) -> [dynamic]u8
{
    bin : [dynamic]u8 = nil
    dxc_blob : ^dxc.IBlob

    if data, ok := os.read_entire_file(in_filepath); ok {
        defer delete(data)
        dxc_blob = compile_shader_dxc(in_filepath, in_defines, in_kind, data)
    }

    // TODO

    return bin
}

 TaskCompileShaderProgram :: struct 
 {
    m_shader : ^ShaderProgram,
    m_compiled_shader : ^CompiledShaderProgram
 }

compile_system_shaders :: proc()
{
    SHADERS_BIN :: "assets/system/shaders/shaders.bin"
    SHADERS_JSON :: "assets/system/shaders/shaders.json"

    text_shaders : [SystemShaders]ShaderProgram
    combined_shader_tasks : [SystemShaders]TaskCompileShaderProgram

    /* when !RK_FINAL 
    {
        //compiled_shaders = #load(SHADERS_BIN)
    } 
    else */
    {
        if data, ok := os.read_entire_file(SHADERS_JSON); ok {
            defer delete(data)
            json.unmarshal(data, &text_shaders)
        }
    
        for &text_shader, index in text_shaders 
        {
            compiled_shader := &g_compiled_shaders[index]
            compiled_shader.m_name = text_shader.m_name

            task_data := &combined_shader_tasks[index]
            task_data.m_shader = &text_shader
            task_data.m_compiled_shader = compiled_shader
            
            if text_shader.m_pixel_shader_file != "" && text_shader.m_vertex_shader_file != "" {
                compiled_shader.m_kind = .SHADER_PROGRAM_GRAPHICS
            }
            else if text_shader.m_compute_shader_file != "" {
                compiled_shader.m_kind = .SHADER_PROGRAM_COMPUTE
            }
            
            if compiled_shader.m_kind == .SHADER_PROGRAM_INVALID do continue

            task_proc :: proc(in_task : thread.Task) 
            {
                task_data := (^TaskCompileShaderProgram)(in_task.data)
                using task_data

                if m_shader.m_pixel_shader_file != "" do m_compiled_shader.m_pixel_shader_blob = compile_shader(m_shader.m_pixel_shader_file, m_shader.m_defines, .SHADER_PIXEL)
                if m_shader.m_vertex_shader_file != "" do m_compiled_shader.m_vertex_shader_blob = compile_shader(m_shader.m_vertex_shader_file, m_shader.m_defines, .SHADER_VERTEX)
                if m_shader.m_compute_shader_file != "" do m_compiled_shader.m_compute_shader_blob = compile_shader(m_shader.m_compute_shader_file, m_shader.m_defines, .SHADER_COMPUTE)
            }

            thread.pool_add_task(&g_thread_pool, context.allocator, task_proc, rawptr(&combined_shader_tasks[index]), int(index))
        }

        thread.pool_start(&g_thread_pool)
        thread.pool_finish(&g_thread_pool)

        str_builder : strings.Builder
        strings.builder_init(&str_builder)
        defer strings.builder_destroy(&str_builder)

        opts := json.Marshal_Options {
            pretty = true,
            spaces = 2
        }

        json.marshal_to_builder(&str_builder, g_compiled_shaders, &opts)
        os.write_entire_file(SHADERS_BIN, str_builder.buf[:])
    }
}