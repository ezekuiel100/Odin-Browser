package ui

// Índice de regras por atributo / :is(), filtro de ancestrais e memo de
// variáveis: as três otimizações do compute_styles de 12/11. Cada teste é um
// caso em que a otimização, ERRADA, mudaria o resultado — e o oráculo
// `-define:STYLECHECK=true` cobre o resto em site real.

import "core:testing"
import dom "../dom"
import html "../html"
import css "../css"

@(private="file")
idx_styles :: proc(markup, sheet: string, vw: f32 = 400) -> (doc: ^dom.Node, styles: map[^dom.Node]Computed, rules: [dynamic]css.Rule) {
    doc = html.parse(markup)
    kf: [dynamic]css.Keyframe_Set
    rules, kf = css.parse(sheet)
    css.free_keyframes(&kf)
    styles, _ = compute_styles(doc, &rules, vw, 300)
    return
}

@(private="file")
idx_free :: proc(doc: ^dom.Node, styles: map[^dom.Node]Computed, rules: ^[dynamic]css.Rule) {
    free_styles(styles)
    css.free_rules(rules)
    dom.free_tree(doc)
}

@(private="file")
by_id :: proc(doc: ^dom.Node, id: string) -> ^dom.Node {
    walk :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
        if n.kind == .Element {
            if v, ok := n.attrs["id"]; ok && v == id do return n
        }
        for c in n.children do if r := walk(c, id); r != nil do return r
        return nil
    }
    return walk(doc, id)
}

// Dois pais com `--a` DIFERENTE e filhos com a MESMA classe declarando o MESMO
// `--b`: o memo pode dividir o mapa entre irmãos, nunca entre primos. Com a
// chave sem a identidade do pai (`-define:SABOTAGE_MEMO=true`), o 2º filho
// herdaria o vermelho do 1º.
@(test)
style_vars_memo_respeita_o_pai :: proc(t: ^testing.T) {
    doc, styles, rules := idx_styles(
        `<div style="--a:#ff0000"><p id="p1" class="x"></p><p id="p2" class="x"></p></div>` +
        `<div style="--a:#0000ff"><p id="p3" class="x"></p></div>` +
        `<div style="--a:#00ff00"><p id="p4" class="y"></p></div>`,
        `.x{--b:1px;color:var(--a)} .y{--a:#00ff00;color:var(--a)}`)
    defer idx_free(doc, styles, &rules)
    testing.expect_value(t, styles[by_id(doc, "p1")].color, u32(0xff0000))
    testing.expect_value(t, styles[by_id(doc, "p2")].color, u32(0xff0000))
    testing.expect_value(t, styles[by_id(doc, "p3")].color, u32(0x0000ff))
    // redeclarar com o MESMO valor herdado não clona — e continua certo
    testing.expect_value(t, styles[by_id(doc, "p4")].color, u32(0x00ff00))
}

// Balde por NOME de atributo: casa quem tem o atributo (com qualquer operador),
// não casa quem não tem, e vale também como chave de ANCESTRAL.
@(test)
style_index_por_atributo :: proc(t: ^testing.T) {
    doc, styles, rules := idx_styles(
        `<div id="a" data-k="v"></div><div id="b" data-k="w"></div><div id="c"></div>` +
        `<section data-theme="dark"><span id="d"></span></section><section><span id="e"></span></section>`,
        `[data-k]{width:10px} [data-k="v"]{height:7px} [data-theme=dark] span{color:#ff0000}`)
    defer idx_free(doc, styles, &rules)
    testing.expect_value(t, styles[by_id(doc, "a")].width, f32(10))
    testing.expect_value(t, styles[by_id(doc, "a")].height, f32(7))
    testing.expect_value(t, styles[by_id(doc, "b")].width, f32(10))
    testing.expect(t, !styles[by_id(doc, "b")].has_height)
    testing.expect(t, !styles[by_id(doc, "c")].has_width)
    testing.expect_value(t, styles[by_id(doc, "d")].color, u32(0xff0000))
    testing.expect(t, styles[by_id(doc, "e")].color != u32(0xff0000))
}

