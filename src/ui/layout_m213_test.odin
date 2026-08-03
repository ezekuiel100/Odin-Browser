package ui

// M213 — absoluto SEM `top` dentro de outro absoluto ficava ancorado em y≈0.
//
// Origem: a faixa clara no TOPO da home do github.com. O `.glow` daquela seção mora
// a 2875px do topo (o pai, `.lp-SectionHero-glow`, estava certo), mas era pintado em
// y=0 — 2900px acima do lugar, cobrindo o hero.
//
// Raiz: `place_absolute` dimensiona a caixa em (0,0) — e é AÍ que a posição estática
// dos descendentes absolutos é gravada — e só depois translada para o lugar final.
// A translação usava `translate_box`, uma cópia de `translate_subtree` que havia
// esquecido de mover `static_x/static_y`. Resultado: a estática dos descendentes
// ficava congelada em ~0, e um absoluto sem `top` (que usa exatamente a estática)
// nascia no topo do documento.
//
// ⚠️ O recorte que custou uma rodada: ao passar a mover a estática, a do PRÓPRIO
// elemento posicionado não pode ir junto — ela é quem ORIGINOU o `y`, então somá-la
// de volta faz a caixa descer um degrau por passe de layout (no github o hero caiu
// 164→328). `place_absolute` salva e restaura só a do topo da subárvore; o teste
// `..._nao_desce_a_cada_passe` é o que trava isso.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay213 :: proc(html: string, passes := 1, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    page := Rect{0, 0, vw, vh}
    for _ in 0 ..< passes {
        layout_box(root, 0, 0, vw)
        layout_absolutes(root, page, page)
    }
    return root
}

@(private = "file")
find_id213 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_id213(c, id); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_id213(it.box, id); r != nil do return r
        }
    }
    return nil
}

@(test)
m213_absoluto_sem_top_dentro_de_absoluto :: proc(t: ^testing.T) {
    // A forma do github: pai absoluto ancorado longe do topo (top:500 no CB), filho
    // absoluto SEM top — que deve cair na estática, ou seja, junto do pai.
    src := `<body style="margin:0"><div style="position:relative;height:2000px">
        <div id="pai" style="position:absolute;top:500px;left:0;width:100%">
            <div id="filho" style="position:absolute;width:100px;height:100px"></div>
        </div>
    </div></body>`
    pai   := find_id213(lay213(src), "pai")
    filho := find_id213(lay213(src), "filho")
    testing.expect(t, pai != nil && filho != nil, "achou pai e filho")
    if pai == nil || filho == nil do return
    testing.expect_value(t, pai.y, f32(500))
    testing.expect_value(t, filho.y, f32(500)) // era 0
}

@(test)
m213_estatica_do_filho_acompanha_irmao_em_fluxo :: proc(t: ^testing.T) {
    // Mesma coisa com conteúdo ANTES do filho: a estática é depois do irmão, e
    // continua sendo relativa ao pai já colocado.
    src := `<body style="margin:0"><div style="position:relative;height:2000px">
        <div id="pai" style="position:absolute;top:300px;left:0;width:100%">
            <div style="height:40px"></div>
            <div id="filho" style="position:absolute;width:10px;height:10px"></div>
        </div>
    </div></body>`
    testing.expect_value(t, find_id213(lay213(src), "filho").y, f32(340))
}

@(test)
m213_nao_desce_a_cada_passe :: proc(t: ^testing.T) {
    // CONTROLE do recorte: mover a estática do PRÓPRIO posicionado somaria o `y` de
    // volta nela e a caixa desceria a cada passe (500 → 1000 → …).
    src := `<body style="margin:0"><div style="position:relative;height:2000px">
        <div id="pai" style="position:absolute;top:500px;left:0;width:100%">
            <div id="filho" style="position:absolute;width:100px;height:100px"></div>
        </div>
    </div></body>`
    for passes in ([]int{1, 2, 5}) {
        root := lay213(src, passes)
        p := find_id213(root, "pai"); f := find_id213(root, "filho")
        testing.expect(t, p != nil && f != nil, "achou nos N passes")
        if p == nil || f == nil do continue
        testing.expect_value(t, p.y, f32(500))
        testing.expect_value(t, f.y, f32(500))
    }
}

@(test)
m213_fixed_sem_top_tambem_nao_desce :: proc(t: ^testing.T) {
    // O mesmo pelo caminho do FIXED (o hero do github caiu 164→328 aqui).
    src := `<body style="margin:0">
        <div style="height:164px"></div>
        <div id="alvo" style="position:fixed;width:100%;height:40px"></div>
        <div style="height:3000px"></div>
    </body>`
    for passes in ([]int{1, 2, 5}) {
        testing.expect_value(t, find_id213(lay213(src, passes), "alvo").y, f32(164))
    }
}

@(test)
m213_absoluto_com_top_continua_no_inset :: proc(t: ^testing.T) {
    // CONTROLE: quem tem `top` não depende da estática — não pode ter mudado.
    src := `<body style="margin:0"><div style="position:relative;height:2000px">
        <div id="pai" style="position:absolute;top:500px;left:0;width:100%;height:200px">
            <div id="filho" style="position:absolute;top:25px;width:10px;height:10px"></div>
        </div>
    </div></body>`
    testing.expect_value(t, find_id213(lay213(src, 1), "filho").y, f32(525))
    testing.expect_value(t, find_id213(lay213(src, 3), "filho").y, f32(525))
}
