package ui

// EMOJI COLORIDO (M188).
//
// Por que existe este arquivo: o ImGui deste build usa `ImWchar = ImWchar16`
// (ver vendor/imgui/imgui.odin, `Wchar :: Wchar16`). Com isso
// `IM_UNICODE_CODEPOINT_MAX` é 0xFFFF e o decodificador UTF-8 do ImGui marca
// TODO codepoint acima disso como erro, trocando-o por U+FFFD (imgui.cpp:2482);
// o FindGlyph então cai no FallbackChar e a tela mostra `?`. Ou seja: o conjunto
// exato do que aparecia como `?` é "rune fora do BMP" — não é falta de fonte, é
// o tipo do atlas não representar o codepoint. Mexer nisso exigiria recompilar o
// ImGui com IMGUI_USE_WCHAR32 e regerar o binding (muda o layout de IO/FontConfig
// e a .lib pré-compilada do vendor); em vez disso, tiramos o emoji do caminho do
// atlas: ele vira uma TEXTURA, desenhada como uma imagem inline.
//
// O caminho reusa inteiro o pipeline de imagem (`Img`/`g_images`/`PC_Image`/
// evicção LRU): o item inline recebe `img_url = "emoji:1F680"` e o único ponto
// novo em images.odin é reconhecer esse esquema e rasterizar LOCALMENTE, sem
// rede e sem worker (é microssegundos, e já estamos na thread principal com o
// renderer na mão).
//
// A cor vem das tabelas COLR/CPAL do Segoe UI Emoji: COLR dá, por glifo-base, a
// lista de CAMADAS (cada uma um glifo + um índice de paleta) e CPAL dá as cores.
// Rasterizamos cada camada com stb_truetype e compomos. Sem COLR (ou fonte sem a
// tabela) cai na SILHUETA monocromática do glifo base — degradação honesta e
// coberta por teste, não erro.

import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"
import "vendor:sdl2"

import tt "vendor:stb/truetype"

// Esquema sintético usado como chave no cache de imagens (`g_images`).
EMOJI_SCHEME :: "emoji:"

// Rasterizamos UMA vez neste tamanho e deixamos o AddImage escalar. A chave do
// cache NÃO leva o tamanho de propósito: senão cada font-size da página criaria
// uma textura própria do mesmo emoji.
EMOJI_RASTER_PX :: 64

EMOJI_FONT_PATH :: "C:\\Windows\\Fonts\\seguiemj.ttf"

// Teto de segurança do canvas composto (a união das camadas é dado do arquivo;
// um COLR corrompido não pode nos fazer alocar centenas de MB).
@(private = "file")
EMOJI_MAX_PX :: EMOJI_RASTER_PX * 4

// ── Fonte de emoji (carregada sob demanda) ──────────────────────────────────
// Página sem emoji não paga os ~12 MB do arquivo. Uma vez carregada, fica: o
// custo é o arquivo, e recarregar por glifo seria muito pior.
@(private = "file") g_emoji_data:   []byte
@(private = "file") g_emoji_info:   tt.fontinfo
@(private = "file") g_emoji_loaded: bool
@(private = "file") g_emoji_ok:     bool

@(private = "file")
emoji_font :: proc() -> (^tt.fontinfo, bool) {
    if !g_emoji_loaded {
        g_emoji_loaded = true
        data, err := os.read_entire_file_from_path(EMOJI_FONT_PATH, context.allocator)
        if err == nil && len(data) > 0 {
            g_emoji_data = data
            g_emoji_ok = bool(tt.InitFont(&g_emoji_info, raw_data(g_emoji_data), 0))
            if !g_emoji_ok { delete(g_emoji_data); g_emoji_data = nil }
        }
    }
    if !g_emoji_ok do return nil, false
    return &g_emoji_info, true
}

// Libera a fonte de emoji (chamado no shutdown junto com o resto).
emoji_shutdown :: proc() {
    if g_emoji_data != nil { delete(g_emoji_data); g_emoji_data = nil }
    g_emoji_loaded = false
    g_emoji_ok     = false
}

// ── Chave de cache ──────────────────────────────────────────────────────────

// "emoji:1F680" — hexadecimal MAIÚSCULO, sem zeros à esquerda.
emoji_key :: proc(cp: rune, allocator := context.allocator) -> string {
    return fmt.aprintf("%s%X", EMOJI_SCHEME, cp, allocator = allocator)
}

