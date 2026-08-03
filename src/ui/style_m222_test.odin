package ui

// M222 — unidades de viewport dinâmicas (`dvh`/`svh`/`lvh` e família) e
// `min()/max()/clamp()` MISTO (% junto com px/rem/vw).
//
// Antes: `height: 100dvh` e `width: min(100%, 1200px)` eram DESCARTADOS pelo
// parse_len — a declaração inteira caía e o elemento ficava sem a propriedade.

import "core:testing"
import "core:fmt"
import htmlp "../html"
import csspkg "../css"

// ── unidades de viewport ────────────────────────────────────────────────────
// test_apply usa o viewport default de apply_decls: 1280×720.

@(test)
test_m222_viewport_dinamico_altura :: proc(t: ^testing.T) {
    unidades := []string{"vh", "dvh", "svh", "lvh", "vb", "dvb", "svb", "lvb"}
    for u in unidades {
        c := test_apply(fmt.tprintf("height: 50%s", u))
        testing.expectf(t, c.has_height && c.height == 360,
            "50%s deveria dar 360 (metade de 720); veio has=%v h=%v", u, c.has_height, c.height)
    }
}

@(test)
test_m222_viewport_dinamico_largura :: proc(t: ^testing.T) {
    unidades := []string{"vw", "dvw", "svw", "lvw", "vi", "dvi", "svi", "lvi"}
    for u in unidades {
        c := test_apply(fmt.tprintf("width: 50%s", u))
        testing.expectf(t, c.has_width && !c.width_pct && c.width == 640,
            "50%s deveria dar 640 (metade de 1280); veio has=%v w=%v", u, c.has_width, c.width)
    }
}

@(test)
test_m222_viewport_min_max :: proc(t: ^testing.T) {
    // vmin/vmax = menor/maior eixo; 1280×720 ⇒ vmin usa 720, vmax usa 1280
    menores := []string{"vmin", "dvmin", "svmin", "lvmin"}
    for u in menores {
        c := test_apply(fmt.tprintf("width: 10%s", u))
        testing.expectf(t, c.has_width && c.width == 72, "10%s esperado 72, veio %v", u, c.width)
    }
    maiores := []string{"vmax", "dvmax", "svmax", "lvmax"}
    for u in maiores {
        c := test_apply(fmt.tprintf("width: 10%s", u))
        testing.expectf(t, c.has_width && c.width == 128, "10%s esperado 128, veio %v", u, c.width)
    }
}

@(test)
test_m222_viewport_dinamico_em_font_size :: proc(t: ^testing.T) {
    // parse_font_size tem o SEU switch de unidades — é um segundo sítio, e
    // esquecê-lo deixaria `font-size: 5dvh` cair calado.
    c := test_apply("font-size: 5dvh")
    testing.expectf(t, c.has_font_size && c.font_size == 36, "5dvh esperado 36, veio %v", c.font_size)
}

@(test)
test_m222_unidade_desconhecida_continua_caindo :: proc(t: ^testing.T) {
    // controle: o ramo de falha do parse_len tem de continuar existindo, senão os
    // testes acima passariam por acidente (qualquer unidade viraria px).
    c := test_apply("height: 100qzx")
    testing.expect(t, !c.has_height, "unidade inventada não pode ser aceita")
}

// ── min/max/clamp misto ─────────────────────────────────────────────────────

@(private = "file")
clamped :: proc(v: string) -> (off, pct: f32, bd: Len_Bounds, ok: bool) {
    return parse_len_clamped(v, 16, 1280, 720)
}

@(test)
test_m222_min_misto :: proc(t: ^testing.T) {
    off, pct, bd, ok := clamped("min(50%, 300px)")
    testing.expect(t, ok, "min misto deveria parsear (antes caía)")
    testing.expectf(t, pct == 0.5 && off == 0, "esperado 50%% sem offset; veio pct=%v off=%v", pct, off)
    testing.expect(t, bd.has, "deveria ter limite")
    testing.expectf(t, bd.hi == 300, "min(): o absoluto é TETO; hi esperado 300, veio %v", bd.hi)
    // vários absolutos: o teto é o MENOR deles
    _, _, bd2, ok2 := clamped("min(50%, 300px, 200px)")
    testing.expect(t, ok2 && bd2.hi == 200, "teto = menor absoluto")
}

