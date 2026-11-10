package ui

import "core:testing"
import im "../../vendor/imgui"
import htmlp "../html"
import csspkg "../css"

// Larguras conhecidas: não dependem das fontes do Windows nem de um renderer.
// CalcTextSizeA lê IndexAdvanceX; os testes exercitam o layout de produção.
@(private="file")
ts_inline :: proc(font: ^im.Font, mode: Font_Kerning = .None) -> ^Box {
    b := new(Box)
    b.is_inline = true; b.width_mc = true
    append(&b.inlines, Inline_Item{kind = .Word, text = "AV", font = font,
        fsize = 20, em = 1, lh = 1, font_kerning = mode})
    return b
}

@(test)
test_typography_kerning_style_inheritance :: proc(t: ^testing.T) {
    testing.expect_value(t, test_apply("font-kerning:normal").font_kerning, Font_Kerning.Normal)
    testing.expect_value(t, test_apply("font-kerning:none").font_kerning, Font_Kerning.None)
    testing.expect_value(t, test_apply("font-kerning:garbage").font_kerning, Font_Kerning.Auto)
    testing.expect_value(t, test_compute_child(".g{font-kerning:none}").font_kerning, Font_Kerning.None)
    testing.expect_value(t, test_compute_child(".g{font-kerning:none}.i{font-kerning:initial}").font_kerning, Font_Kerning.Auto)
    testing.expect_value(t, test_compute_child(".g{font-kerning:none}.i{font:20px serif}").font_kerning, Font_Kerning.Auto)
    testing.expect(t, css_supports_decl("font-kerning", "normal"))
    testing.expect(t, !css_supports_decl("font-kerning", "garbage"))
}

