package ui

// stroke-miterlimit + shape-rendering.
//
// ⚠️⚠️ O QUE ESTA FEATURE CORRIGIU não foi "a prop era ignorada": o
// `AddPolyline` do ImGui faz **miter ILIMITADO**, então o bico crescia sem
// parar e NENHUM dos três valores de `stroke-linejoin` tinha efeito no ápice —
// o disco do `round` era pintado por cima de um espinho que continuava lá. O
// comentário antigo no svg.odin afirmava o oposto ("junta em bisel"); foi o
// pixel contra o Chrome que desmentiu.
//
// A geometria da junta é FUNÇÃO PURA (3 pontos → polígono do vão), então o
// corte do miterlimit se afirma sem janela — mesmo padrão do svg_dash_pieces.

import "core:testing"
import "core:math"
import im "../../vendor/imgui"

@(private = "file")
nearm :: proc(a, b: f32, tol: f32 = 0.01) -> bool { return abs(a - b) <= tol }

@(test)
test_svg_miter_ratio :: proc(t: ^testing.T) {
    // reto: o bico tem exatamente a espessura do traço
    testing.expectf(t, nearm(svg_miter_ratio({0, 0}, {10, 0}, {20, 0}), 1),
        "linha reta = razão 1; veio %v", svg_miter_ratio({0, 0}, {10, 0}, {20, 0}))

    // virada de 90°: razão = 1/sin(45°) = √2
    r90 := svg_miter_ratio({0, 0}, {10, 0}, {10, 10})
    testing.expectf(t, nearm(r90, math.sqrt_f32(2), 0.02), "quina de 90° = √2 ≈ 1.414; veio %v", r90)

    // quanto mais AGUDO, maior o bico (é o que o miterlimit existe p/ cortar)
    ag := svg_miter_ratio({0, 40}, {5, 0}, {10, 40})
    testing.expectf(t, ag > 8, "ápice bem agudo deveria dar razão alta; veio %v", ag)
    testing.expect(t, ag > r90, "mais agudo = razão MAIOR")

    // dobra de 180° (volta por cima de si): bico infinito, não pode virar NaN
    d := svg_miter_ratio({0, 0}, {10, 0}, {0, 0})
    testing.expectf(t, d > 1e6, "dobra de 180° = bico ilimitado; veio %v", d)
}

@(test)
test_svg_join_corte_pelo_miterlimit :: proc(t: ^testing.T) {
    // "Λ" agudo: p1 é o ápice, o lado EXTERNO da virada é p/ CIMA (y menor)
    p0, p1, p2 := im.Vec2{0, 40}, im.Vec2{5, 0}, im.Vec2{10, 40}
    ratio := svg_miter_ratio(p0, p1, p2)

    // limite generoso → BICO (4 pontos), com a ponta para FORA da curva
    big, nb := svg_join_pts(p0, p1, p2, 5, 20, .Miter)
    testing.expectf(t, nb == 4, "com limite alto a junta é bico (4 pontos); veio %d", nb)
    if nb == 4 {
        testing.expectf(t, big[2].y < p1.y,
            "a ponta do bico tem de ficar do lado de FORA (acima do ápice); veio y=%v vs %v", big[2].y, p1.y)
        // distância da ponta ao vértice = r * razão (definição do miterLength)
        dx, dy := big[2].x - p1.x, big[2].y - p1.y
        d := math.sqrt(dx * dx + dy * dy)
        testing.expectf(t, nearm(d, 5 * ratio, 0.05),
            "comprimento do bico = r*razão = %v; veio %v", 5 * ratio, d)
    }

    // MESMA geometria com limite apertado → BISEL (3 pontos). É o corte.
    small, ns := svg_join_pts(p0, p1, p2, 5, 2, .Miter)
    testing.expectf(t, ns == 3, "acima do limite a junta vira bisel (3 pontos); veio %d", ns)
    _ = small

    // linejoin:bevel ignora o limite e é SEMPRE bisel
    _, nbev := svg_join_pts(p0, p1, p2, 5, 20, .Bevel)
    testing.expectf(t, nbev == 3, "bevel é bisel mesmo com limite alto; veio %d", nbev)

    // CONTRA-CASO: colineares não têm vão a preencher
    _, nz := svg_join_pts({0, 0}, {10, 0}, {20, 0}, 5, 4, .Miter)
    testing.expectf(t, nz == 0, "sem virada não há junta a desenhar; veio %d", nz)
}

