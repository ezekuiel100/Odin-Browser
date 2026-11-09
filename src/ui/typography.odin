package ui

import tt "vendor:stb/truetype"
import im "../../vendor/imgui"

Font_Kerning :: enum u8 { Auto, Normal, None }

// A fonte e os bytes pertencem ao atlas. Não guardamos ponteiros para Sources:
// adicionar uma webfont pode realocar essa lista. O cache guarda só fontinfo,
// cujos ponteiros apontam para o SFNT que vive enquanto a fonte viver.
@(thread_local)
g_kern_cache: struct {
    font: ^im.Font,
    data: rawptr,
    info: tt.fontinfo,
    valid: bool,
    gpos: []byte,
    lookups: [256]int,
    n_lookups: int,
}

@(private = "file")
kerning_info :: proc(font: ^im.Font) -> ^tt.fontinfo {
    if font == nil || font.Sources == nil || font.SourcesCount < 1 do return nil
    src := font.Sources
    if src.FontData == nil || src.FontDataSize <= 0 || src.FontNo != 0 do return nil
    if g_kern_cache.font != font || g_kern_cache.data != src.FontData {
        g_kern_cache.font = font
        g_kern_cache.data = src.FontData
        g_kern_cache.valid = bool(tt.InitFont(&g_kern_cache.info, cast([^]u8)src.FontData, 0))
        bytes := (cast([^]byte)src.FontData)[:int(src.FontDataSize)]
        g_kern_cache.gpos = ot_gpos_table(bytes)
        g_kern_cache.n_lookups = ot_kern_lookups(g_kern_cache.gpos, g_kern_cache.lookups[:])
    }
    return g_kern_cache.valid ? &g_kern_cache.info : nil
}

// Usa a mesma escala do stb que rasterizou o atlas (size já inclui render_px).
// Sem glifo na face principal, o fallback/merge continua com seu avanço normal.
text_pair_kerning :: proc(font: ^im.Font, size: f32, left, right: rune, mode: Font_Kerning) -> f32 {
    if mode == .None || left == 0 || right == 0 || size <= 0 do return 0
    info := kerning_info(font)
    if info == nil do return 0
    a, b := tt.FindGlyphIndex(info, left), tt.FindGlyphIndex(info, right)
    if a == 0 || b == 0 do return 0
    if len(g_kern_cache.gpos) > 0 {
        advance, _ := ot_pair_advance(g_kern_cache.gpos, g_kern_cache.lookups[:g_kern_cache.n_lookups], int(a), int(b))
        return f32(advance) * tt.ScaleForPixelHeight(info, size)
    }
    return f32(tt.GetGlyphKernAdvance(info, a, b)) * tt.ScaleForPixelHeight(info, size)
}

text_kerning_width :: proc(font: ^im.Font, size: f32, text: string, mode: Font_Kerning) -> f32 {
    if mode == .None do return 0
    w: f32 = 0
    prev: rune
    for r in text {
        w += text_pair_kerning(font, size, prev, r, mode)
        prev = r
    }
    return w
}

text_has_kerning :: proc(font: ^im.Font, size: f32, text: string, mode: Font_Kerning) -> bool {
    if mode == .None do return false
    prev: rune
    for r in text {
        if text_pair_kerning(font, size, prev, r, mode) != 0 do return true
        prev = r
    }
    return false
}
