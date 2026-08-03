package ui

// Geometria da elipse final do radial-gradient (css-images-3 §3.3): centro do
// `at <position>` e semi-eixos do shape+size. Antes o paint IGNORAVA tudo isso
// e desenhava sempre uma elipse centrada com os semi-eixos da caixa × √2.
//
// Os valores esperados aqui são calculados à mão sobre uma caixa 200×100:
// distâncias do centro aos lados (dl,dr,dt,db) e, no caso *-corner, a elipse
// com a razão de aspecto do *-side escalada até PASSAR pelo canto.

import "core:testing"
import "core:math"
import csspkg "../css"

@(private = "file")
BX :: f32(0)
@(private = "file")
BY :: f32(0)
@(private = "file")
BW :: f32(200)
@(private = "file")
BH :: f32(100)

@(private = "file")
geom :: proc(decl: string) -> (cx, cy, rx, ry: f32) {
    g, _ := csspkg.parse_gradient(decl)
    return radial_geometry(g, BX, BY, BW, BH)
}

@(private = "file")
near :: proc(t: ^testing.T, got, want: f32, what: string) {
    testing.expectf(t, abs(got - want) < 0.05, "%s: %.3f (esperado %.3f)", what, got, want)
}

@(test)
test_radial_geom_default_e_farthest_corner :: proc(t: ^testing.T) {
    // centro (100,50); side_x=100, side_y=50; k=√((100/100)²+(50/50)²)=√2
    cx, cy, rx, ry := geom("radial-gradient(red, blue)")
    near(t, cx, 100, "cx"); near(t, cy, 50, "cy")
    near(t, rx, 100 * math.SQRT_TWO, "rx farthest-corner")
    near(t, ry, 50 * math.SQRT_TWO, "ry farthest-corner")
}

@(test)
test_radial_geom_circulo_usa_distancia_unica :: proc(t: ^testing.T) {
    // circle farthest-corner = distância ao canto = √(100²+50²)
    _, _, rx, ry := geom("radial-gradient(circle, red, blue)")
    near(t, rx, math.sqrt(f32(100*100 + 50*50)), "raio do circulo")
    testing.expect(t, rx == ry, "circulo tem os dois eixos iguais")
}

@(test)
test_radial_geom_sides_com_centro_deslocado :: proc(t: ^testing.T) {
    // at 30% 40% => centro (60,40); dl=60 dr=140 dt=40 db=60
    cx, cy, rx, ry := geom("radial-gradient(closest-side at 30% 40%, red, blue)")
    near(t, cx, 60, "cx"); near(t, cy, 40, "cy")
    near(t, rx, 60, "rx closest-side"); near(t, ry, 40, "ry closest-side")

    _, _, fx, fy := geom("radial-gradient(farthest-side at 30% 40%, red, blue)")
    near(t, fx, 140, "rx farthest-side"); near(t, fy, 60, "ry farthest-side")

    // circle closest-side = o MENOR dos quatro lados
    _, _, cr, _ := geom("radial-gradient(circle closest-side at 30% 40%, red, blue)")
    near(t, cr, 40, "raio circle closest-side")
}

@(test)
test_radial_geom_corner_escala_a_razao_do_side :: proc(t: ^testing.T) {
    // closest-corner: aspecto do closest-side (60,40) escalado por
    // k=√((60/60)²+(40/40)²)=√2 → (84.85, 56.57)
    _, _, rx, ry := geom("radial-gradient(closest-corner at 30% 40%, red, blue)")
    near(t, rx, 60 * math.SQRT_TWO, "rx closest-corner")
    near(t, ry, 40 * math.SQRT_TWO, "ry closest-corner")

    // farthest-corner: aspecto do farthest-side (140,60) × √2
    _, _, fx, fy := geom("radial-gradient(farthest-corner at 30% 40%, red, blue)")
    near(t, fx, 140 * math.SQRT_TWO, "rx farthest-corner")
    near(t, fy, 60 * math.SQRT_TWO, "ry farthest-corner")
}

@(test)
test_radial_geom_raios_explicitos_e_centro_px :: proc(t: ^testing.T) {
    // % de raio: x contra a LARGURA, y contra a ALTURA
    _, _, rx, ry := geom("radial-gradient(ellipse 80% 30%, red, blue)")
    near(t, rx, 160, "rx = 80% de 200"); near(t, ry, 30, "ry = 30% de 100")

    cx, cy, cr, _ := geom("radial-gradient(circle 40px at 10px 20px, red, blue)")
    near(t, cx, 10, "cx px"); near(t, cy, 20, "cy px"); near(t, cr, 40, "raio px")
}

// A MÁSCARA (mask-image: radial-gradient) usa a mesma geometria — é um caminho
// por-pixel separado do paint, e antes ele ignorava o prelúdio E usava os
// semi-eixos da caixa (= farthest-side) no lugar do default farthest-corner.
// O teste antigo só checava "centro mais opaco que a borda", o que passava com
// qualquer elipse; estes pinam o RAIO.
@(test)
test_radial_mask_usa_a_mesma_elipse :: proc(t: ^testing.T) {
    alpha :: proc(decl: string, px, py: f32) -> u32 {
        g, _ := csspkg.parse_gradient(decl)
        return test_mask_alpha(g, px, py, 0, 0, 100, 100) // caixa 100x100
    }
    near_a :: proc(t: ^testing.T, v, want: u32, what: string) {
        d := int(v) - int(want)
        testing.expectf(t, d >= -8 && d <= 8, "%s: alpha %d (esperado %d)", what, v, want)
    }
    // closest-side numa caixa 100x100 centrada: raio 50 nos dois eixos.
    CS :: "radial-gradient(closest-side, black, transparent)"
    near_a(t, alpha(CS, 50, 50), 255, "centro opaco")
    near_a(t, alpha(CS, 50, 25), 127, "meio do raio (t=0.5)")
    near_a(t, alpha(CS, 50,  0),   0, "borda (t=1) transparente")

    // DEFAULT (farthest-corner): numa caixa 100x100 o raio é 50·√2 ≈ 70,7 — NÃO
    // os 50 do semi-eixo da caixa que o código antigo usava. Em y=25 => t=0,354
    // (alpha ≈ 165); com o raio antigo daria t=0,5 (alpha ≈ 127).
    DF :: "radial-gradient(black, transparent)"
    near_a(t, alpha(DF, 50, 25), 165, "default farthest-corner em t=0,354")

    // centro deslocado: o ponto opaco anda com o `at`
    AT :: "radial-gradient(closest-side at 25% 50%, black, transparent)"
    near_a(t, alpha(AT, 25, 50), 255, "opaco no centro deslocado")
    testing.expect(t, alpha(AT, 25, 50) > alpha(AT, 75, 50), "lado oposto mais transparente")
}

@(test)
test_radial_geom_canto_da_caixa :: proc(t: ^testing.T) {
    // at top left: centro no canto; farthest-side = a caixa inteira
    cx, cy, rx, ry := geom("radial-gradient(farthest-side at top left, red, blue)")
    near(t, cx, 0, "cx"); near(t, cy, 0, "cy")
    near(t, rx, 200, "rx"); near(t, ry, 100, "ry")
}
