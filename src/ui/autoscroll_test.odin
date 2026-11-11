package ui

import "core:testing"

// Rolagem automática do botão do meio: a máquina de estados e a velocidade são
// PURAS (autoscroll.odin) justamente para dar para provar o contrato sem janela.
// O comportamento no app (ícone, página e rolável interno andando, clique
// engolido) foi provado à mão com mouse_event + F9.

@(private = "file")
inp_at :: proc(x, y: f32) -> Autoscroll_Input {
    return Autoscroll_Input{mouse = {x, y}, tab_ok = true}
}

@(test)
autoscroll_toggle_mode_sobrevive_a_soltura :: proc(t: ^testing.T) {
    // apertou e soltou SEM sair da zona morta ⇒ modo trava, segue ligado
    a: Autoscroll
    autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
    i := inp_at(105, 103)
    autoscroll_step(&a, i)
    i.mid_released = true
    autoscroll_step(&a, i)
    testing.expect(t, a.on, "soltar dentro da zona morta deveria manter o modo (trava)")
    testing.expect(t, !a.held)
    // longe da âncora depois da soltura NÃO conta como arraste
    autoscroll_step(&a, inp_at(100, 400))
    testing.expect(t, a.on && !a.dragged)
}

@(test)
autoscroll_arraste_encerra_na_soltura :: proc(t: ^testing.T) {
    // controle do anterior: a ÚNICA diferença é sair da zona morta apertado
    a: Autoscroll
    autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
    autoscroll_step(&a, inp_at(100, 160))
    testing.expect(t, a.dragged)
    i := inp_at(100, 160)
    i.mid_released = true
    autoscroll_step(&a, i)
    testing.expect(t, !a.on, "arrastou com o meio apertado: soltar deveria encerrar")
}

@(test)
autoscroll_clique_encerra_e_e_engolido :: proc(t: ^testing.T) {
    for b in 0 ..< 3 {
        a: Autoscroll
        autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
        i := inp_at(100, 100); i.mid_released = true
        autoscroll_step(&a, i) // modo trava
        i = inp_at(300, 300)
        i.clicked[b] = true
        sw := autoscroll_step(&a, i)
        testing.expectf(t, !a.on, "botão %d deveria encerrar", b)
        testing.expectf(t, sw[b], "botão %d deveria ser engolido", b)
        for o in 0 ..< 3 do if o != b do testing.expectf(t, !sw[o], "só o botão %d, não o %d", b, o)
        // só o MEIO deixa a soltura pendurada p/ engolir
        testing.expect_value(t, a.swallow_mid_release, b == 2)
    }
}

@(test)
autoscroll_sem_clique_nada_e_engolido :: proc(t: ^testing.T) {
    // controle: modo ligado e mouse andando, sem clique ⇒ nada engolido. Sem isto
    // o teste acima passaria com um `swallow = {true,true,true}` fixo.
    a: Autoscroll
    autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
    sw := autoscroll_step(&a, inp_at(100, 500))
    testing.expect(t, a.on)
    testing.expect(t, sw == [3]bool{}, "sem clique não se engole nada")
    // e desligado, um clique NÃO é engolido (o clique normal da página)
    b: Autoscroll
    i := inp_at(0, 0); i.clicked[0] = true
    sw = autoscroll_step(&b, i)
    testing.expect(t, sw == [3]bool{}, "fora do modo, clique é clique")
}

@(test)
autoscroll_esc_e_troca_de_aba_encerram :: proc(t: ^testing.T) {
    a: Autoscroll
    autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
    i := inp_at(100, 100); i.escape = true
    autoscroll_step(&a, i)
    testing.expect(t, !a.on, "Esc")
    autoscroll_start(&a, 7, {100, 100}, nil, {false, true})
    i = inp_at(100, 100); i.tab_ok = false
    autoscroll_step(&a, i)
    testing.expect(t, !a.on, "aba trocada/carregando")
}

@(test)
autoscroll_swallow_sobrevive_ao_stop_e_ao_restart :: proc(t: ^testing.T) {
    // o aperto que encerra vem frames ANTES da soltura: o stop não pode apagar a
    // marca, senão a soltura vira mouseup/auxclick na página
    a: Autoscroll
    a.swallow_mid_release = true
    autoscroll_stop(&a)
    testing.expect(t, a.swallow_mid_release)
}

