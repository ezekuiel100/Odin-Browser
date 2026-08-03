package ui

// fill-opacity / stroke-opacity — e a geometria que elas EXPUSERAM.
//
// ⚠️⚠️ As duas props já existiam desde o lote 27 e o parse estava certo. O que
// a medição contra o Chrome achou foi outra coisa: com traço TRANSLÚCIDO, a
// geometria EXTRA da ponta e da junta (que existe porque o AddPolyline do ImGui
// só faz ponta reta) era desenhada POR CIMA do próprio traço, e o trecho
// sobreposto compunha o alfa DUAS ou TRÊS vezes — mancha escura na ponta e na
// quina. Com traço opaco o defeito é INVISÍVEL, e foi por isso que sobreviveu
// aos lotes 27, 34 e 35.
//
// Remédio: desenhar só a parte que NÃO se sobrepõe — meio-disco na ponta,
// cunha com arco na junta. Estes testes travam exatamente essa propriedade:
// nenhum ponto da geometria extra pode cair para dentro do traço.

import "core:testing"
import "core:math"
import im "../../vendor/imgui"

@(private = "file")
nearo :: proc(a, b: f32, tol: f32 = 0.01) -> bool { return abs(a - b) <= tol }

@(test)
test_svg_opacity_parse :: proc(t: ^testing.T) {
    // número, porcentagem e o CLAMP de [0,1] (spec: fora da faixa não descarta)
    v1, ok1 := svg_opacity("0.25");  testing.expect(t, ok1 && nearo(v1, 0.25), "número")
    v2, ok2 := svg_opacity("50%");   testing.expect(t, ok2 && nearo(v2, 0.5),  "porcentagem")
    v3, _   := svg_opacity("1.8");   testing.expect(t, nearo(v3, 1), "acima de 1 CLAMPA, não descarta")
    v4, _   := svg_opacity("-3");    testing.expect(t, nearo(v4, 0), "abaixo de 0 CLAMPA a 0 (invisível)")
    _,  ok5 := svg_opacity("banana");testing.expect(t, !ok5, "valor inválido não declara")
}

@(test)
test_svg_cap_nao_invade_o_traco :: proc(t: ^testing.T) {
    // traço horizontal indo para a DIREITA, ponta em (100,0), raio 5.
    // A ponta redonda tem de ficar toda em x >= 100 — qualquer ponto com x < 100
    // estaria EM CIMA do traço, e com stroke-opacity somaria alfa ali.
    arc, ok := svg_half_disc_pts({100, 0}, {0, 0}, 5)
    testing.expect(t, ok, "com direção definida deve produzir o semicírculo")
    if !ok do return
    minx: f32 = 1e9
    maxd: f32 = 0
    for p in arc {
        minx = min(minx, p.x)
        d := math.sqrt((p.x - 100) * (p.x - 100) + p.y * p.y)
        maxd = max(maxd, abs(d - 5))
    }
    testing.expectf(t, minx >= 99.99, "nenhum ponto pode invadir o traço (x < 100); menor x = %v", minx)
    testing.expectf(t, maxd < 0.01, "todos os pontos no raio 5; erro máximo = %v", maxd)

    // e o semicírculo tem de COBRIR a ponta: vai de uma borda à outra do traço
    ys := [2]f32{arc[0].y, arc[len(arc) - 1].y}
    testing.expectf(t, (nearo(ys[0], -5) && nearo(ys[1], 5)) || (nearo(ys[0], 5) && nearo(ys[1], -5)),
        "as pontas do arco são as bordas do traço (±5); veio %v e %v", ys[0], ys[1])

    // CONTRA-CASO: sem direção (pontos iguais) não há semicírculo a computar
    _, ok2 := svg_half_disc_pts({10, 10}, {10, 10}, 5)
    testing.expect(t, !ok2, "sem direção o chamador tem de cair no disco inteiro")
}

@(test)
test_svg_junta_redonda_so_no_vao :: proc(t: ^testing.T) {
    // "Λ": (0,40) → (5,0) → (10,40). O vão externo fica ACIMA do ápice.
    poly, ok := svg_round_join_pts({0, 40}, {5, 0}, {10, 40}, 5)
    testing.expect(t, ok, "quina de verdade tem cunha")
    if !ok do return
    testing.expect(t, poly[0] == im.Vec2{5, 0}, "o primeiro ponto é o VÉRTICE (a cunha fecha nele)")

    // todo o arco tem de ficar do lado de FORA (acima do ápice), nunca abaixo —
    // abaixo é onde os dois segmentos JÁ pintaram, e é onde o disco somava alfa
    maxy: f32 = -1e9
    for p in poly[1:] do maxy = max(maxy, p.y)
    testing.expectf(t, maxy <= 0.01, "nenhum ponto do arco pode cair dentro do traço (y > 0); maior y = %v", maxy)

    // o arco é o MENOR (o vão), não a volta inteira: com N=8 passos, a soma dos
    // ângulos não pode passar de 180°
    a0 := math.atan2(poly[1].y, poly[1].x - 5)
    an := math.atan2(poly[len(poly) - 1].y, poly[len(poly) - 1].x - 5)
    d := abs(an - a0)
    if d > math.PI do d = 2 * math.PI - d
    testing.expectf(t, d <= math.PI + 0.01, "arco pelo caminho CURTO; veio %v rad", d)

    // espelhado em "V": a cunha inverte de lado (se o sinal do lado externo
    // estivesse trocado, um dos dois passaria sozinho)
    dn, ok2 := svg_round_join_pts({0, 0}, {5, 40}, {10, 0}, 5)
    testing.expect(t, ok2, "idem no outro sentido")
    if ok2 {
        miny: f32 = 1e9
        for p in dn[1:] do miny = min(miny, p.y)
        testing.expectf(t, miny >= 39.99, "no V o vão é ABAIXO do ápice; menor y = %v", miny)
    }

    // CONTRA-CASO: colineares não têm vão
    _, ok3 := svg_round_join_pts({0, 0}, {10, 0}, {20, 0}, 5)
    testing.expect(t, !ok3, "sem virada não há cunha")
}