// :is()/:where() entram no balde de CADA argumento — e um argumento sem chave
// manda a regra inteira p/ o universal (não pode sumir).
@(test)
style_index_is_where :: proc(t: ^testing.T) {
    doc, styles, rules := idx_styles(
        `<div id="a" class="ka"></div><div id="kb"></div><span id="c"></span><i id="d" class="kd"></i>` +
        `<ul class="list"><li id="e"></li></ul><p id="f"></p>`,
        `:where(.ka, #kb, span){width:11px} :is(:not(.zz), .kd){height:3px} :is(.list li){width:12px}`)
    defer idx_free(doc, styles, &rules)
    testing.expect_value(t, styles[by_id(doc, "a")].width, f32(11))
    testing.expect_value(t, styles[by_id(doc, "kb")].width, f32(11))
    testing.expect_value(t, styles[by_id(doc, "c")].width, f32(11))
    testing.expect(t, !styles[by_id(doc, "d")].has_width)
    testing.expect_value(t, styles[by_id(doc, "d")].height, f32(3)) // arg sem chave: universal
    testing.expect_value(t, styles[by_id(doc, "f")].height, f32(3))
    testing.expect_value(t, styles[by_id(doc, "e")].width, f32(12))
}

// @media que não casa fica FORA do índice, e o índice é refeito por viewport.
@(test)
style_index_media_por_viewport :: proc(t: ^testing.T) {
    sheet := `@media (max-width: 100px){div{width:5px}} @media (min-width: 300px){div{height:9px}}`
    {
        doc, styles, rules := idx_styles(`<div id="a"></div>`, sheet, 400)
        defer idx_free(doc, styles, &rules)
        testing.expect(t, !styles[by_id(doc, "a")].has_width)
        testing.expect_value(t, styles[by_id(doc, "a")].height, f32(9))
    }
    {
        doc, styles, rules := idx_styles(`<div id="a"></div>`, sheet, 80)
        defer idx_free(doc, styles, &rules)
        testing.expect_value(t, styles[by_id(doc, "a")].width, f32(5))
        testing.expect(t, !styles[by_id(doc, "a")].has_height)
    }
}

// Filtro de ancestrais: `+`/`~` ligam IRMÃOS, que não são ancestrais — o
// composto à esquerda deles não pode virar exigência (`-define:SABOTAGE_ANC`
// exige e derruba os dois primeiros casos). O que vem à esquerda de um ` `/`>`
// é ancestral mesmo, inclusive atrás de um irmão (`A B + C`: A é ancestral de C).
@(test)
style_filtro_de_ancestrais :: proc(t: ^testing.T) {
    doc, styles, rules := idx_styles(
        `<div class="sib"></div><section class="box"><p id="a"></p></section>` +
        `<h2 class="h"></h2><div class="b"><i id="b"></i></div>` +
        `<main class="m"><em class="e"></em><b id="c"></b></main>` +
        `<article class="out"><div><span id="d"></span></div></article><span id="e"></span>`,
        `.sib ~ .box p{width:1px} .h + .b > i{width:2px} .m .e + b{width:3px} .out span{width:4px} .out > span{height:4px}`)
    defer idx_free(doc, styles, &rules)
    testing.expect_value(t, styles[by_id(doc, "a")].width, f32(1))
    testing.expect_value(t, styles[by_id(doc, "b")].width, f32(2))
    testing.expect_value(t, styles[by_id(doc, "c")].width, f32(3))
    testing.expect_value(t, styles[by_id(doc, "d")].width, f32(4))
    testing.expect(t, !styles[by_id(doc, "d")].has_height) // `>`: o pai é <div>, não .out
    testing.expect(t, !styles[by_id(doc, "e")].has_width)
}

// compute_styles numa SUBÁRVORE: os ancestrais reais (fora da recursão) contam
// p/ o matcher, então o filtro tem de se desligar em vez de rejeitar.
@(test)
style_filtro_desliga_fora_da_cadeia :: proc(t: ^testing.T) {
    doc := html.parse(`<div class="outer"><section id="s"><span id="x"></span></section></div>`)
    defer dom.free_tree(doc)
    rules, kf := css.parse(`.outer span{width:6px}`)
    defer { css.free_rules(&rules); css.free_keyframes(&kf) }
    sub := by_id(doc, "s")
    styles, _ := compute_styles(sub, &rules, 400, 300)
    defer free_styles(styles)
    testing.expect_value(t, styles[by_id(doc, "x")].width, f32(6))
}
