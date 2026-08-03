package ui

// M243 — a família `border` resolvida no nível do ÁTOMO (lado × sub-propriedade).
//
// O desempate do M241 é pairwise ANCESTRAL→DESCENDENTE, e a borda é a única
// família com IRMÃOS que se sobrepõem: `border-top` e `border-width` não se
// contêm, mas os dois escrevem `border-top-width`. Com pairwise, quem decidia
// era a ordem fixa do apply_decls (border-<lado> no passo 2, border-<sub> no
// passo 3) e um dos dois sentidos saía errado.
//
// 💡 O conserto NÃO apaga shorthand nenhum: os 12 longhands por lado rodam no
// passo 4, então basta EMITIR o átomo vencedor e ele passa por cima. Com isso
// `has_border`, a regra da LARGURA OMITIDA (`medium`) e o `style_none` seguem
// vindo do caminho de sempre — não-regressão por construção.
//
// A treliça tem quatro fontes por átomo:
//   border                → 4 lados × 3 subs
//   border-<lado>         → 1 lado  × 3 subs
//   border-<sub>          → 4 lados × 1 sub
//   border-<lado>-<sub>   → o átomo

import "core:testing"

// ── os dois sentidos do conflito de IRMÃOS ──────────────────────────────────

@(test)
m243_irmaos_por_ordem_de_fonte :: proc(t: ^testing.T) {
    // border-width depois → vence o topo
    a := test_compute_one(".x{border-top:9px solid red} .y{border-width:2px}", "div", "x y")
    testing.expectf(t, a.border_w == [4]f32{2, 2, 2, 2}, "border-width DEPOIS leva os 4 lados; veio %v", a.border_w)

    // border-top depois → vence SÓ o topo, os outros ficam com border-width
    b := test_compute_one(".x{border-width:2px} .y{border-top:9px solid red}", "div", "x y")
    testing.expectf(t, b.border_w == [4]f32{9, 2, 2, 2},
        "border-top DEPOIS vence só o topo; esperava [9 2 2 2], veio %v", b.border_w)
}

@(test)
m243_irmaos_por_especificidade :: proc(t: ^testing.T) {
    // border-top é MAIS específico e vem ANTES: tem de vencer mesmo assim — é o
    // caso que a ordem fixa nunca conseguiria acertar.
    c := test_compute_one(".x.z{border-top:9px solid red} .y{border-width:2px}", "div", "x y z")
    testing.expectf(t, c.border_w == [4]f32{9, 2, 2, 2},
        "border-top mais ESPECÍFICO vence o topo mesmo vindo antes; veio %v", c.border_w)
}

@(test)
m243_cada_sub_propriedade_e_independente :: proc(t: ^testing.T) {
    // A cor vem de um irmão, a largura de outro, e o estilo de um terceiro —
    // cada átomo tem de escolher o seu vencedor sozinho.
    c := test_compute_one(
        ".x{border-color:#00ff00} .y{border-top:9px solid #ff0000} .z{border-width:2px}",
        "div", "x y z")
    testing.expectf(t, c.border_w == [4]f32{2, 2, 2, 2}, "largura: border-width é o último; veio %v", c.border_w)
    testing.expectf(t, c.border_c[0] == 0xff0000,
        "cor do topo: border-top é mais tarde que border-color; veio %x", c.border_c[0])
    testing.expectf(t, c.border_c[1] == 0x00ff00,
        "cor da direita: só border-color escreve nela; veio %x", c.border_c[1])
}

// ── a treliça inteira: os 4 níveis disputando ───────────────────────────────

@(test)
m243_quatro_fontes_no_mesmo_atomo :: proc(t: ^testing.T) {
    // Ordem crescente de fonte; o ÚLTIMO a escrever cada átomo vence.
    c := test_compute_one(
        ".a{border:1px solid black}"    + // 4 lados
        ".b{border-width:2px}"          + // 4 larguras
        ".c{border-top:3px solid blue}" + // topo inteiro
        ".d{border-top-width:4px}",       // o átomo
        "div", "a b c d")
    testing.expectf(t, c.border_w == [4]f32{4, 2, 2, 2},
        "o átomo explícito é o último; esperava [4 2 2 2], veio %v", c.border_w)

    // Agora o átomo vem PRIMEIRO: perde para todos os outros.
    d := test_compute_one(
        ".d{border-top-width:4px}" +
        ".a{border:1px solid black}",
        "div", "a d")
    testing.expectf(t, d.border_w == [4]f32{1, 1, 1, 1},
        "shorthand DEPOIS apaga o átomo; esperava [1 1 1 1], veio %v", d.border_w)
}

@(test)
m243_lado_a_lado_nao_vaza :: proc(t: ^testing.T) {
    // `border-left` não pode encostar no topo — pega tabela que indexa o lado
    // errado (a armadilha clássica do t/r/b/l).
    c := test_compute_one(".a{border-width:2px} .b{border-left:9px solid red}", "div", "a b")
    testing.expectf(t, c.border_w == [4]f32{2, 2, 2, 9},
        "só a ESQUERDA muda; esperava [2 2 2 9], veio %v", c.border_w)
}