@(test)
test_typography_real_sfnt_kerning_matches_layout :: proc(t: ^testing.T) {
    data := #load("../../vendor/imgui/imgui/misc/fonts/Roboto-Medium.ttf")
    testing.expect(t, len(data) > 0)
    if len(data) == 0 do return
    defer g_kern_cache = {}
    cfg := im.FontConfig{FontData = raw_data(data), FontDataSize = i32(len(data))}
    advances: [128]f32
    for &a in advances do a = 10
    f := im.Font{FontSize = 20, Sources = &cfg, SourcesCount = 1,
        IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
    k := text_pair_kerning(&f, 20, 'A', 'V', .Normal)
    testing.expect(t, k < 0, "a fixture Roboto deve conter o par AV negativo")
    testing.expect(t, text_pair_kerning(&f, 20, 'A', 'V', .None) == 0)
    testing.expect(t, abs(text_pair_kerning(&f, 40, 'A', 'V', .Normal) - 2*k) < 0.001)
    normal := ts_inline(&f, .Normal)
    layout_box(normal, 0, 0, 300)
    none := ts_inline(&f, .None)
    layout_box(none, 0, 0, 300)
    testing.expect(t, abs(normal.w - (20+k)) < 0.001)
    testing.expect(t, none.w == 20)
    testing.expect(t, text_pair_kerning(nil, 20, 'A', 'V', .Normal) == 0)
    // As strings destes itens são literais; free_layout as liberaria.
    delete(normal.inlines); free(normal)
    delete(none.inlines); free(none)
}

@(test)
test_typography_kerning_uses_real_atlas_sources :: proc(t: ^testing.T) {
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    defer text_metrics_clear()
    data := #load("../../vendor/imgui/imgui/misc/fonts/Roboto-Medium.ttf")
    cfg := im.FontConfig{FontDataOwnedByAtlas = false, OversampleH = 2, OversampleV = 1,
        GlyphMaxAdvanceX = 3.4028235e38, RasterizerMultiply = 1, RasterizerDensity = 1}
    font := im.FontAtlas_AddFontFromMemoryTTF(im.GetIO().Fonts, raw_data(data), i32(len(data)), 20, &cfg)
    testing.expect(t, im.FontAtlas_Build(im.GetIO().Fonts))
    testing.expect(t, text_has_kerning(font, 20, "AV", .Normal), "a fonte REAL do atlas precisa expor os pares")
    normal := ts_inline(font, .Normal)
    none := ts_inline(font, .None)
    layout_box(normal, 0, 0, 300)
    layout_box(none, 0, 0, 300)
    testing.expectf(t, normal.w < none.w, "kerning tem efeito na largura: normal %v, none %v", normal.w, none.w)
    delete(normal.inlines); free(normal)
    delete(none.inlines); free(none)
}

@(test)
test_typography_intrinsic_space_uses_font_advance :: proc(t: ^testing.T) {
    advances: [128]f32
    for &a in advances do a = 10
    advances[' '] = 6
    f := im.Font{FontSize = 20, IndexAdvanceX = {Size = 128, Capacity = 128, Data = &advances[0]}}
    b := ts_inline(&f)
    append(&b.inlines, Inline_Item{kind = .Word, text = "AV", font = &f,
        fsize = 20, em = 1, lh = 1, font_kerning = .None, space_before = true})
    b.word_spacing = 3
    layout_box(b, 0, 0, 300)
    testing.expectf(t, b.w == 49, "20 + espaço 6 + word-spacing 3 + 20 = 49; veio %v", b.w)
    delete(b.inlines); free(b)
    text_metrics_clear() // não manter ponteiro para a fonte na pilha
}

@(private="file")
ts_sized :: proc(minc, fit: bool, avail: f32) -> f32 {
    b := Box{is_inline = true, width_mc = true, width_minc = minc, width_fit = fit,
        padding = {0, 5, 0, 5}}
    append(&b.inlines, Inline_Item{kind = .Word, text_w = 40, fsize = 20, lh = 1})
    append(&b.inlines, Inline_Item{kind = .Word, text_w = 70, fsize = 20, lh = 1, space_before = true})
    defer delete(b.inlines)
    layout_box(&b, 0, 0, avail)
    return b.w
}

@(test)
test_sizing_min_max_fit_content :: proc(t: ^testing.T) {
    testing.expect(t, ts_sized(true, false, 300) == 80, "min-content = palavra 70 + padding 10")
    testing.expect(t, abs(ts_sized(false, false, 300) - 125.6) < 0.001)
    testing.expect(t, ts_sized(false, true, 100) == 100, "fit-content usa o disponível entre os extremos")
    testing.expect(t, ts_sized(false, true, 30) == 80, "fit-content não reduz a palavra indivisível")
    testing.expect(t, abs(ts_sized(false, true, 300) - 125.6) < 0.001)
}

@(test)
test_sizing_grid_row_measures_wrapped_intrinsic_item :: proc(t: ^testing.T) {
    grid := Box{is_grid = true, grid_track_n = 1, gap = 8, row_gap = 8}
    grid.grid_tracks[0] = {kind = .Fixed, value = 220}
    item := Box{is_inline = true, width_mc = true, width_minc = true}
    append(&item.inlines, Inline_Item{kind = .Word, text_w = 40, fsize = 20, lh = 1})
    append(&item.inlines, Inline_Item{kind = .Word, text_w = 70, fsize = 20, lh = 1, space_before = true})
    next := Box{has_height = true, height = 10}
    append(&grid.children, &item, &next)
    defer delete(grid.children)
    defer delete(item.inlines)
    layout_box(&grid, 0, 0, 300)
    testing.expect(t, item.w == 70)
    testing.expectf(t, item.h >= 40, "duas linhas precisam de pelo menos 40px; veio %v", item.h)
    testing.expectf(t, next.y >= item.y + item.h + 8, "a segunda linha não pode sobrepor o conteúdo: %v", next.y)
}

@(test)
test_sizing_intrinsic_keywords_do_not_inherit :: proc(t: ^testing.T) {
    c := test_compute_child(".g{width:min-content}")
    testing.expect(t, !c.width_mc && !c.width_minc && !c.width_fit)
    c = test_apply("width:fit-content")
    testing.expect(t, c.width_mc && c.width_fit && !c.width_minc && !c.has_width)
}

@(private="file")
ts_abs :: proc(ml_auto, mt_auto, stretch: bool) -> Box {
    root := Box{}
    c := Box{pos = .Absolute, has_width = !stretch, width = 40, has_height = true, height = 20,
        has_margin = true, margin = {5, 7, 11, 9},
        margin_left_auto = ml_auto, margin_top_auto = mt_auto,
        inset_has = {true, true, true, true}, inset = {15, 20, 25, 10}}
    append(&root.children, &c)
    defer delete(root.children)
    layout_box(&root, 0, 0, 300)
    layout_absolutes(&root, Rect{0, 0, 300, 200}, Rect{0, 0, 300, 200})
    return c
}

@(test)
test_position_absolute_margins_and_single_auto :: proc(t: ^testing.T) {
    c := ts_abs(false, false, false)
    testing.expectf(t, c.x == 19 && c.y == 20, "inset + margem: veio %v,%v", c.x, c.y)
    c = ts_abs(true, true, false)
    testing.expectf(t, c.x == 233 && c.y == 144, "margem auto absorve o espaço restante: %v,%v", c.x, c.y)
    c = ts_abs(false, false, true)
    testing.expectf(t, c.w == 254 && c.x == 19, "stretch desconta margens: %v,%v", c.w, c.x)
}

@(private="file")
ts_find :: proc(b: ^Box) -> ^Box {
    if b.node != nil && b.node.attrs["id"] == "target" do return b
    for c in b.children {
        if r := ts_find(c); r != nil do return r
    }
    return nil
}

@(test)
test_sizing_intrinsic_width_survives_grid_and_flex_column :: proc(t: ^testing.T) {
    cases := []string{
        `<body style="margin:0"><div style="display:grid;grid-template-columns:200px"><div id="target" style="width:min-content"><span style="display:inline-block;width:40px;height:10px"></span> <span style="display:inline-block;width:70px;height:10px"></span></div></div></body>`,
        `<body style="margin:0"><div style="display:flex;flex-direction:column;width:200px"><div id="target" style="width:min-content"><span style="display:inline-block;width:40px;height:10px"></span> <span style="display:inline-block;width:70px;height:10px"></span></div></div></body>`,
        `<body style="margin:0"><div style="position:relative;width:200px;height:100px"><div id="target" style="position:absolute;left:0;right:0;width:min-content"><span style="display:inline-block;width:40px;height:10px"></span> <span style="display:inline-block;width:70px;height:10px"></span></div></div></body>`,
    }
    for src in cases {
        dom := htmlp.parse(src)
        rules, _ := csspkg.parse("")
        styles, _ := compute_styles(dom, &rules, 800, 600)
        root := build_layout(dom, styles, "")
        layout_box(root, 0, 0, 800)
        layout_absolutes(root, Rect{0, 0, 800, 600}, Rect{0, 0, 800, 600})
        target := ts_find(root)
        testing.expect(t, target != nil)
        if target != nil do testing.expectf(t, target.w == 70, "min-content não deve esticar nem somar os átomos: %v", target.w)
        free_layout(root)
    }
}