@(test)
test_svg_join_lado_externo :: proc(t: ^testing.T) {
    // O lado externo depende do SENTIDO do giro. Espelhando o "Λ" em "V", a
    // ponta tem de inverter — se o sinal estivesse trocado, a junta seria
    // pintada DENTRO da curva e o teste do outro sentido passaria sozinho.
    up, nu := svg_join_pts({0, 40}, {5, 0}, {10, 40}, 5, 20, .Miter)   // Λ
    dn, nd := svg_join_pts({0, 0}, {5, 40}, {10, 0}, 5, 20, .Miter)    // V
    testing.expect(t, nu == 4 && nd == 4, "os dois são bico")
    if nu == 4 && nd == 4 {
        testing.expectf(t, up[2].y < 0,  "Λ: ponta ACIMA do ápice; veio %v", up[2].y)
        testing.expectf(t, dn[2].y > 40, "V: ponta ABAIXO do ápice; veio %v", dn[2].y)
    }
}

@(test)
test_svg_join_quando_quebra :: proc(t: ^testing.T) {
    // miter só quebra a polilinha quando ESTOURA o limite (abaixo dele o bico
    // do ImGui já é o certo, e não quebrar é o que preserva o caminho rápido)
    testing.expect(t, !svg_join_breaks(.Miter, 3.9, 4), "3.9 < 4: deixa o ImGui fazer")
    testing.expect(t,  svg_join_breaks(.Miter, 4.1, 4), "4.1 > 4: precisa cortar")

    // bevel/round quebram em qualquer quina REAL, mas não em ângulo raso —
    // é o que mantém a curva achatada (todo vértice de ícone) num emit só
    testing.expect(t, !svg_join_breaks(.Round, 1.001, 4), "vértice de curva não quebra")
    testing.expect(t, !svg_join_breaks(.Bevel, 1.001, 4), "idem bevel")
    testing.expect(t,  svg_join_breaks(.Round, 1.5, 4),   "quina de verdade quebra")
    testing.expect(t,  svg_join_breaks(.Bevel, 1.5, 4),   "idem bevel")
}

@(test)
test_svg_shape_rendering :: proc(t: ^testing.T) {
    na, sm, ok := svg_parse_shape_rendering("crispEdges")
    testing.expect(t, ok && na && sm == 1, "crispEdges desliga o antialias")
    na2, _, _ := svg_parse_shape_rendering("optimizespeed")
    testing.expect(t, na2, "optimizeSpeed também desliga (e o valor não é sensível a caixa)")
    na3, sm3, _ := svg_parse_shape_rendering("geometricPrecision")
    testing.expect(t, !na3 && sm3 == 3, "geometricPrecision mantém o AA e refina a curva")
    na4, sm4, ok4 := svg_parse_shape_rendering("auto")
    testing.expect(t, ok4 && !na4 && sm4 == 1, "auto = comportamento de sempre")
    _, _, ok5 := svg_parse_shape_rendering("banana")
    testing.expect(t, !ok5, "valor inválido não declara nada")

    // seg_mul de verdade REFINA o polígono (é o efeito observável da prop, e o
    // único que dá p/ afirmar sem medir pixel de curva)
    a := svg_ellipse_pts(0, 0, 10, 10)
    b := svg_ellipse_pts(0, 0, 10, 10, 3)
    testing.expectf(t, len(b) == 3 * len(a), "geometricPrecision triplica os lados: %d vs %d", len(b), len(a))
}
