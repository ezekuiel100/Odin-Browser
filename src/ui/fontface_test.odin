package ui

// M224 — a parte TESTÁVEL do @font-face: escolha de `src` e validação do SFNT.
// (O download e o atlas não cabem em teste de unidade: rede + contexto de ImGui.
// Para esses existem `browser.exe --fonttest` e a prova ponta-a-ponta com
// servidor local descrita na memória do marco.)

import "core:testing"
import csspkg "../css"

// ── escolha da origem ───────────────────────────────────────────────────────

// ⚠️ Este teste AFIRMAVA, no M224, que woff2 era inutilizável e que só woff2
// na lista derrubava a família para a genérica. Com `src/brotli` + `src/woff2`
// (M226) a afirmação virou — e é exatamente o serviço que um teste-espelho
// presta: ele obriga a mexer aqui em vez de deixar a nova capacidade
// desligada em silêncio.
@(test)
test_m226_pick_ordena_pelo_custo_de_chegar_pronto :: proc(t: ^testing.T) {
    // a lista canônica de site real: woff2 primeiro
    srcs := []csspkg.Font_Src{
        {url = "a.woff2", hint = "woff2"},
        {url = "a.woff",  hint = "woff"},
        {url = "a.ttf",   hint = "truetype"},
    }
    u, ok := test_pick_src(srcs)
    testing.expect(t, ok, "há algo utilizável")
    testing.expectf(t, u == "a.ttf", "SFNT cru vence, que carrega direto; veio %q", u)

    // sem TTF, o woff2 vence o woff1: é o formato moderno e o menor
    u2, ok2 := test_pick_src(srcs[:2])
    testing.expectf(t, ok2 && u2 == "a.woff2", "woff2 vence woff1; veio %q", u2)

    // e só woff2 na lista agora É utilizável
    u3, ok3 := test_pick_src(srcs[:1])
    testing.expectf(t, ok3 && u3 == "a.woff2", "woff2 sozinho serve; veio %q ok=%v", u3, ok3)

    // o que continua fora são os formatos que não são SFNT
    _, ok4 := test_pick_src([]csspkg.Font_Src{
        {url = "a.eot", hint = "embedded-opentype"},
        {url = "a.svg", hint = "svg"},
    })
    testing.expect(t, !ok4, "eot e svg continuam sem origem utilizável")
}

@(test)
test_m224_pick_sem_format_usa_a_extensao :: proc(t: ^testing.T) {
    u, ok := test_pick_src([]csspkg.Font_Src{{url = "https://x/y/font.ttf?v=3", hint = ""}})
    testing.expect(t, ok && u == "https://x/y/font.ttf?v=3", "extensão .ttf com query")
    u2, ok2 := test_pick_src([]csspkg.Font_Src{{url = "f.woff2", hint = ""}})
    testing.expect(t, ok2 && u2 == "f.woff2", "extensão .woff2 sem format() também serve")
}

// ── validação do SFNT (a guarda ANTI-CRASH) ─────────────────────────────────

// Monta um SFNT mínimo: só o diretório de tabelas + um cmap com os encodings
// pedidos. Não precisa de glifo nenhum — o que se testa é a TRIAGEM.
@(private = "file")
fake_sfnt :: proc(tags: []string, cmap_encs: [][2]u16, allocator := context.allocator) -> []byte {
    n := len(tags)
    cmap_at := 12 + 16 * n
    cmap_len := 4 + 8 * len(cmap_encs)
    b := make([]byte, cmap_at + cmap_len + 16, allocator)
    put16 :: proc(d: []byte, at: int, v: u16) { d[at] = u8(v >> 8); d[at + 1] = u8(v) }
    put32 :: proc(d: []byte, at: int, v: u32) {
        d[at] = u8(v >> 24); d[at + 1] = u8(v >> 16); d[at + 2] = u8(v >> 8); d[at + 3] = u8(v)
    }
    put32(b, 0, 0x00010000) // sfntVersion TrueType
    put16(b, 4, u16(n))
    for tag, i in tags {
        e := 12 + i * 16
        b[e] = tag[0]; b[e + 1] = tag[1]; b[e + 2] = tag[2]; b[e + 3] = tag[3]
        off := tag == "cmap" ? cmap_at : cmap_at // qualquer offset válido serve p/ a triagem
        put32(b, e + 8, u32(off))
        put32(b, e + 12, 4)
    }
    put16(b, cmap_at, 0)                      // version
    put16(b, cmap_at + 2, u16(len(cmap_encs)))
    for enc, i in cmap_encs {
        e := cmap_at + 4 + i * 8
        put16(b, e, enc[0])     // platformID
        put16(b, e + 2, enc[1]) // encodingID
    }
    return b
}

