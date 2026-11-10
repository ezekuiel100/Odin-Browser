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
