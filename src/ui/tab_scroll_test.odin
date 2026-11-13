package ui

import "core:testing"
import "core:time"
import "base:intrinsics"
import im "../../vendor/imgui"

// draw_browser puxa o backend SDL do ImGui: sem o SDL2.lib o link do teste falha
// (SDL_RenderGeometryRaw).
when ODIN_OS == .Windows {
    @(require) foreign import _tab_scroll_test_sdl "../../vendor/imgui/backend_deps/SDL2-bin/SDL2.lib"
}

// Scroll da página é POR ABA. O ImGui guarda o scroll na janela, indexada pelo ID;
// com um "##viewport" único para todas as abas, rolar uma rolava as outras.
//
// UM teste só, de propósito: dois testes seguidos que carregam página pelo
// fetch_worker derrubam o segundo com Segmentation_Fault dentro do
// load_page_scripts (estado global da VM entre testes — problema anterior a este
// teste, não investigado). A página não tem TEXTO: texto exige o atlas de
// fontes do conteúdo (setup_fonts), que o contexto de teste não monta.

@(private = "file")
tab_scroll_frame :: proc(s: ^State, wheel: f32 = 0) {
    io := im.GetIO()
    im.IO_AddMousePosEvent(io, 640, 400) // sobre o viewport
    if wheel != 0 do im.IO_AddMouseWheelEvent(io, 0, wheel)
    im.NewFrame()
    draw_browser(s)
    im.Render()
}

@(private = "file")
tab_scroll_settle :: proc(s: ^State) {
    for _ in 0..<60 do tab_scroll_frame(s) // 1 s a 60 fps: a roda suave (τ=50 ms) termina
}

@(private = "file")
tab_scroll_y :: proc() -> f32 {
    _, y := js_scroll_get() // o scroll do viewport ativo, gravado no frame
    return y
}

@(test)
page_scroll_is_per_tab :: proc(t: ^testing.T) {
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    io := im.GetIO()
    io.IniFilename = nil
    io.DisplaySize = {1280, 800}
    io.DeltaTime = 1.0 / 60
    apply_style()
    im.FontAtlas_AddFontDefault(io.Fonts)
    testing.expect(t, im.FontAtlas_Build(io.Fonts))

    s: State
    defer delete(s.tabs)
    append(&s.tabs, make_tab("A"), make_tab("B"))
    TALL :: `data:text/html,<body style="margin:0"><div style="height:6000px"></div></body>`
    s.active = 0; start_navigation(&s, TALL)
    s.active = 1; start_navigation(&s, TALL)
    for len(g_jobs) > 0 {
        if !bool(intrinsics.atomic_load(&g_jobs[0].done)) {
            time.sleep(time.Millisecond)
            continue
        }
        poll_jobs(&s)
    }
    testing.expect(t, !s.tabs[0].loading && !s.tabs[1].loading)

    // 1) rola a aba A
    s.active = 0
    tab_scroll_settle(&s)
    tab_scroll_frame(&s, -5) // 5 cliques p/ baixo
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 5 * WHEEL_STEP_PX)

    // 2) a aba B não foi rolada: abre no topo
    s.active = 1
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), f32(0))

    // 3) rola B; A volta exatamente onde estava, e B também
    tab_scroll_frame(&s, -2)
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 2 * WHEEL_STEP_PX)
    s.active = 0
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 5 * WHEEL_STEP_PX)
    s.active = 1
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 2 * WHEEL_STEP_PX)

    // 4) âncora (#id) pedida em A, mas o usuário troca p/ B antes de ela ser
    // aplicada: não pode rolar B, e A continua onde estava.
    s.active = 0
    tab_scroll_settle(&s)
    s.scroll_pending = true
    s.scroll_target = 3000
    s.scroll_smooth = true
    s.scroll_tab = s.tabs[0].id
    s.active = 1
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 2 * WHEEL_STEP_PX)
    testing.expect(t, !s.scroll_pending, "a âncora de outra aba é descartada")
    s.active = 0
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), 5 * WHEEL_STEP_PX)

    // 5) controle: a mesma âncora NA aba dona é aplicada (o descarte acima não
    // é o caminho da âncora quebrado)
    s.scroll_pending = true
    s.scroll_target = 3000
    s.scroll_smooth = false
    s.scroll_tab = s.tabs[0].id
    tab_scroll_settle(&s)
    testing.expect_value(t, tab_scroll_y(), f32(3000))
}
