package ui

import "core:testing"
import "core:time"
import "base:intrinsics"
import js "../js"
import im "../../vendor/imgui"

when ODIN_OS == .Windows {
    @(require) foreign import _loading_test_sdl "../../vendor/imgui/backend_deps/SDL2-bin/SDL2.lib"
}

loading_test_frame :: proc(s: ^State, x, y: f32, down: bool) {
    io := im.GetIO()
    im.IO_AddMousePosEvent(io, x, y)
    im.IO_AddMouseButtonEvent(io, 0, down)
    im.NewFrame()
    draw_browser(s)
    im.Render()
}

// Runs in its own process: exercising NewFrame changes ImGui's font caches,
// while the unit suite contains synthetic fonts without a real atlas.
when #config(LOADING_INTEGRATION_TEST, false) {
@(test)
loading_page_allows_real_tab_widgets :: proc(t: ^testing.T) {
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    im.SetCurrentContext(ctx)
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    defer shaped_text_clear()
    defer text_metrics_clear()
    io := im.GetIO()
    io.IniFilename = nil
    io.DisplaySize = {1280, 800}
    io.DeltaTime = 1.0 / 60
    apply_style()
    previous_big, previous_ui := g_font_big, g_font_ui
    defer { g_font_big = previous_big; g_font_ui = previous_ui }
    font := im.FontAtlas_AddFontDefault(io.Fonts)
    g_font_big, g_font_ui = font, font
    testing.expect(t, im.FontAtlas_Build(io.Fonts))

    s: State
    defer delete(s.tabs)
    append(&s.tabs, make_tab("Loading"), make_tab("Other tab"))
    start_navigation(&s, `data:text/html,<script>var end=Date.now()+1000;while(Date.now()<end){}</script><body></body>`)
    testing.expect(t, len(g_jobs) == 1)
    defer {
        for len(g_jobs) > 0 {
            if !bool(intrinsics.atomic_load(&g_jobs[0].done)) {
                time.sleep(time.Millisecond)
                continue
            }
            poll_jobs(&s)
        }
    }
    // Settle hover and focus, then press/release the actual second tab widget.
    loading_test_frame(&s, 300, 1, false)
    loading_test_frame(&s, 300, 1, false)
    loading_test_frame(&s, 300, 1, true)
    loading_test_frame(&s, 300, 1, false)
    testing.expect_value(t, s.active, 1)

    // Return to the loading tab and click the actual + widget.
    loading_test_frame(&s, 100, 20, false)
    loading_test_frame(&s, 100, 20, true)
    loading_test_frame(&s, 100, 20, false)
    testing.expect_value(t, s.active, 0)
    loading_test_frame(&s, 466, 1, false)
    loading_test_frame(&s, 466, 1, true)
    loading_test_frame(&s, 466, 1, false)
    testing.expect_value(t, len(s.tabs), 3)
    testing.expect_value(t, s.active, 2)
    testing.expect(t, s.tabs[0].loading, "the worker must still be loading while real tab widgets respond")
    for !bool(intrinsics.atomic_load(&g_jobs[0].done)) do time.sleep(time.Millisecond)
    poll_jobs(&s)
    testing.expect(t, !s.tabs[0].loading)
    testing.expect_value(t, s.tabs[0].style_vw, f32(1280))
    testing.expect_value(t, s.tabs[0].style_vh, f32(690))
    testing.expect(t, !tab_needs_restyle(&s.tabs[0], 1280, 690),
        "the first frame must reuse the worker cascade instead of computing the page twice")
    s.active = 0
    loading_test_frame(&s, -1, -1, false)
    testing.expect_value(t, s.tabs[0].style_vw, f32(1280))
    testing.expect_value(t, s.tabs[0].style_vh, f32(690))
    testing.expect_value(t, s.tabs[0].restyle_nodes, 0)
}
}

@(test)
new_tab_remains_available_after_busy_page_turn :: proc(t: ^testing.T) {
    previous_id, previous_focus := g_next_tab_id, g_focus_url
    defer { g_next_tab_id = previous_id; g_focus_url = previous_focus }
    s: State
    defer delete(s.tabs)
    vm := js.vm_create()
    defer js.vm_free(vm)
    first := make_tab("Busy page")
    first.vm = vm
    first.url = "https://example.test/"
    append(&s.tabs, first)
    js.vm_run(vm, `setTimeout(function(){while(true){}}, 0);`)
    js.vm_begin_host_turn(vm, 20)
    js.vm_pump_timers(vm, 0)
    js.vm_end_host_turn(vm)

    s.url_buf[0] = 'x'
    s.autoscroll.on = true
    open_new_tab(&s)
    testing.expect_value(t, len(s.tabs), 2)
    testing.expect_value(t, s.active, 1)
    testing.expect_value(t, s.tabs[0].id, first.id)
    testing.expect_value(t, s.tabs[0].vm, vm)
    testing.expect(t, s.tabs[1].id != first.id)
    testing.expect_value(t, s.tabs[1].url, "")
    testing.expect_value(t, s.url_buf[0], u8(0))
    testing.expect(t, g_focus_url && !s.autoscroll.on)

    // Download jobs also must not prevent opening another tab.
    s.tabs[0].loading = true
    s.active = 0
    open_new_tab(&s)
    testing.expect_value(t, len(s.tabs), 3)
    testing.expect_value(t, s.active, 2)
    testing.expect(t, s.tabs[0].loading)
}