@(test)
test_m224_sfnt_usable_aceita_o_normal :: proc(t: ^testing.T) {
    tags := []string{"head", "hhea", "hmtx", "maxp", "cmap", "glyf", "loca"}
    b := fake_sfnt(tags, [][2]u16{{3, 1}}) // Windows Unicode BMP
    defer delete(b)
    testing.expect(t, test_sfnt_usable(b), "TrueType com cmap (3,1) é utilizável")

    b2 := fake_sfnt([]string{"head", "hhea", "hmtx", "maxp", "cmap", "CFF "}, [][2]u16{{0, 3}})
    defer delete(b2)
    testing.expect(t, test_sfnt_usable(b2), "OpenType/CFF com cmap Unicode (plataforma 0)")
}

@(test)
test_m224_sfnt_usable_recusa_o_que_derrubaria :: proc(t: ^testing.T) {
    // ⚠️ ESTA é a guarda que impede um CRASH: sem ela, bytes que o stb_truetype
    // recusa fazem o ImGui abortar o processo (IM_ASSERT em stbtt_InitFont).
    // Medido com a Wingdings do Windows, que só tem cmap de SÍMBOLO (3,0).
    sem_cmap := fake_sfnt([]string{"head", "hhea", "hmtx", "maxp", "glyf", "loca"}, [][2]u16{{3, 1}})
    defer delete(sem_cmap)
    testing.expect(t, !test_sfnt_usable(sem_cmap), "sem tabela cmap")

    sem_glifo := fake_sfnt([]string{"head", "hhea", "hmtx", "maxp", "cmap"}, [][2]u16{{3, 1}})
    defer delete(sem_glifo)
    testing.expect(t, !test_sfnt_usable(sem_glifo), "sem glyf+loca nem CFF")

    so_simbolo := fake_sfnt([]string{"head", "hhea", "hmtx", "maxp", "cmap", "glyf", "loca"}, [][2]u16{{3, 0}})
    defer delete(so_simbolo)
    testing.expect(t, !test_sfnt_usable(so_simbolo), "cmap só-símbolo (3,0): não endereçável por codepoint")

    testing.expect(t, !test_sfnt_usable([]byte{}), "vazio")
    testing.expect(t, !test_sfnt_usable([]byte{0, 1, 0, 0, 9, 9}), "truncado depois do header")
}

@(test)
test_m224_to_sfnt_recusa_lixo :: proc(t: ^testing.T) {
    // "wOF2" com 8 bytes: agora SABEMOS ler woff2, mas este está truncado no
    // cabeçalho. Tem de sair nil, e não estourar índice tentando o diretório.
    w2 := []byte{'w', 'O', 'F', '2', 0, 1, 0, 0}
    testing.expect(t, test_to_sfnt(w2) == nil, "woff2 truncado no cabeçalho")
    // HTML de página de erro servido no lugar da fonte (acontece muito)
    html := transmute([]byte)string("<!doctype html><html><body>404</body></html>")
    testing.expect(t, test_to_sfnt(html) == nil, "corpo que não é fonte")
    // "wOFF" com cabeçalho mentiroso não pode estourar índice
    bad := make([]byte, 60); defer delete(bad)
    bad[0] = 'w'; bad[1] = 'O'; bad[2] = 'F'; bad[3] = 'F'
    bad[12] = 0xFF; bad[13] = 0xFF // numTables absurdo
    testing.expect(t, test_to_sfnt(bad) == nil, "woff corrompido devolve nil sem estourar")
}
