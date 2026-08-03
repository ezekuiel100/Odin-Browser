package ui

// stroke-dasharray / stroke-dashoffset.
//
// A geometria do tracejado é FUNÇÃO PURA (polilinha de tela + padrão em px →
// peças acesas), então dá p/ afirmar coordenadas sem janela, sem atlas de fonte
// e sem global — ao contrário de tudo que depende de métrica de texto. É o mesmo
// padrão dos helpers `test_clip_hit`/`test_mask_alpha`.
//
// As afirmações da ponte CSS (`stroke-dasharray` vindo de REGRA) NÃO moram aqui:
// tocam o global `g_svg_css` e por isso vivem no @(test) único de
// style_lote23_test.odin.

import "core:testing"
import "core:math"
import im "../../vendor/imgui"

@(private = "file")
neard :: proc(a, b: f32, tol: f32 = 0.01) -> bool { return abs(a - b) <= tol }

// Comprimento total ACESO — o invariante mais forte do tracejado: para um padrão
// `d g`, a soma dos traços tem de ser ~ comprimento × d/(d+g).
@(private = "file")
lit_len :: proc(pieces: [][]im.Vec2) -> f32 {
    total: f32 = 0
    for p in pieces {
        for i in 0 ..< len(p) - 1 {
            dx, dy := p[i + 1].x - p[i].x, p[i + 1].y - p[i].y
            total += math.sqrt(dx * dx + dy * dy)
        }
    }
    return total
}

// Literal composto de slice vive na pilha do PROC — devolvê-lo de um helper é
// erro do compilador, então a linha de teste é um global imutável.
@(private = "file")
LINE100 := [2]im.Vec2{{0, 0}, {100, 0}}

@(private = "file")
line100 :: proc() -> []im.Vec2 { return LINE100[:] }

@(test)
test_svg_dash_parse :: proc(t: ^testing.T) {
    // lista par simples, nas DUAS grafias de separador
    a1, n1, k1 := svg_parse_dasharray("4 2", svg_user_num, 0, 0, 0)
    testing.expect(t, k1 && n1 == 2 && a1[0] == 4 && a1[1] == 2, "`4 2`")
    a2, n2, k2 := svg_parse_dasharray("4,2", svg_user_num, 0, 0, 0)
    testing.expect(t, k2 && n2 == 2 && a2[0] == 4 && a2[1] == 2, "vírgula é separador igual ao espaço")
    a3, n3, _ := svg_parse_dasharray(" 4 ,  2 ", svg_user_num, 0, 0, 0)
    testing.expect(t, n3 == 2 && a3[0] == 4 && a3[1] == 2, "vírgula E espaço juntos não geram item vazio")

    // lista ÍMPAR é REPETIDA p/ virar par (spec). Sem isso `stroke-dasharray:5`
    // — grafia comum — não teria vão nenhum e sairia sólido.
    a4, n4, _ := svg_parse_dasharray("5", svg_user_num, 0, 0, 0)
    testing.expectf(t, n4 == 2 && a4[0] == 5 && a4[1] == 5, "`5` = `5 5`; veio n=%d", n4)
    a5, n5, _ := svg_parse_dasharray("4 2 1", svg_user_num, 0, 0, 0)
    testing.expectf(t, n5 == 6 && a5[3] == 4 && a5[5] == 1, "`4 2 1` = `4 2 1 4 2 1`; veio n=%d", n5)

    // `none` e os ERROS de spec: todos viram SÓLIDO (n=0) com ok=true, que é
    // DISTINTO de inválido — `none` precisa poder CANCELAR um valor herdado.
    _, n6, k6 := svg_parse_dasharray("none", svg_user_num, 0, 0, 0)
    testing.expect(t, k6 && n6 == 0, "`none` = sólido, declarado")
    _, n7, k7 := svg_parse_dasharray("-3 2", svg_user_num, 0, 0, 0)
    testing.expect(t, k7 && n7 == 0, "valor negativo é erro per-spec → sólido")
    _, n8, k8 := svg_parse_dasharray("0 0", svg_user_num, 0, 0, 0)
    testing.expect(t, k8 && n8 == 0, "soma zero = `none`")

    // token que não é número: declaração INVÁLIDA (ok=false) — o chamador não
    // escreve nada e o valor herdado do <g> continua valendo.
    _, _, k9 := svg_parse_dasharray("4 banana", svg_user_num, 0, 0, 0)
    testing.expect(t, !k9, "token inválido não pode virar `none` silencioso")

    // CONTRA-CASO do zero: `0 8` é VÁLIDO (é o idioma da linha pontilhada) e não
    // pode cair no mesmo balde de "soma zero"
    a10, n10, k10 := svg_parse_dasharray("0 8", svg_user_num, 0, 0, 0)
    testing.expect(t, k10 && n10 == 2 && a10[0] == 0 && a10[1] == 8, "`0 8` = pontilhado, não `none`")
}

@(test)
test_svg_dash_geometria :: proc(t: ^testing.T) {
    // 100px de linha com padrão 10/10 → 5 traços de 10, começando em 0
    pieces, ok := svg_dash_pieces(line100(), false, {10, 10}, 0)
    testing.expect(t, ok, "padrão normal não pode estourar o teto de peças")
    testing.expectf(t, len(pieces) == 5, "esperado 5 traços em 100px com 10/10; veio %d", len(pieces))
    testing.expectf(t, neard(lit_len(pieces), 50), "metade acesa = 50px; veio %v", lit_len(pieces))
    if len(pieces) == 5 {
        testing.expectf(t, neard(pieces[0][0].x, 0) && neard(pieces[0][1].x, 10),
            "1º traço [0,10]; veio [%v,%v]", pieces[0][0].x, pieces[0][1].x)
        testing.expectf(t, neard(pieces[1][0].x, 20) && neard(pieces[1][1].x, 30),
            "2º traço [20,30]; veio [%v,%v]", pieces[1][0].x, pieces[1][1].x)
    }

    // padrão assimétrico: 25% aceso
    p2, _ := svg_dash_pieces(line100(), false, {5, 15}, 0)
    testing.expectf(t, neard(lit_len(p2), 25), "5/15 acende 25%% de 100; veio %v", lit_len(p2))
}

