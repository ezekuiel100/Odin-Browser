package ui

import "core:testing"
import "core:math"
import dompkg "../dom"

// Roda suave (wheel_smooth.odin). O simulador imita o ImGui: o SetScroll de um
// frame só vale no frame SEGUINTE, e o valor é clampado ao limite.

@(private = "file")
Sim :: struct {
    a:   Wheel_Axis,
    cur: f32, // o que o "ImGui" reporta
    max: f32,
}

// Um frame: roda `delta` px, passa `dt` s. Devolve o scroll depois do frame.
@(private = "file")
frame :: proc(s: ^Sim, delta, dt: f32) -> f32 {
    if v, ok := wheel_axis_step(&s.a, s.cur, s.max, delta, dt); ok {
        s.cur = clamp(v, 0, s.max)
    }
    return s.cur
}

// Roda até parar (ou estourar `n` frames). Devolve o nº de frames gastos.
@(private = "file")
drain :: proc(s: ^Sim, dt: f32, n := 1000) -> int {
    for i in 0 ..< n {
        if !s.a.on do return i
        frame(s, 0, dt)
    }
    return n
}

@(test)
wheel_um_clique_nao_salta_mas_chega :: proc(t: ^testing.T) {
    s := Sim{cur = 500, max = 10000}
    primeiro := frame(&s, WHEEL_STEP_PX, 1.0 / 60)
    // a diferença em relação ao comportamento antigo: o 1º frame NÃO anda os 60
    testing.expectf(t, primeiro > 500 && primeiro < 560, "1º frame andou %.1f (esperava entre 0 e 60, exclusive)", primeiro - 500)
    // ... e o controle: no fim, o destino é EXATAMENTE o do salto antigo
    drain(&s, 1.0 / 60)
    testing.expectf(t, s.cur == 560, "destino final %.1f, esperava 560", s.cur)
    testing.expect(t, !s.a.on)
}

@(test)
wheel_saida_inteira_e_monotona :: proc(t: ^testing.T) {
    // texto em sub-pixel sai borrado: todo valor entregue tem de ser inteiro
    s := Sim{cur = 0, max = 10000}
    ant := frame(&s, WHEEL_STEP_PX * 3, 1.0 / 144)
    for _ in 0 ..< 200 {
        if !s.a.on do break
        v := frame(&s, 0, 1.0 / 144)
        testing.expectf(t, v == math.round(v), "scroll fracionário: %v", v)
        testing.expectf(t, v >= ant, "andou para trás: %.1f → %.1f", ant, v)
        ant = v
    }
    testing.expect_value(t, s.cur, f32(180))
}

@(test)
wheel_tempo_de_parede_independe_do_fps :: proc(t: ^testing.T) {
    // 100 ms depois do clique, 60 fps e 10 fps têm de estar no mesmo lugar
    // (a menos do arredondamento). Com passo POR FRAME (o `d*0.2` da âncora),
    // 10 fps estaria muito atrás.
    a := Sim{cur = 0, max = 10000}
    frame(&a, WHEEL_STEP_PX, 1.0 / 60)
    for _ in 1 ..< 6 do frame(&a, 0, 1.0 / 60) // 6 frames = 100 ms
    b := Sim{cur = 0, max = 10000}
    frame(&b, WHEEL_STEP_PX, 1.0 / 10)          // 1 frame = 100 ms
    testing.expectf(t, abs(a.cur - b.cur) <= 1, "60 fps em %.1f, 10 fps em %.1f", a.cur, b.cur)
    // controle: a 100 ms a animação já andou de verdade, mas ainda não chegou
    testing.expectf(t, a.cur > 40 && a.cur < 60, "a 100 ms esperava 40..60, veio %.1f", a.cur)
}

@(test)
wheel_termina_em_tempo_curto :: proc(t: ^testing.T) {
    s := Sim{cur = 0, max = 10000}
    frame(&s, WHEEL_STEP_PX, 1.0 / 60)
    n := drain(&s, 1.0 / 60)
    // ~3τ para 95%; o fim exato (resíduo < 0,5 px) vem perto de 5τ = 250 ms
    testing.expectf(t, n <= 20, "levou %d frames (%.0f ms) para parar", n + 1, f32(n + 1) * 1000 / 60)
}

@(test)
wheel_cliques_seguidos_acumulam :: proc(t: ^testing.T) {
    s := Sim{cur = 0, max = 10000}
    frame(&s, WHEEL_STEP_PX, 1.0 / 60)
    frame(&s, WHEEL_STEP_PX, 1.0 / 60) // 2º clique NO MEIO da animação
    frame(&s, WHEEL_STEP_PX, 1.0 / 60)
    drain(&s, 1.0 / 60)
    // retomar da POSIÇÃO perderia distância; do ALVO, soma exata
    testing.expect_value(t, s.cur, f32(180))
}

@(test)
wheel_inverter_no_meio_volta_ao_inicio :: proc(t: ^testing.T) {
    s := Sim{cur = 300, max = 10000}
    frame(&s, WHEEL_STEP_PX, 1.0 / 60)
    frame(&s, -WHEEL_STEP_PX, 1.0 / 60)
    drain(&s, 1.0 / 60)
    testing.expect_value(t, s.cur, f32(300))
}

