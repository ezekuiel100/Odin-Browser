package ui

import "core:math"
import "core:slice"
import im "../../vendor/imgui"

// Native raster sizes are requested during layout, but added only BETWEEN
// frames: adding a source while ImGui owns the atlas invalidates draw data.
// Keep the bootstrap ladder as a fallback and bound session memory (including
// pages animating font-size). Font bytes and glyph ranges remain atlas-owned.
Native_Font :: struct {
    base: ^im.Font,
    size: f32,
    font: ^im.Font,
}
g_native_fonts: [dynamic]Native_Font
g_native_font_pixels: f32
NATIVE_FONT_LIMIT :: 64
NATIVE_FONT_PIXEL_BUDGET :: 24 * 1024 * 1024

native_fonts_reset :: proc() {
    delete(g_native_fonts)
    g_native_fonts = nil
    g_native_font_pixels = 0
}

native_font_pick :: proc(base: ^im.Font, size: f32) -> ^im.Font {
    if base == nil || base.Sources == nil || base.SourcesCount == 0 ||
       size < 4 || size > 160 || math.is_nan(size) {
        return base
    }
    if im.GetCurrentContext() == nil || base.ContainerAtlas != im.GetIO().Fonts do return base
    // This ImGui rasterizer floors SizePixels. Use nearest physical pixels,
    // avoiding redundant fractional entries during zoom/animations.
    target := math.round(size)
    for v in g_native_fonts {
        if v.base == base && v.size == target do return v.font != nil ? v.font : base
    }
    // Conservative area estimate, counting actual fallback/merged glyphs too.
    pixels := target * target * f32(base.Glyphs.Size)
    if len(g_native_fonts) < NATIVE_FONT_LIMIT &&
       g_native_font_pixels + pixels <= NATIVE_FONT_PIXEL_BUDGET {
        append(&g_native_fonts, Native_Font{base = base, size = target})
        g_native_font_pixels += pixels
    }
    return base
}

native_fonts_pending :: proc() -> bool {
    for v in g_native_fonts do if v.font == nil do return true
    return false
}

// Called by fontface_poll, sharing its single atlas rebuild and texture upload.
native_fonts_add :: proc(atlas: ^im.FontAtlas) -> bool {
    if atlas == nil || atlas.Locked do return false
    added := false
    for &v in g_native_fonts {
        if v.font != nil do continue
        // AddFont can reallocate Sources, so copy ALL merge inputs first.
        sources := slice.clone((cast([^]im.FontConfig)v.base.Sources)[:int(v.base.SourcesCount)])
        for source, i in sources {
            cfg := source
            ratio := v.size / v.base.FontSize
            cfg.FontDataOwnedByAtlas = false
            cfg.SizePixels = source.SizePixels * ratio
            cfg.GlyphOffset *= ratio
            cfg.GlyphMinAdvanceX *= ratio
            cfg.GlyphExtraAdvanceX *= ratio
            cfg.RasterizerDensity = 1
            cfg.OversampleH = 2
            cfg.OversampleV = 1
            cfg.PixelSnapH = false
            cfg.MergeMode = i != 0
            cfg.DstFont = v.font
            f := im.FontAtlas_AddFont(atlas, &cfg)
            if i == 0 do v.font = f
        }
        delete(sources)
        added = true
    }
    return added
}
