package ui

// M179 — evicção LRU do cache de imagens.
//
// Antes disto o cache era ILIMITADO: `g_images` guardava toda imagem de toda
// página visitada até o processo morrer, e cada uma segura uma textura SDL
// (memória do lado C, invisível ao TRACK_ALLOC). O M178 fechou o ciclo de vida
// (destruir de verdade); faltava o TETO.
//
// A política tem três invariantes, e este teste trava as três:
//   1. NUNCA evicta `.Loading` — tem worker em outra thread escrevendo dentro da
//      entrada; liberar é use-after-free. Esta é de CORREÇÃO, não de desempenho.
//   2. NUNCA evicta o que foi usado nos 2 últimos frames (o que está na tela) —
//      senão o cache vira re-download em laço.
//   3. Evicta do menos usado ao mais usado, só até voltar ao orçamento.
//
// ⚠️ TUDO num @(test) SÓ, de propósito: o runner do Odin roda testes em PARALELO
// e `g_images`/`g_frame` são GLOBAIS. A 1ª versão deste arquivo tinha 5 testes
// separados e deu total contaminado + Segmentation_Fault (um teste liberava as
// URLs enquanto o outro iterava o mapa). Mesma pedra anotada na memória p/ testes
// que tocam global.

import "core:testing"
import "core:fmt"
import "core:strings"

// Entrada sintética: `tex` fica nil de propósito (teste não tem renderer), e o
// custo vem do campo `bytes` — foi p/ isso que ele deixou de ser derivado de `tex`.
@(private = "file")
por_entrada :: proc(url: string, mb: int, usado_em: int, estado: Img_State) -> ^Img {
    img := new(Img)
    img.url = strings.clone(url)
    img.state = estado
    img.bytes = mb * 1024 * 1024
    img.last_used = usado_em
    img.w = 1024; img.h = mb * 256
    g_images[img.url] = img
    return img
}

@(private = "file")
limpa :: proc() {
    images_free_all()
    g_frame = 0
}

@(private = "file")
total_mb :: proc() -> int {
    t := 0
    for _, img in g_images do t += img.bytes
    return t / 1024 / 1024
}

@(test)
m179_evicçao_do_cache_de_imagens :: proc(t: ^testing.T) {
    limpa()
    defer limpa()
    orc_mb := IMG_CACHE_BUDGET / 1024 / 1024

    // ── (a) a fixture PRECISA estourar, senão nada abaixo prova coisa alguma ──
    g_frame = 100
    for i in 0 ..< 5 do por_entrada(fmt.tprintf("http://x/%d.png", i), 40, 10 + i, .Ready)
    testing.expectf(t, total_mb() > orc_mb, "fixture tem de estourar o orcamento, tem %d MB", total_mb())

    // ── (b) evicta as mais VELHAS até caber ──────────────────────────────────
    images_evict()
    testing.expectf(t, total_mb() <= orc_mb, "depois de evictar tem de caber, tem %d MB", total_mb())
    for _, img in g_images {
        testing.expectf(t, img.last_used >= 12, "sobrou uma velha demais (last_used=%d)", img.last_used)
    }

    // ── (c) dentro do orçamento não mexe em nada ─────────────────────────────
    limpa()
    g_frame = 100
    por_entrada("http://x/a.png", 10, 1, .Ready)
    por_entrada("http://x/b.png", 10, 2, .Ready)
    images_evict()
    testing.expect_value(t, len(g_images), 2)

    // ── (d) INVARIANTE 1: `.Loading` nunca é evictada (worker vivo dentro) ────
    limpa()
    g_frame = 100
    por_entrada("http://x/baixando.png", 90, 1, .Loading) // a mais velha de todas
    for i in 0 ..< 3 do por_entrada(fmt.tprintf("http://x/%d.png", i), 40, 10 + i, .Ready)
    images_evict()
    _, viva := g_images["http://x/baixando.png"]
    testing.expect(t, viva, "entrada .Loading NAO pode ser evictada (worker escrevendo nela)")

    // ── (e) INVARIANTE 2: o que está na tela fica, mesmo sendo elegível ───────
    limpa()
    g_frame = 100
    por_entrada("http://x/visivel.png", 60, 100, .Ready) // usada NESTE frame
    por_entrada("http://x/velha1.png", 60, 5, .Ready)
    por_entrada("http://x/velha2.png", 60, 6, .Ready)
    images_evict()
    _, ficou := g_images["http://x/visivel.png"]
    testing.expect(t, ficou, "imagem usada no frame atual NAO pode ser evictada (re-download em laco)")
    testing.expectf(t, total_mb() <= orc_mb, "e ainda assim tem de caber, tem %d MB", total_mb())
}