@(test)
test_svg_dash_offset :: proc(t: ^testing.T) {
    // offset POSITIVO avança DENTRO do padrão: com 10/10 e offset 10 a linha
    // começa no VÃO, então o 1º traço é [10,20].
    p1, _ := svg_dash_pieces(line100(), false, {10, 10}, 10)
    testing.expect(t, len(p1) > 0, "offset não pode apagar o traço")
    if len(p1) > 0 {
        testing.expectf(t, neard(p1[0][0].x, 10) && neard(p1[0][1].x, 20),
            "offset 10 → 1º traço [10,20]; veio [%v,%v]", p1[0][0].x, p1[0][1].x)
    }

    // offset NEGATIVO enrola pelo fim do padrão: -5 ≡ 15 num período de 20, que
    // cai no VÃO com 5 restantes → o 1º traço vai de 5 a 15.
    // ⚠️ minha expectativa aqui era [0,5] e estava ERRADA: offset positivo desliza
    // o padrão p/ TRÁS (por isso `10` empurra o traço p/ [10,20]), logo o negativo
    // desliza p/ a FRENTE. O par de casos deste proc é o que trava o sinal.
    p2, _ := svg_dash_pieces(line100(), false, {10, 10}, -5)
    if len(p2) > 0 {
        testing.expectf(t, neard(p2[0][0].x, 5) && neard(p2[0][1].x, 15),
            "offset -5 → 1º traço [5,15]; veio [%v,%v]", p2[0][0].x, p2[0][1].x)
    }

    // offset de um PERÍODO inteiro é idêntico a offset 0 (o padrão é cíclico)
    a, _ := svg_dash_pieces(line100(), false, {10, 10}, 0)
    b, _ := svg_dash_pieces(line100(), false, {10, 10}, 20)
    testing.expectf(t, len(a) == len(b) && neard(lit_len(a), lit_len(b)),
        "offset de 1 período = offset 0; veio %d vs %d peças", len(a), len(b))
}

@(test)
test_svg_dash_forma :: proc(t: ^testing.T) {
    // VÉRTICE PRESERVADO: um traço que passa pela quina continua sendo polilinha
    // (3 pontos), não uma corda reta entre as pontas.
    l := []im.Vec2{{0, 0}, {10, 0}, {10, 10}} // 20px em L
    p, _ := svg_dash_pieces(l, false, {15, 5}, 0)
    testing.expect(t, len(p) >= 1, "deveria haver um traço")
    if len(p) >= 1 {
        testing.expectf(t, len(p[0]) == 3, "traço que cruza a quina tem 3 pontos; veio %d", len(p[0]))
        if len(p[0]) == 3 {
            testing.expect(t, neard(p[0][1].x, 10) && neard(p[0][1].y, 0), "o ponto do meio É a quina")
            testing.expect(t, neard(p[0][2].y, 5), "termina 5px depois da quina, no outro eixo")
        }
    }

    // FECHADO: o segmento de fechamento também é tracejado. Quadrado 10×10 =
    // perímetro 40; com 5/5 acende metade.
    sq := []im.Vec2{{0, 0}, {10, 0}, {10, 10}, {0, 10}}
    pc, _ := svg_dash_pieces(sq, true, {5, 5}, 0)
    testing.expectf(t, neard(lit_len(pc), 20, 0.1),
        "perímetro 40 com 5/5 acende 20; veio %v", lit_len(pc))
    // CONTRA-CASO: sem fechar, o caminho é 30 (falta o lado de volta) → 15
    po, _ := svg_dash_pieces(sq, false, {5, 5}, 0)
    testing.expectf(t, neard(lit_len(po), 15, 0.1),
        "aberto tem 30 de caminho → 15 aceso; veio %v", lit_len(po))
}

@(test)
test_svg_dash_pontilhado_e_teto :: proc(t: ^testing.T) {
    // `0 10` = traço de comprimento ZERO, o idioma da linha PONTILHADA (só
    // aparece com linecap round). Sai como peça de UM ponto.
    p, ok := svg_dash_pieces(line100(), false, {0, 10}, 0)
    testing.expect(t, ok, "pontilhado é padrão válido")
    dots := 0
    for pc in p do if len(pc) == 1 do dots += 1
    testing.expectf(t, dots >= 10, "esperado ~11 pontos a cada 10px; veio %d (peças %d)", dots, len(p))
    testing.expectf(t, neard(lit_len(p), 0), "ponto não tem comprimento; veio %v", lit_len(p))

    // ⚠️ e NENHUM ponto espúrio na ponta: com 10/10 o caminho acaba logo depois
    // de um vão fechar, e a peça aberta que sobra não pode virar um ponto.
    p2, _ := svg_dash_pieces(line100(), false, {10, 10}, 0)
    for pc in p2 do testing.expectf(t, len(pc) >= 2, "peça de 1 ponto no fim = artefato; veio %d pontos", len(pc))

    // TETO: padrão minúsculo em caminho longo devolve ok=false p/ o chamador
    // cair em SÓLIDO — desenhar as peças parciais seria pior.
    long := []im.Vec2{{0, 0}, {100000, 0}}
    _, ok2 := svg_dash_pieces(long, false, {0.5, 0.5}, 0)
    testing.expect(t, !ok2, "100k px com período 1 tem de estourar o teto")
}