@(test)
m243_box4_de_border_width_por_lado :: proc(t: ^testing.T) {
    // `border-width: 1px 2px 3px 4px` tem de alimentar cada átomo com o SEU valor
    // (regra 1-4), não com o primeiro token.
    c := test_compute_one(".a{border-width:1px 2px 3px 4px}", "div", "a")
    testing.expectf(t, c.border_w == [4]f32{1, 2, 3, 4}, "regra 1-4 por lado; veio %v", c.border_w)

    // e com dois valores: t/b = 1, r/l = 2 — aqui já com um irmão em jogo, que é
    // o caminho novo (com uma declaração só a família nem passa pelo M243).
    d := test_compute_one(".a{border-width:1px 2px} .b{border-top:5px solid red}", "div", "a b")
    testing.expectf(t, d.border_w == [4]f32{5, 2, 1, 2}, "1-4 com dois valores + irmão; veio %v", d.border_w)
}

// ── CONTROLES: o que NÃO pode ter mudado ────────────────────────────────────

@(test)
m243_declaracao_unica_intocada :: proc(t: ^testing.T) {
    // Com UMA declaração da família o bloco nem roda — o caminho antigo fica
    // exatamente como estava. Inclui a regra da LARGURA OMITIDA (`medium`=3px),
    // que é justamente o que se perderia se eu tivesse apagado o shorthand.
    a := test_compute_one(".a{border:solid red}", "div", "a")
    testing.expectf(t, a.border_w == [4]f32{3, 3, 3, 3},
        "estilo sem largura = medium (3px); veio %v", a.border_w)

    b := test_compute_one(".a{border:1px solid red}", "div", "a")
    testing.expectf(t, b.border_w == [4]f32{1, 1, 1, 1}, "shorthand completo; veio %v", b.border_w)
    testing.expect(t, b.has_border, "has_border segue marcado")
}

@(test)
m243_medium_sobrevive_com_irmao_em_jogo :: proc(t: ^testing.T) {
    // Agora COM o caminho novo ligado: a largura omitida continua virando medium.
    // (o `border:solid red` não emite átomo de largura de propósito — o motor
    // nunca implementou o reset-ao-inicial do shorthand, e o M243 não muda isso)
    c := test_compute_one(".a{border:solid red} .b{border-top-color:blue}", "div", "a b")
    testing.expectf(t, c.border_w == [4]f32{3, 3, 3, 3},
        "medium sobrevive à resolução por átomo; veio %v", c.border_w)
    testing.expectf(t, c.border_c[0] == 0x0000ff, "o átomo de cor do topo vence; veio %x", c.border_c[0])
}

@(test)
m243_none_nao_vira_borda :: proc(t: ^testing.T) {
    // `border:none` depois de uma borda real tem de APAGAR o traço, não virar
    // 3px invisível (seria o efeito de emitir `medium` para largura omitida).
    c := test_compute_one(".a{border-top:5px solid red} .b{border:none}", "div", "a b")
    testing.expect(t, c.border_style_none[0], "border:none marca o topo como sem estilo")
}

@(test)
m243_var_cai_no_pairwise :: proc(t: ^testing.T) {
    // `var()` não se fatia por texto aqui (o `vars` só existe no apply_decls), e
    // aí desistimos da resolução por átomo — DECLARADO, não silencioso. O que se
    // afirma é que o resultado segue sendo o do caminho antigo, não lixo.
    c := test_compute_one(
        ":root{--w:7px} .a{border-width:2px} .b{border-top:var(--w) solid red}", "div", "a b")
    testing.expect(t, c.border_w[1] == 2, "os outros lados seguem vindo do border-width")
}

@(test)
m243_empate_no_mesmo_bloco_vai_para_o_mais_especifico :: proc(t: ^testing.T) {
    // ⚠️⚠️ Todo `style=""` inline é UM bloco: as declarações chegam com spec E
    // ordem IGUAIS (o `wins` não guarda ordem por-declaração). No empate tem de
    // vencer a mais específica em ALCANCE, que é o que a ordem fixa do
    // apply_border_props já fazia. Com desempate `>` estrito o `border` genérico
    // ganhava do `border-top` escrito ao lado.
    //
    // Reduzido do WPT css-multicol/auto-fill-auto-size-001-print: lá a caixa
    // vazia passou de 0 para 20px de altura porque as bordas que deviam ser
    // `none` voltaram a valer 10px.
    c := test_compute_one("", "div", "",
        "border:10px solid red; border-top:none; border-bottom:none")
    testing.expect(t, c.border_style_none[0], "topo tem de ficar SEM estilo (border-top:none)")
    testing.expect(t, c.border_style_none[2], "base tem de ficar SEM estilo (border-bottom:none)")
    testing.expect(t, !c.border_style_none[3], "CONTROLE: a esquerda segue com o solid do shorthand")

    // mesma coisa em REGRA (não inline), onde a ordem de fonte é real e distinta
    r := test_compute_one(".a{border:10px solid red; border-top:none}", "div", "a")
    testing.expect(t, r.border_style_none[0], "em regra também: border-top:none vence o shorthand ao lado")
}

@(test)
m243_radius_nao_entra_na_familia :: proc(t: ^testing.T) {
    // `border-radius` começa com "border-" mas é árvore de DOIS níveis, sem
    // irmãos: tem de continuar no desempate pairwise do M241.
    c := test_compute_one(".a.b{border-radius:0} .p{border-top-left-radius:12px}", "div", "a b p")
    testing.expectf(t, c.border_radius[0] == 0,
        "border-radius mais específico segue apagando o canto; veio %v", c.border_radius[0])
}
