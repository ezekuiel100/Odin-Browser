package ui

// Testes do emoji-como-textura (M188). O rasterizador é PURO (stb_truetype + o
// arquivo da fonte), então roda em `odin test` — diferente de tudo que depende do
// atlas de fontes do ImGui, que não existe aqui.

import "core:testing"
import "core:fmt"

@(test)
emoji_chave_ida_e_volta :: proc(t: ^testing.T) {
    k := emoji_key(0x1F680, context.temp_allocator)
    testing.expectf(t, k == "emoji:1F680", "chave do foguete; veio %q", k)

    cp, ok := emoji_key_rune(k)
    testing.expect(t, ok, "a chave gerada tem de ser reconhecida de volta")
    testing.expectf(t, cp == 0x1F680, "roundtrip; veio U+%X", cp)

    // não é do esquema → não é nossa
    _, nao := emoji_key_rune("https://exemplo.com/a.png")
    testing.expect(t, !nao, "url http NAO pode ser lida como emoji")
    _, nao2 := emoji_key_rune("emoji:")
    testing.expect(t, !nao2, "chave sem codepoint e invalida")
    _, nao3 := emoji_key_rune("emoji:XYZ")
    testing.expect(t, !nao3, "hex invalido e invalido")
}

// A fronteira do desvio. O que o ImGui NÃO representa (fora do BMP) vira
// textura; o que ele já desenha hoje (BMP, via Segoe UI Symbol mesclada) NÃO
// pode ser desviado — senão trocaríamos um caminho que funciona por outro.
@(test)
emoji_fronteira_e_o_bmp :: proc(t: ^testing.T) {
    testing.expect(t, !emoji_needs_texture('A'), "letra comum segue no atlas")
    testing.expect(t, !emoji_needs_texture('á'), "latin-1 segue no atlas")
    testing.expect(t, !emoji_needs_texture(0x2606), "estrela BMP segue no atlas")
    testing.expect(t, !emoji_needs_texture(0x2728), "faisca BMP segue no atlas")
    testing.expect(t, !emoji_needs_texture(0xFFFF), "ultimo do BMP segue no atlas")
    testing.expect(t, emoji_needs_texture(0x10000), "primeiro fora do BMP vira textura")
    testing.expect(t, emoji_needs_texture(0x1F680), "foguete vira textura")
}

@(test)
emoji_split_separa_as_pecas :: proc(t: ^testing.T) {
    // sem emoji: uma peça só, com o texto inteiro (caminho comum)
    p1 := emoji_split("Comecar Gratis")
    testing.expectf(t, len(p1) == 1, "texto puro = 1 peca; veio %d", len(p1))
    testing.expect(t, p1[0].emoji == 0 && p1[0].text == "Comecar Gratis", "peca unica preserva o texto")

    // o caso do site: emoji + espaço + palavra
    p2 := emoji_split("\U0001F680 Comecar")
    testing.expectf(t, len(p2) == 2, "emoji + resto = 2 pecas; veio %d", len(p2))
    testing.expectf(t, p2[0].emoji == 0x1F680, "1a peca e o foguete; veio U+%X", p2[0].emoji)
    testing.expectf(t, p2[1].text == " Comecar", "2a peca mantem o espaco; veio %q", p2[1].text)

    // emoji no MEIO, sem espaços em volta
    p3 := emoji_split("a\U0001F680b")
    testing.expectf(t, len(p3) == 3, "texto-emoji-texto = 3 pecas; veio %d", len(p3))
    testing.expect(t, p3[0].text == "a" && p3[1].emoji == 0x1F680 && p3[2].text == "b", "ordem preservada")

    // dois emoji seguidos
    p4 := emoji_split("\U0001F680\U0001F389")
    testing.expectf(t, len(p4) == 2, "dois emoji = 2 pecas; veio %d", len(p4))

    // texto vazio não gera peça
    testing.expect(t, len(emoji_split("")) == 0, "vazio nao gera peca")
}

// DEGRADAÇÃO DECLARADA: sequência ZWJ vira componentes separados, não o glifo
// combinado. Este teste existe para dizer QUAL é a degradação — se um dia
// tratarmos ZWJ, ele falha e é atualizado de propósito.
@(test)
emoji_zwj_degrada_em_componentes :: proc(t: ^testing.T) {
    // 👨‍👩‍👧 = homem + ZWJ + mulher + ZWJ + menina
    fam := "\U0001F468‍\U0001F469‍\U0001F467"
    p := emoji_split(fam)
    // 3 emoji + os 2 ZWJ (que são BMP e seguem como texto) = 5 peças
    testing.expectf(t, len(p) == 5, "ZWJ hoje separa em componentes; veio %d pecas", len(p))
    testing.expect(t, p[0].emoji == 0x1F468 && p[2].emoji == 0x1F469 && p[4].emoji == 0x1F467,
        "os componentes saem na ordem")
}

@(test)
emoji_raster_sai_colorido :: proc(t: ^testing.T) {
    defer emoji_shutdown()

    px, w, h, ok := emoji_raster(0x1F680)
    if !testing.expectf(t, ok, "o foguete tem de rasterizar (fonte %s)", EMOJI_FONT_PATH) do return
    defer delete(px)

    testing.expectf(t, w > 0 && h > 0, "bitmap com area; veio %dx%d", w, h)
    testing.expectf(t, len(px) == w * h * 4, "RGBA completo; veio %d bytes p/ %dx%d", len(px), w, h)

    opacos := 0
    cores  := make(map[u32]bool, context.temp_allocator)
    for i := 0; i < len(px); i += 4 {
        if px[i + 3] < 250 do continue // só o miolo opaco: a borda é antialias
        opacos += 1
        cores[u32(px[i]) << 16 | u32(px[i + 1]) << 8 | u32(px[i + 2])] = true
    }
    testing.expectf(t, opacos > 100, "o foguete tem miolo opaco; veio %d px", opacos)
    // A prova de que o COLR foi aplicado: silhueta monocromática daria UMA cor.
    testing.expectf(t, len(cores) > 1,
        "COLR aplicado => mais de uma cor no miolo; veio %d cor(es)", len(cores))
    fmt.printf("[emoji] U+1F680 %dx%d, %d px opacos, %d cores distintas\n", w, h, opacos, len(cores))
}

// Rune sem glifo na fonte: degrada em "não desenha", não em crash nem em `?`.
@(test)
emoji_sem_glifo_degrada :: proc(t: ^testing.T) {
    defer emoji_shutdown()
    // plano 16, uso privado — nenhuma fonte de emoji tem isto
    px, w, h, ok := emoji_raster(0x10FFFD)
    testing.expect(t, !ok, "codepoint sem glifo devolve ok=false")
    testing.expect(t, px == nil && w == 0 && h == 0, "e nao devolve bitmap")
}