// Inverso de emoji_key. Devolve ok=false se a url não for do esquema.
emoji_key_rune :: proc(url: string) -> (rune, bool) {
    if !strings.has_prefix(url, EMOJI_SCHEME) do return 0, false
    hex := url[len(EMOJI_SCHEME):]
    if hex == "" do return 0, false
    v: i64 = 0
    for ch in hex {
        d: i64
        switch {
        case ch >= '0' && ch <= '9': d = i64(ch - '0')
        case ch >= 'A' && ch <= 'F': d = i64(ch - 'A') + 10
        case ch >= 'a' && ch <= 'f': d = i64(ch - 'a') + 10
        case: return 0, false
        }
        v = v * 16 + d
        if v > 0x10FFFF do return 0, false
    }
    return rune(v), true
}

// O ImGui consegue representar este rune no atlas? Tudo acima do BMP vira U+FFFD
// (`?`) lá dentro — é exatamente esse conjunto que desviamos para textura.
// Runes do BMP seguem pelo caminho normal (a Segoe UI Symbol já está mesclada
// nas fontes de conteúdo); desviá-los também seria mudar o que hoje funciona.
emoji_needs_texture :: proc(r: rune) -> bool {
    return r > 0xFFFF
}

// ── Leitura big-endian do sfnt ──────────────────────────────────────────────

@(private = "file")
be16 :: proc(b: []byte, o: int) -> (u16, bool) {
    if o < 0 || o + 2 > len(b) do return 0, false
    return u16(b[o]) << 8 | u16(b[o + 1]), true
}

@(private = "file")
be32 :: proc(b: []byte, o: int) -> (u32, bool) {
    if o < 0 || o + 4 > len(b) do return 0, false
    return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3]), true
}

// Offset de uma tabela do sfnt pelo tag de 4 letras.
@(private = "file")
sfnt_table :: proc(data: []byte, tag: string) -> (int, bool) {
    num, ok := be16(data, 4)
    if !ok do return 0, false
    for i in 0 ..< int(num) {
        o := 12 + i * 16
        if o + 16 > len(data) do return 0, false
        if string(data[o:o + 4]) == tag {
            off, k := be32(data, o + 8)
            if !k || int(off) >= len(data) do return 0, false
            return int(off), true
        }
    }
    return 0, false
}

// ── COLR / CPAL ─────────────────────────────────────────────────────────────

Emoji_Layer :: struct {
    glyph:   i32,
    palette: u16, // 0xFFFF = "cor do texto" (foreground) por definição do COLR
}

// Camadas COLR (v0) do glifo base. Sem tabela/registro → ok=false, e o chamador
// cai na silhueta.
@(private = "file")
colr_layers :: proc(data: []byte, gid: i32, allocator := context.allocator) -> ([]Emoji_Layer, bool) {
    colr, ok := sfnt_table(data, "COLR")
    if !ok do return nil, false
    ver, k1        := be16(data, colr + 0)
    n_base, k2     := be16(data, colr + 2)
    base_off, k3   := be32(data, colr + 4)
    layer_off, k4  := be32(data, colr + 8)
    n_layer, k5    := be16(data, colr + 12)
    if !k1 || !k2 || !k3 || !k4 || !k5 do return nil, false
    if ver != 0 && ver != 1 do return nil, false // v1 tem grafo próprio; usamos só a parte v0
    base := colr + int(base_off)
    lays := colr + int(layer_off)

    // BaseGlyphRecord[]: (uint16 gid, uint16 firstLayer, uint16 numLayers),
    // ORDENADO por gid → busca binária.
    lo, hi := 0, int(n_base) - 1
    first, count: u16
    found := false
    for lo <= hi {
        mid := (lo + hi) / 2
        rec := base + mid * 6
        g, kg := be16(data, rec)
        if !kg do return nil, false
        switch {
        case i32(g) < gid: lo = mid + 1
        case i32(g) > gid: hi = mid - 1
        case:
            f, kf := be16(data, rec + 2)
            c, kc := be16(data, rec + 4)
            if !kf || !kc do return nil, false
            first, count = f, c
            found = true
            lo, hi = 1, 0 // sai
        }
    }
    if !found || count == 0 do return nil, false
    if int(first) + int(count) > int(n_layer) do return nil, false

    out := make([]Emoji_Layer, int(count), allocator)
    for i in 0 ..< int(count) {
        rec := lays + (int(first) + i) * 4
        g, kg := be16(data, rec)
        p, kp := be16(data, rec + 2)
        if !kg || !kp { delete(out, allocator); return nil, false }
        out[i] = Emoji_Layer{glyph = i32(g), palette = p}
    }
    return out, true
}