@(test)
test_m222_max_misto :: proc(t: ^testing.T) {
    off, pct, bd, ok := clamped("max(50%, 300px)")
    testing.expect(t, ok, "max misto deveria parsear")
    testing.expectf(t, pct == 0.5 && off == 0, "pct=%v off=%v", pct, off)
    testing.expectf(t, bd.has && bd.lo == 300, "max(): o absoluto é PISO; lo=%v", bd.lo)
}

@(test)
test_m222_clamp_misto_nas_3_posicoes :: proc(t: ^testing.T) {
    // clamp(A,B,C) ≡ max(A, min(B,C)) — a % pode estar em QUALQUER das 3 posições
    // e as três reduzem à mesma forma linear-com-limites.
    _, p1, b1, ok1 := clamped("clamp(320px, 90%, 1200px)")
    testing.expect(t, ok1 && p1 == 0.9, "% no meio")
    testing.expectf(t, b1.lo == 320 && b1.hi == 1200, "lo=%v hi=%v", b1.lo, b1.hi)

    _, p2, b2, ok2 := clamped("clamp(50%, 400px, 800px)")
    testing.expect(t, ok2 && p2 == 0.5, "% na 1ª posição = piso percentual")
    testing.expectf(t, b2.lo == 400, "max(P, min(400,800)) ⇒ lo=400; veio %v", b2.lo)

    _, p3, b3, ok3 := clamped("clamp(100px, 400px, 50%)")
    testing.expect(t, ok3 && p3 == 0.5, "% na 3ª posição")
    testing.expectf(t, b3.lo == 100 && b3.hi == 400, "max(100, min(400,P)) ⇒ [100,400]; veio %v %v", b3.lo, b3.hi)
}

@(test)
test_m222_misto_com_calc_e_unidades :: proc(t: ^testing.T) {
    // a forma que o Tailwind/containers usam: calc com % dentro do min
    off, pct, bd, ok := clamped("min(calc(100% - 2rem), 60rem)")
    testing.expect(t, ok, "calc com % dentro de min")
    testing.expectf(t, pct == 1 && off == -32, "pct=%v off=%v (2rem=32px)", pct, off)
    testing.expectf(t, bd.hi == 960, "60rem = 960; veio %v", bd.hi)
    // vw conta como ABSOLUTO (é resolvido no parse), então vira limite
    _, _, bd2, ok2 := clamped("min(80%, 50vw)")
    testing.expect(t, ok2 && bd2.has && bd2.hi == 640, "50vw de 1280 = 640 vira teto")
}

@(test)
test_m222_sem_mistura_nao_muda_nada :: proc(t: ^testing.T) {
    // A garantia de não-regressão: sem mistura, parse_len_clamped devolve
    // EXATAMENTE o que parse_len_linear devolvia, e sem limites.
    off, pct, bd, ok := clamped("clamp(1rem, 2vw, 3rem)") // tudo absoluto
    testing.expect(t, ok && !bd.has, "todo-absoluto: sem limites")
    testing.expectf(t, pct == 0 && off == 25.6, "clamp(16, 25.6, 48) = 25.6; veio %v", off)

    off2, pct2, bd2, ok2 := clamped("min(50%, 30%)") // tudo percentual
    testing.expect(t, ok2 && !bd2.has, "todo-percentual: sem limites")
    testing.expectf(t, pct2 == 0.3 && off2 == 0, "menor fração; veio %v", pct2)

    off3, pct3, bd3, ok3 := clamped("calc(100% - 40px)") // nem é min/max/clamp
    testing.expect(t, ok3 && !bd3.has, "calc puro: sem limites")
    testing.expectf(t, pct3 == 1 && off3 == -40, "pct=%v off=%v", pct3, off3)
}