@(test)
autoscroll_velocidade :: proc(t: ^testing.T) {
    // zona morta parada, nos dois sentidos
    testing.expect_value(t, autoscroll_velocity(0), 0)
    testing.expect_value(t, autoscroll_velocity(AUTOSCROLL_DEAD), 0)
    testing.expect_value(t, autoscroll_velocity(-AUTOSCROLL_DEAD), 0)
    // sinal: abaixo da âncora desce, acima sobe, simétrico
    testing.expect(t, autoscroll_velocity(50) > 0)
    testing.expect_value(t, autoscroll_velocity(-50), -autoscroll_velocity(50))
    // cresce com a distância e ACELERA (mais que linear)
    v1, v2, v4 := autoscroll_velocity(AUTOSCROLL_DEAD + 50), autoscroll_velocity(AUTOSCROLL_DEAD + 100), autoscroll_velocity(AUTOSCROLL_DEAD + 200)
    testing.expect(t, v1 < v2 && v2 < v4)
    testing.expect(t, v4 - v2 > v2 - v1, "deveria acelerar com a distância")
    // teto
    testing.expect_value(t, autoscroll_velocity(1e6), AUTOSCROLL_VMAX)
}

@(test)
autoscroll_delta_acumula_rolagem_lenta :: proc(t: ^testing.T) {
    // ~8 px/s: cada frame de 16 ms dá 0,13 px. Truncar SEM acumular daria zero
    // para sempre; acumulando, 1 s inteiro anda ~8 px, sempre em px INTEIROS.
    a: Autoscroll
    autoscroll_start(&a, 7, {0, 100}, nil, {false, true})
    y := f32(100 + AUTOSCROLL_DEAD + 2)
    want := autoscroll_velocity(y - 100)
    total := f32(0)
    for _ in 0 ..< 60 {
        d := autoscroll_delta(&a, {0, y}, 1.0 / 60)
        testing.expect(t, d.y == f32(int(d.y)), "deslocamento tem de ser inteiro")
        total += d.y
    }
    testing.expectf(t, abs(total - want) <= 1, "1 s a %.1f px/s andou %.1f", want, total)
    // um frame travado (2 s) não vira salto: limitado a AUTOSCROLL_DTMAX
    b: Autoscroll
    autoscroll_start(&b, 7, {0, 100}, nil, {false, true})
    d := autoscroll_delta(&b, {0, 100 + 300}, 2)
    testing.expect(t, d.y <= autoscroll_velocity(300) * AUTOSCROLL_DTMAX + 1)
    // desligado não anda
    c: Autoscroll
    testing.expect(t, autoscroll_delta(&c, {900, 900}, 1) == [2]f32{})
}

@(test)
autoscroll_eixo_x :: proc(t: ^testing.T) {
    // cursor 200 px À ESQUERDA e 200 px ABAIXO da âncora, alvo que rola nos dois
    // eixos: X anda p/ a esquerda (negativo), Y p/ baixo, com a MESMA curva
    a: Autoscroll
    autoscroll_start(&a, 7, {500, 500}, nil, {true, true})
    d := autoscroll_delta(&a, {300, 700}, 0.05)
    testing.expectf(t, d.x < 0 && d.y > 0, "esperava X<0 e Y>0, veio %v", d)
    testing.expectf(t, d.x == -d.y, "a curva é a mesma nos dois eixos: %v", d)
}

@(test)
autoscroll_eixo_que_nao_rola_fica_parado :: proc(t: ^testing.T) {
    // controle do anterior: o MESMO movimento, alvo que só rola no Y (o caso de
    // `overflow-x:hidden`) ⇒ X tem de ficar em zero mesmo com o cursor longe
    a: Autoscroll
    autoscroll_start(&a, 7, {500, 500}, nil, {false, true})
    d := autoscroll_delta(&a, {300, 700}, 0.05)
    testing.expect_value(t, d.x, 0)
    testing.expect(t, d.y > 0)
    // e o espelho: só X
    b: Autoscroll
    autoscroll_start(&b, 7, {500, 500}, nil, {true, false})
    d = autoscroll_delta(&b, {300, 700}, 0.05)
    testing.expect(t, d.x < 0)
    testing.expect_value(t, d.y, 0)
}