// Cor (r,g,b,a) de um índice da paleta 0 do CPAL. Índice 0xFFFF (foreground) e
// qualquer falha → preto opaco.
@(private = "file")
cpal_color :: proc(data: []byte, idx: u16) -> [4]u8 {
    PRETO :: [4]u8{0, 0, 0, 255}
    if idx == 0xFFFF do return PRETO
    cpal, ok := sfnt_table(data, "CPAL")
    if !ok do return PRETO
    n_entries, k1 := be16(data, cpal + 2)
    n_pal,     k2 := be16(data, cpal + 4)
    recs_off,  k3 := be32(data, cpal + 8)
    if !k1 || !k2 || !k3 || n_pal == 0 || idx >= n_entries do return PRETO
    // colorRecordIndices[0] = primeiro registro da paleta 0
    first, k4 := be16(data, cpal + 12)
    if !k4 do return PRETO
    rec := cpal + int(recs_off) + (int(first) + int(idx)) * 4
    if rec + 4 > len(data) do return PRETO
    // ColorRecord é BGRA
    return [4]u8{data[rec + 2], data[rec + 1], data[rec + 0], data[rec + 3]}
}

// ── Rasterização ────────────────────────────────────────────────────────────

// Rasteriza um emoji em RGBA (alpha NÃO pré-multiplicado, que é o que o
// SDL_BLEND espera). Devolve pixels/w/h; ok=false se a fonte não tem o glifo —
// nesse caso o chamador não desenha nada (melhor um vão que um `?`).
emoji_raster :: proc(cp: rune, px := EMOJI_RASTER_PX, allocator := context.allocator) -> (pixels: []u8, w: int, h: int, ok: bool) {
    info, fok := emoji_font()
    if !fok do return nil, 0, 0, false
    gid := tt.FindGlyphIndex(info, cp)
    if gid == 0 do return nil, 0, 0, false // a fonte não tem este emoji

    layers, has_colr := colr_layers(g_emoji_data, gid, context.temp_allocator)
    if !has_colr {
        // Silhueta: o glifo base sozinho, em preto. É o que uma fonte sem COLR
        // (ou um emoji sem registro) consegue dar.
        layers = make([]Emoji_Layer, 1, context.temp_allocator)
        layers[0] = Emoji_Layer{glyph = gid, palette = 0xFFFF}
    }

    scale := tt.ScaleForPixelHeight(info, f32(px))

    Bmp :: struct { data: [^]byte, w, h, x, y: i32, col: [4]u8 }
    bmps := make([dynamic]Bmp, 0, len(layers), context.temp_allocator)
    defer for b in bmps do tt.FreeBitmap(b.data, nil)

    minx, miny := max(i32), max(i32)
    maxx, maxy := min(i32), min(i32)
    for l in layers {
        bw, bh, bx, by: i32
        d := tt.GetGlyphBitmap(info, scale, scale, l.glyph, &bw, &bh, &bx, &by)
        if d == nil || bw <= 0 || bh <= 0 do continue
        append(&bmps, Bmp{d, bw, bh, bx, by, cpal_color(g_emoji_data, l.palette)})
        minx = min(minx, bx);      miny = min(miny, by)
        maxx = max(maxx, bx + bw); maxy = max(maxy, by + bh)
    }
    if len(bmps) == 0 do return nil, 0, 0, false

    cw := int(maxx - minx)
    ch := int(maxy - miny)
    if cw <= 0 || ch <= 0 || cw > EMOJI_MAX_PX || ch > EMOJI_MAX_PX do return nil, 0, 0, false

    out := make([]u8, cw * ch * 4, allocator)
    // Compõe "source-over" em alpha RETO (não pré-multiplicado):
    //   a = as + ad*(1-as);  c = (cs*as + cd*ad*(1-as)) / a
    for b in bmps {
        for yy in 0 ..< int(b.h) {
            dy := int(b.y - miny) + yy
            if dy < 0 || dy >= ch do continue
            for xx in 0 ..< int(b.w) {
                dx := int(b.x - minx) + xx
                if dx < 0 || dx >= cw do continue
                cov := b.data[yy * int(b.w) + xx]
                if cov == 0 do continue
                as := (f32(cov) / 255) * (f32(b.col[3]) / 255)
                if as <= 0 do continue
                o  := (dy * cw + dx) * 4
                ad := f32(out[o + 3]) / 255
                a  := as + ad * (1 - as)
                if a <= 0 do continue
                for c in 0 ..< 3 {
                    cs := f32(b.col[c]) / 255
                    cd := f32(out[o + c]) / 255
                    out[o + c] = u8(clamp((cs * as + cd * ad * (1 - as)) / a, 0, 1) * 255 + 0.5)
                }
                out[o + 3] = u8(clamp(a, 0, 1) * 255 + 0.5)
            }
        }
    }
    return out, cw, ch, true
}

