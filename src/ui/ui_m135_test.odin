package ui

// M135 — trilha `.Auto` (auto / min-content / max-content / lado MAX de um minmax)
// era fixada no max-content SEM TETO, e o item VAZAVA do container.
//
// No ge.globo: `.feed-post-body` é `repeat(auto-fit, minmax(45%, max-content))` num
// container de 579px; o título dava max-content de 803px e a manchete saía CORTADA
// na borda direita (o texto existia, só não cabia).
//
// A spec resolve isso em duas etapas: a base da trilha é a função de MÍNIMO, e o
// max-content é só um LIMITE DE CRESCIMENTO — alcançável apenas se houver espaço
// livre. Sem espaço livre a trilha fica na base. Aqui o efeito é o mesmo pelo outro
// lado: se o total estoura, o excesso é devolvido pelas trilhas .Auto na proporção
// do que cada uma pode ceder (do max-content até seu piso).

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return root
}

@(private = "file")
find_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == want do return b
    }
    for c in b.children {
        if r := find_id(c, want); r != nil do return r
    }
    return nil
}

@(private = "file")
BODY :: `<body style="margin:0"><div style="width:579px">`

// O caso do ge.globo, reduzido: mídia na coluna 1, texto na coluna 2.
//
// ⚠️ Em `odin test` NÃO há atlas de fonte (word_width=0), então texto não serve de
// max-content aqui. O conteúdo largo é um filho com LARGURA EXPLÍCITA — mede igual e
// independe de métrica de fonte. (O caso com texto de verdade foi validado por
// `--render` sobre a home do ge.globo.)
@(private = "file")
FEED :: BODY + `<div style="display:grid;column-gap:16px;align-items:start;
        grid-template-columns:repeat(auto-fit,minmax(45%,max-content));
        grid-template-rows:repeat(5,auto)">
    <div id="media" style="grid-column:1;grid-row:1/span 5"><div style="width:261px"></div></div>
    <div id="hdr" style="grid-column:2"><div style="width:120px"></div></div>
    <div id="ttl" style="grid-column:2"><div style="width:803px"></div></div>
    </div></div></body>`

@(test)
m135_max_content_nao_vaza_do_container :: proc(t: ^testing.T) {
    root := lay(FEED)
    ttl := find_id(root, "ttl")
    testing.expect(t, ttl != nil, "achou o titulo")
    if ttl == nil do return
    testing.expectf(t, ttl.x + ttl.w <= 579.5,
        "o titulo termina DENTRO dos 579px (x=%.0f w=%.0f fim=%.0f)", ttl.x, ttl.w, ttl.x + ttl.w)
}

@(test)
m135_as_duas_trilhas_somadas_cabem :: proc(t: ^testing.T) {
    // 261 (mídia) + 16 (gap) + 302 (texto) = 579 exatos.
    root := lay(FEED)
    media, hdr := find_id(root, "media"), find_id(root, "hdr")
    testing.expect(t, media != nil && hdr != nil, "achou os itens")
    if media == nil || hdr == nil do return
    total := media.w + 16 + hdr.w
    testing.expectf(t, total <= 579.5, "trilhas + gap cabem em 579 (%.0f + 16 + %.0f = %.0f)",
        media.w, hdr.w, total)
    testing.expectf(t, hdr.x > media.x, "ficaram em colunas distintas (media.x=%.0f hdr.x=%.0f)",
        media.x, hdr.x)
}

@(test)
m135_o_excesso_sai_de_quem_pode_ceder :: proc(t: ^testing.T) {
    // A mídia (max-content 261) está quase no piso de 45% (260,55): quem cede é a
    // coluna do texto, que ia de 803 para ~302.
    root := lay(FEED)
    media, ttl := find_id(root, "media"), find_id(root, "ttl")
    if media == nil || ttl == nil { testing.fail(t); return }
    testing.expectf(t, media.w >= 260 && media.w <= 262,
        "a mídia mal encolheu, ficou no max-content dela (w=%.1f)", media.w)
    testing.expectf(t, ttl.w > 290 && ttl.w < 315,
        "o texto cedeu o excesso e ficou ~302 (w=%.1f)", ttl.w)
}

@(test)
m135_sem_estouro_o_max_content_e_respeitado :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o encolhimento só vale quando estoura. Cabendo, a trilha .Auto
    // continua no max-content (não é esticada nem espremida).
    root := lay(BODY + `<div style="display:grid;grid-template-columns:max-content max-content;column-gap:16px">
        <div id="a"><div style="width:100px"></div></div>
        <div id="b"><div style="width:150px"></div></div></div></div></body>`)
    a, b := find_id(root, "a"), find_id(root, "b")
    if a == nil || b == nil { testing.fail(t); return }
    testing.expectf(t, a.w == 100 && b.w == 150,
        "cada trilha continua no max-content do seu conteúdo (a=%.0f b=%.0f)", a.w, b.w)
}

@(test)
m135_trilha_fixa_nao_cede_espaco :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: só trilhas .Auto devolvem excesso. Uma coluna em px é rígida —
    // o excesso todo tem que sair da coluna max-content ao lado.
    root := lay(BODY + `<div style="display:grid;grid-template-columns:400px max-content">
        <div id="a"></div>
        <div id="b"><div style="width:500px"></div></div></div></div></body>`)
    a, b := find_id(root, "a"), find_id(root, "b")
    if a == nil || b == nil { testing.fail(t); return }
    testing.expectf(t, a.w == 400, "a coluna fixa continua com 400px (w=%.0f)", a.w)
    testing.expectf(t, b.w > 170 && b.w < 190, "a max-content cedeu tudo (w=%.0f, esperado ~179)", b.w)
}