@(test)
wheel_respeita_os_limites :: proc(t: ^testing.T) {
    fim := Sim{cur = 970, max = 1000}
    frame(&fim, WHEEL_STEP_PX * 5, 1.0 / 60)
    drain(&fim, 1.0 / 60)
    testing.expect_value(t, fim.cur, f32(1000))
    // e o alvo não "guarda" o excesso: um clique para cima sai do fim na hora
    testing.expectf(t, fim.a.target == 1000, "alvo guardou excesso: %.1f", fim.a.target)

    topo := Sim{cur = 20, max = 1000}
    frame(&topo, -WHEEL_STEP_PX * 5, 1.0 / 60)
    drain(&topo, 1.0 / 60)
    testing.expect_value(t, topo.cur, f32(0))
}

@(test)
wheel_escritor_externo_vence :: proc(t: ^testing.T) {
    // o usuário arrasta a barra (ou âncora/navegação) no meio da animação
    s := Sim{cur = 0, max = 10000}
    frame(&s, WHEEL_STEP_PX * 10, 1.0 / 60)
    frame(&s, 0, 1.0 / 60)
    s.cur = 5000 // alguém escreveu
    _, ok := wheel_axis_step(&s.a, s.cur, s.max, 0, 1.0 / 60)
    testing.expect(t, !ok)  // não escreve por cima
    testing.expect(t, !s.a.on)

    // controle: sem escritor externo, o MESMO frame segue animando
    c := Sim{cur = 0, max = 10000}
    frame(&c, WHEEL_STEP_PX * 10, 1.0 / 60)
    frame(&c, 0, 1.0 / 60)
    _, ok2 := wheel_axis_step(&c.a, c.cur, c.max, 0, 1.0 / 60)
    testing.expect(t, ok2)
    testing.expect(t, c.a.on)
}

@(test)
wheel_nova_roda_depois_de_escritor_externo_parte_de_la :: proc(t: ^testing.T) {
    s := Sim{cur = 0, max = 10000}
    frame(&s, WHEEL_STEP_PX * 10, 1.0 / 60)
    s.cur = 5000                     // barra arrastada
    frame(&s, WHEEL_STEP_PX, 1.0 / 60) // roda de novo no mesmo frame
    drain(&s, 1.0 / 60)
    // parte de 5000, não do alvo velho (600)
    testing.expect_value(t, s.cur, f32(5060))
}

@(test)
wheel_dt_degenerado :: proc(t: ^testing.T) {
    // dt = 0 (dois frames no mesmo tick): não anda, não vira NaN, não para
    s := Sim{cur = 100, max = 10000}
    v := frame(&s, WHEEL_STEP_PX, 0)
    testing.expect_value(t, v, f32(100))
    testing.expect(t, s.a.on)
    // dt enorme (janela travada 3 s): chega de uma vez, sem passar do alvo
    v = frame(&s, 0, 3)
    testing.expect_value(t, v, f32(160))
    testing.expect(t, !s.a.on)
}

@(test)
wheel_container_anima_e_encadeia_no_alvo :: proc(t: ^testing.T) {
    a: Wheel_Axis
    cur, consumed := wheel_container_step(&a, 0, 80, 40, 1.0 / 60, false)
    testing.expect(t, consumed && cur > 0 && cur < 40)
    cur, consumed = wheel_container_step(&a, cur, 80, 40, 1.0 / 60, false)
    testing.expect(t, consumed && a.target == 80)
    cur, consumed = wheel_container_step(&a, cur, 80, 40, 1.0 / 60, false)
    testing.expect(t, !consumed && a.on) // página recebe a roda excedente
    for _ in 0 ..< 50 do cur, _ = wheel_container_step(&a, cur, 80, 0, 1.0 / 60, false)
    testing.expect_value(t, cur, f32(80))
    cur, consumed = wheel_container_step(&a, cur, 80, 40, 1.0 / 60, true)
    testing.expect(t, consumed && cur == 80) // overscroll-behavior:contain
    cur, consumed = wheel_container_step(&a, cur, 80, -40, 1.0 / 60, false)
    testing.expect(t, consumed && cur < 80 && a.target == 40)
}

@(test)
wheel_container_restyle_preserva_animacao :: proc(t: ^testing.T) {
    node: dompkg.Node
    old := Box{node = &node, overflow_scroll = true}
    prev := &old
    prev.scroll_y, _ = wheel_container_step(&prev.wheel[1], 0, 700, 40, 1.0 / 60, false)
    // O DOM sobrevive ao restyle; a árvore de caixas é substituída.
    next := Box{node = prev.node, overflow_scroll = true}
    scroll_restore_tree(&next, &old)
    testing.expect_value(t, next.scroll_y, prev.scroll_y)
    testing.expect_value(t, next.wheel[1].target, f32(40))
    testing.expect(t, next.wheel[1].on)
    cur, _ := wheel_container_step(&next.wheel[1], next.scroll_y, 700, 0, 1.0 / 60, false)
    testing.expect(t, cur > next.scroll_y)
}