// ── Separação de emoji no texto ─────────────────────────────────────────────

Emoji_Piece :: struct {
    text:  string, // fatia do original (vazia quando é emoji)
    emoji: rune,   // 0 quando é texto
}

// Quebra um texto nos runes que precisam virar textura. "🚀 Vai" →
// [emoji 1F680]["  Vai"]. Sem emoji nenhum devolve UMA peça com o texto inteiro
// (o caminho comum não paga nada além da varredura).
//
// ⚠️ Degradação conhecida: sequências ZWJ (👨‍👩‍👧) e modificadores de tom de pele
// viram peças SEPARADAS — desenhamos os componentes, não o glifo combinado. É
// pior que o Chrome e melhor que `?`; está coberto por teste dizendo isso.
emoji_split :: proc(text: string, allocator := context.temp_allocator) -> []Emoji_Piece {
    tem := false
    for r in text {
        if emoji_needs_texture(r) { tem = true; break }
    }
    out := make([dynamic]Emoji_Piece, 0, tem ? 4 : 1, allocator)
    if !tem {
        if text != "" do append(&out, Emoji_Piece{text = text})
        return out[:]
    }
    start := 0
    for r, i in text {
        if !emoji_needs_texture(r) do continue
        if i > start do append(&out, Emoji_Piece{text = text[start:i]})
        append(&out, Emoji_Piece{emoji = r})
        start = i + utf8_rune_len(r)
    }
    if start < len(text) do append(&out, Emoji_Piece{text = text[start:]})
    return out[:]
}

@(private = "file")
utf8_rune_len :: proc(r: rune) -> int {
    switch {
    case r < 0x80:    return 1
    case r < 0x800:   return 2
    case r < 0x10000: return 3
    }
    return 4
}

// ── Entrega ao cache de imagens ─────────────────────────────────────────────

// Preenche uma entrada `Img` do esquema "emoji:" rasterizando na hora. Roda na
// THREAD PRINCIPAL (chamado de images_poll), então já sobe a textura aqui — nem
// passa pelo handoff `pixels` do worker, e por isso não mexe em quem libera o quê.
emoji_img_upload :: proc(img: ^Img, renderer: ^sdl2.Renderer) {
    img.state = .Failed // qualquer saída antecipada abaixo fica em Failed
    cp, ok := emoji_key_rune(img.url)
    if !ok do return
    if renderer == nil do return

    px, w, h, rok := emoji_raster(cp)
    if !rok do return // a fonte não tem este glifo → o item colapsa (inline_img_dims)
    defer delete(px)

    tex := sdl2.CreateTexture(renderer, .RGBA32, .STATIC, c.int(w), c.int(h))
    if tex == nil do return
    sdl2.UpdateTexture(tex, nil, raw_data(px), c.int(w * 4))
    sdl2.SetTextureBlendMode(tex, .BLEND)
    // Rasterizamos a 64px e o texto costuma ser bem menor: sem filtro linear o
    // downscale vira serrilha.
    // ⚠️ NÃO chamar `SetTextureScaleMode(tex, .Linear)` aqui. Rasterizamos a 64px
    // e o texto é bem menor, então o filtro linear PARECE a coisa certa — mas com
    // ele o backend imgui_impl_sdlrenderer2 simplesmente NÃO DESENHA esta textura:
    // a página sai com o vão do emoji e nada dentro. Medido nos dois sentidos —
    // `.Nearest` explícito dá um PNG byte a byte idêntico ao de não chamar, e só
    // `.Linear` some. O sintoma engana: com qualquer outro comando de textura
    // emitido antes no mesmo drawlist, o emoji volta a aparecer (foi assim que o
    // achamos, com um AddRectFilled de sonda). Deixe o default, como fazem as
    // imagens normais do motor.

    if img.tex != nil do sdl2.DestroyTexture(img.tex)
    img.tex   = tex
    img.w     = w
    img.h     = h
    img.bytes = w * h * 4 // entra no orçamento da evicção como qualquer imagem
    img.state = .Ready
}

// Descrição legível p/ log/DevTools.
emoji_describe :: proc(url: string, allocator := context.temp_allocator) -> string {
    cp, ok := emoji_key_rune(url)
    if !ok do return url
    return fmt.aprintf("emoji U+%X", cp, allocator = allocator)
}