@(test)
test_m222_retas_que_se_cruzam_continuam_caindo :: proc(t: ^testing.T) {
    // Duas porcentagens com offsets DIFERENTES são retas que se cruzam: não há
    // forma fechada `clamp(lo, frac*base+off, hi)`, então descartamos.
    // ⚠️ Isto MUDA o comportamento anterior — e para melhor: o parse_len devolvia
    // aqui um número sem sentido (somava fração e offset como se a fração fosse
    // px: `min(-9.5, 5.3)` = -9.5px). Descartar é honesto; inventar não é.
    _, _, _, ok := clamped("min(calc(50% - 10px), calc(30% + 5px))")
    testing.expect(t, !ok, "duas retas com offset ⇒ descarta, não chuta")
    _, _, _, ok2 := clamped("clamp(10%, 50%, 90%)")
    testing.expect(t, ok2, "clamp todo-percentual continua valendo (caminho antigo)")
}

@(test)
test_m222_bounds_apply :: proc(t: ^testing.T) {
    vazio: Len_Bounds
    testing.expect(t, bounds_apply(1234, vazio) == 1234, "zero-value NÃO pode grudar em 0")
    b := Len_Bounds{lo = 100, hi = 300, has = true}
    testing.expect(t, bounds_apply(50, b) == 100, "abaixo do piso")
    testing.expect(t, bounds_apply(200, b) == 200, "dentro")
    testing.expect(t, bounds_apply(999, b) == 300, "acima do teto")
    // lo > hi: o piso vence (ordem max(lo, min(hi, x)) da spec do clamp)
    inv := Len_Bounds{lo = 300, hi = 100, has = true}
    testing.expect(t, bounds_apply(0, inv) == 300, "lo > hi ⇒ lo vence")
}

// ── ponta-a-ponta no LAYOUT ─────────────────────────────────────────────────

@(private = "file")
lay222 :: proc(html, css: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    page := Rect{0, 0, vw, vh}
    layout_box(root, 0, 0, vw)
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
find222 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find222(c, id); r != nil do return r
    }
    return nil
}

@(test)
test_m222_layout_min_misto_e_funcao_da_base :: proc(t: ^testing.T) {
    // O ponto que distingue "clamp de verdade" de "constante": o MESMO valor
    // resolve diferente conforme a base. 50% de 800 = 400 → limitado a 300;
    // 50% de 400 = 200 → passa livre.
    css := `#pai{width:800px} #largo{width:min(50%,300px)}
            #pai2{width:400px} #estreito{width:min(50%,300px)}`
    root := lay222(`<div id=pai><div id=largo></div></div><div id=pai2><div id=estreito></div></div>`, css)
    largo := find222(root, "largo")
    estr  := find222(root, "estreito")
    testing.expect(t, largo != nil && estr != nil, "achou as caixas")
    testing.expectf(t, largo.w == 300, "base 800: 50%%=400 limitado a 300; veio %v", largo.w)
    testing.expectf(t, estr.w == 200, "base 400: 50%%=200, abaixo do teto; veio %v", estr.w)
}

@(test)
test_m222_layout_clamp_e_max_width :: proc(t: ^testing.T) {
    css := `#pai{width:1000px} #a{width:clamp(320px,50%,400px)} #b{max-width:min(90%,200px)}`
    root := lay222(`<div id=pai><div id=a></div><div id=b></div></div>`, css)
    a := find222(root, "a")
    b := find222(root, "b")
    testing.expectf(t, a != nil && a.w == 400, "clamp(320,500,400) = 400; veio %v", a != nil ? a.w : -1)
    // #b é bloco (largura auto = 1000) mas com max-width limitado a 200
    testing.expectf(t, b != nil && b.w == 200, "max-width min(90%%,200px) = 200; veio %v", b != nil ? b.w : -1)
}

@(test)
test_m222_layout_dvh :: proc(t: ^testing.T) {
    root := lay222(`<div id=hero></div>`, `#hero{height:100dvh}`, 800, 600)
    h := find222(root, "hero")
    testing.expectf(t, h != nil && h.h == 600, "100dvh no viewport de 600 = 600; veio %v", h != nil ? h.h : -1)
}
