package css

// Prelúdio do radial-gradient — `[<shape> || <size>] [at <position>]`.
//
// Antes, o prelúdio INTEIRO era descartado: todo radial-gradient virava uma
// elipse centrada farthest-corner. `at 30% 30%`, `circle`, `closest-side` e os
// raios explícitos não tinham efeito nenhum (o hero do getbootstrap saía como
// um borrão cinza no lugar do gradiente colorido).

import "core:testing"

@(private = "file")
rad :: proc(v: string) -> Gradient {
    g, _ := parse_gradient(v)
    return g
}

@(test)
test_radial_sem_preludio_usa_default_do_css :: proc(t: ^testing.T) {
    g := rad("radial-gradient(red, blue)")
    testing.expect(t, g.active && g.radial, "gradiente radial valido")
    testing.expect_value(t, g.r_size, Radial_Size.Farthest_Corner) // zero-value = default
    testing.expect(t, !g.r_circle, "sem shape = elipse")
    testing.expect(t, !g.r_pos_set, "sem 'at' = centro 50% 50%")
}

@(test)
test_radial_shape_e_size_por_keyword :: proc(t: ^testing.T) {
    g := rad("radial-gradient(circle closest-side at 30% 40%, red, blue)")
    testing.expect(t, g.r_circle, "circle")
    testing.expect_value(t, g.r_size, Radial_Size.Closest_Side)
    testing.expect(t, g.r_pos_set, "'at' marcado")
    testing.expect(t, abs(g.r_cx - 0.3) < 1e-4 && g.r_cx_pct, "centro x = 30%")
    testing.expect(t, abs(g.r_cy - 0.4) < 1e-4 && g.r_cy_pct, "centro y = 40%")

    casos := [4]struct{decl: string, want: Radial_Size}{
        {"radial-gradient(closest-side, red, blue)",    .Closest_Side},
        {"radial-gradient(closest-corner, red, blue)",  .Closest_Corner},
        {"radial-gradient(farthest-side, red, blue)",   .Farthest_Side},
        {"radial-gradient(farthest-corner, red, blue)", .Farthest_Corner},
    }
    for c in casos {
        testing.expect_value(t, rad(c.decl).r_size, c.want)
    }
}

@(test)
test_radial_raios_explicitos :: proc(t: ^testing.T) {
    e := rad("radial-gradient(ellipse 80% 30%, red, blue)")
    testing.expect_value(t, e.r_size, Radial_Size.Explicit)
    testing.expect(t, abs(e.r_rx - 0.8) < 1e-4 && e.r_rx_pct, "rx = 80% do lado")
    testing.expect(t, abs(e.r_ry - 0.3) < 1e-4 && e.r_ry_pct, "ry = 30% do lado")

    // círculo tem UM raio: vale p/ os dois eixos
    c := rad("radial-gradient(circle 40px at 10px 20px, red, blue)")
    testing.expect_value(t, c.r_size, Radial_Size.Explicit)
    testing.expect(t, c.r_circle, "circle")
    testing.expect(t, abs(c.r_rx - 40) < 1e-4 && !c.r_rx_pct, "raio 40px")
    testing.expect(t, abs(c.r_ry - 40) < 1e-4, "circulo: ry = rx")
    testing.expect(t, abs(c.r_cx - 10) < 1e-4 && !c.r_cx_pct, "centro x = 10px")
    testing.expect(t, abs(c.r_cy - 20) < 1e-4 && !c.r_cy_pct, "centro y = 20px")
}

@(test)
test_radial_posicao_por_keyword :: proc(t: ^testing.T) {
    tl := rad("radial-gradient(at top left, red, blue)")
    testing.expect(t, tl.r_pos_set, "'at' marcado")
    testing.expect(t, tl.r_cx == 0 && tl.r_cy == 0, "top left = 0,0 (ordem invertida aceita)")

    br := rad("radial-gradient(at right bottom, red, blue)")
    testing.expect(t, br.r_cx == 1 && br.r_cy == 1, "right bottom = 100%,100%")

    // 'center' preenche o eixo que falta; um valor só deixa o outro no meio
    cm := rad("radial-gradient(at center 30%, red, blue)")
    testing.expect(t, abs(cm.r_cx - 0.5) < 1e-4, "center = 50% no x")
    testing.expect(t, abs(cm.r_cy - 0.3) < 1e-4, "30% no y")

    um := rad("radial-gradient(at 25%, red, blue)")
    testing.expect(t, abs(um.r_cx - 0.25) < 1e-4, "valor unico vai p/ o x")
    testing.expect(t, abs(um.r_cy - 0.5) < 1e-4, "y fica no meio")
}

@(test)
test_radial_preludio_nao_engole_stops :: proc(t: ^testing.T) {
    // o prelúdio consome só o 1º argumento; as cores seguem intactas
    g := rad("radial-gradient(circle at 30% 30%, #1e6fff, #ffd21e 40%, #ff2e93)")
    testing.expect_value(t, g.n, 3)
    testing.expect(t, g.r_circle && g.r_pos_set, "prelúdio lido")

    // repeating também
    r := rad("repeating-radial-gradient(circle at 50% 50%, red 0 12px, blue 12px 24px)")
    testing.expect(t, r.repeating && r.radial && r.r_circle, "repeating radial com circle")
}
