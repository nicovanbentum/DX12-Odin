package main

import "core:fmt"
import "core:thread"

RK_CONVERT :: #config(RK_CONVERT, false)

g_thread_pool : thread.Pool

main :: proc() 
{
    thread.pool_init(&g_thread_pool, context.allocator, 4)
    defer thread.pool_destroy(&g_thread_pool)

    app := App { m_running = true }

    if !app_init(&app) do panic("Failed to initialize app")

    app_run(&app)
    
    app_deinit(&app)
}