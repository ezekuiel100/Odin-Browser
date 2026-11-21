package ui

import "core:testing"
import im "../../vendor/imgui"

@(test)
test_native_font_raster_size_merge_and_rebuild :: proc(t: ^testing.T) {
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    native_fonts_reset()
    defer native_fonts_reset()
    atlas := im.GetIO().Fonts
    data := #load("../../vendor/imgui/imgui/misc/fonts/Roboto-Medium.ttf")
    primary := [?]im.Wchar{'A', 'A', 0}
    merged := [?]im.Wchar{'V', 'V', 0}
    cfg := content_font_cfg()
    cfg.FontDataOwnedByAtlas = false
    base := im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), 40, &cfg, &primary[0])
    cfg.MergeMode = true
    im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), 40, &cfg, &merged[0])
    testing.expect(t, im.FontAtlas_Build(atlas))

    previous_interactive := g_native_font_interactive
    defer { g_native_font_interactive = previous_interactive }
    g_native_font_interactive = false

    // A large title initially falls back, without modifying the locked atlas.
    atlas.Locked = true
    testing.expect(t, native_font_pick(base, 85.25) == base)
    testing.expect(t, native_fonts_pending())
    testing.expect(t, !native_fonts_add(atlas))
    atlas.Locked = false
    testing.expect(t, native_fonts_add(atlas))
    testing.expect(t, im.FontAtlas_Build(atlas))
    title := native_font_pick(base, 85.25)
    testing.expect(t, title != base)
    testing.expect_value(t, title.FontSize, f32(85))
    testing.expect_value(t, title.SourcesCount, i16(2))
    testing.expect(t, im.Font_FindGlyphNoFallback(title, 'A') != nil)
    testing.expect(t, im.Font_FindGlyphNoFallback(title, 'V') != nil, "merged symbols must survive native rasterization")
    testing.expect(t, !native_fonts_pending())

    native_font_pick(base, 17.5)
    testing.expect(t, native_fonts_add(atlas))
    testing.expect(t, im.FontAtlas_Build(atlas))
    testing.expect(t, native_font_pick(base, 85.25) == title, "old font handles survive subsequent rebuilds")
    testing.expect(t, im.Font_FindGlyphNoFallback(title, 'V') != nil)
    testing.expect(t, native_font_pick(base, 200) == base, "oversized requests use the bounded fallback")
}

@(test)
test_interactive_large_title_raster_and_animation_reuse :: proc(t: ^testing.T) {
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    native_fonts_reset()
    defer native_fonts_reset()
    previous_interactive := g_native_font_interactive
    g_native_font_interactive = true
    defer { g_native_font_interactive = previous_interactive }
    atlas := im.GetIO().Fonts
    data := #load("../../vendor/imgui/imgui/misc/fonts/Roboto-Medium.ttf")
    ranges := [?]im.Wchar{32, 126, 0}
    cfg := content_font_cfg()
    cfg.FontDataOwnedByAtlas = false
    base := im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), 40, &cfg, &ranges[0])
    testing.expect(t, im.FontAtlas_Build(atlas))

    // The 1.5x bootstrap raster already covers ordinary text sizes.
    for size: f32 = 16; size <= 60; size += 0.5 {
        testing.expect(t, native_font_pick(base, size) == base)
    }
    testing.expect(t, !native_fonts_pending())
    testing.expect_value(t, len(g_native_fonts), 0)

    // Work Sans's 72 CSS px title needs a larger physical raster. All sizes
    // in this animation bucket queue just one request, even inside a frame.
    atlas.Locked = true
    for size: f32 = 81; size <= 96; size += 0.25 {
        testing.expect(t, native_font_pick(base, size) == base)
    }
    testing.expect_value(t, len(g_native_fonts), 1)
    testing.expect(t, !native_fonts_add(atlas))
    atlas.Locked = false
    testing.expect(t, native_fonts_add(atlas))
    testing.expect(t, im.FontAtlas_Build(atlas))
    title := native_font_pick(base, 85.25)
    testing.expect(t, title != base)
    testing.expect_value(t, title.FontSize, f32(96))
    testing.expect(t, im.Font_FindGlyphNoFallback(title, 'A') != nil)

    // Shrinking and repeating the animation reuse the higher resolution font.
    for size: f32 = 61; size <= 96; size += 0.25 {
        testing.expect(t, native_font_pick(base, size) == title)
    }
    testing.expect(t, !native_fonts_pending())
    testing.expect_value(t, len(g_native_fonts), 1)
    testing.expect(t, !native_fonts_add(atlas))
    testing.expect(t, native_font_pick(base, 200) == base)
}
