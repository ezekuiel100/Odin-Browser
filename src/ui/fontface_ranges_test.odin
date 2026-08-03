package ui

// Guarda contra face com ZERO glifo nos ranges do atlas.
//
// O que é certo: se uma face entra no atlas e não produz glifo nenhum dentro de
// `g_text_ranges`, o `IM_ASSERT(Glyphs.Size > 0)` do ImGui ABORTA o processo
// DENTRO do `FontAtlas_Build` — não na primeira pintura. Nada barrava isso.
//
// ⚠️ O que NÃO é certo, e está medido em `face_glyph_count_in_ranges`: que
// exista fonte real que caia nesse buraco. Escrevi este arquivo convencido de
// que fonte de ícones era o espécime e a medição derrubou a hipótese — Font
// Awesome (108), Glyphicons (21), Segoe MDL2 (1), subset greek-ext do Google
// Fonts (2). Todas sobrevivem, porque `g_text_ranges` começa em U+0020 e
// praticamente toda fonte embarca o espaço. Por isso o caso do crash aqui é
// montado pelo lado dos RANGES, com um bloco que a fonte comprovadamente não
// cobre: mesma aritmética, resultado determinístico, e sem afirmar sobre fonte
// real uma coisa que eu não consegui demonstrar.
//
// ⚠️ Fontes REAIS, não stubs sintéticos: o que está sob teste é o cruzamento do
// cmap de verdade com os ranges de verdade, e um SFNT montado à mão nem passa
// pelo `stbtt_InitFont` que o guarda usa (é o mesmo que o ImGui roda).

import "core:os"
import "core:testing"
import im "../../vendor/imgui"

SEGOE_UI   :: "C:\\Windows\\Fonts\\segoeui.ttf"  // texto: Latin/grego/pontuação…
SEGOE_MDL2 :: "C:\\Windows\\Fonts\\segmdl2.ttf"  // ícones: glifos em U+E700–U+E9FF

// Bloco CJK: medido em 0 glifos nas DUAS fontes abaixo. É o papel que a PUA
// deveria fazer para uma fonte de ícones — pedir ao atlas o que a fonte não tem.
@(private = "file")
g_ranges_nao_cobertos := [?]im.Wchar{0x4E00, 0x4EFF, 0}

@(private = "file")
ler :: proc(t: ^testing.T, path: string) -> ([]byte, bool) {
    b, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil || len(b) == 0 {
        testing.expectf(t, false, "fonte de sistema ausente (%s): o teste precisa dela para valer algo", path)
        return nil, false
    }
    return b, true
}

// 1. CONTROLE: fonte de texto normal continua entrando. Um guarda paranoico
//    demais mataria toda webfont e "consertaria" o crash tirando a feature.
@(test)
test_guarda_aceita_fonte_de_texto :: proc(t: ^testing.T) {
    b, ok := ler(t, SEGOE_UI); if !ok do return
    defer delete(b)
    testing.expect(t, face_glyph_count_in_ranges(b, g_text_ranges[:]) > 0,
        "Segoe UI tem glifo nos ranges de texto (não pode ser recusada)")
}

// 2. O CASO FATAL: fonte válida × ranges que ela não cobre = zero glifos no
//    atlas. Sem o guarda, isto aborta dentro do FontAtlas_Build.
@(test)
test_guarda_recusa_face_sem_glifo_nos_ranges :: proc(t: ^testing.T) {
    b, ok := ler(t, SEGOE_UI); if !ok do return
    defer delete(b)
    // Ela passa na triagem ANTERIOR — é por isso que o caso chegaria ao atlas.
    testing.expect(t, sfnt_usable(b),
        "a fonte é um SFNT válido: sfnt_usable sozinho NÃO barra este caso")
    testing.expect(t, face_glyph_count_in_ranges(b, g_ranges_nao_cobertos[:]) == 0,
        "zero glifo nos ranges pedidos → recusada ANTES do FontAtlas_Build")
}

// 3. O guarda segue os ranges que RECEBE — não tem preferência por
//    `g_text_ranges`. Sem este caso, o 2 seria compatível com "recusa qualquer
//    range que eu não conheça", e é ele que cai nas DUAS sabotagens.
@(test)
test_guarda_segue_os_ranges_que_recebe :: proc(t: ^testing.T) {
    b, ok := ler(t, SEGOE_MDL2); if !ok do return
    defer delete(b)
    testing.expect(t, face_glyph_count_in_ranges(b, g_icon_ranges[:]) > 0,
        "a fonte de ícones tem glifos de sobra em U+E700–U+E9FF")
    testing.expect(t, face_glyph_count_in_ranges(b, g_ranges_nao_cobertos[:]) == 0,
        "a MESMA fonte não tem nada em CJK")
}

// 4. Lixo e vazio dão 0 — e, sobretudo, não ESTOURAM: `stbtt_InitFont` não
//    valida nada e segfaulta em bytes truncados (foi o que este caso pegou).
@(test)
test_guarda_recusa_bytes_invalidos :: proc(t: ^testing.T) {
    testing.expect(t, face_glyph_count_in_ranges(nil, g_text_ranges[:]) == 0, "vazio")
    testing.expect(t, face_glyph_count_in_ranges([]byte{0, 1, 0, 0, 9, 9}, g_text_ranges[:]) == 0, "truncado")
}
