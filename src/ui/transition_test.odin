package ui

// M223 — testes de `transition-property` / `-timing-function` / `-delay`.
//
// Três níveis: a CURVA (timing_eval, matemática pura), o PARSING (qual canal
// recebe o quê) e o RELÓGIO (os steppers, com atraso e curva).

import "core:testing"

@(private = "file")
near3 :: proc(a, b: f32, tol: f32 = 0.005) -> bool { return abs(a - b) <= tol }

// ── curva ───────────────────────────────────────────────────────────────────

@(test)
test_m223_timing_linear_e_extremos :: proc(t: ^testing.T) {
    lin := Timing{kind = .Linear}
    testing.expect(t, near3(timing_eval(lin, 0), 0), "0")
    testing.expect(t, near3(timing_eval(lin, 0.37), 0.37), "identidade")
    testing.expect(t, near3(timing_eval(lin, 1), 1), "1")
    // toda curva tem de fixar os extremos, senão o fim da transição "salta"
    curvas := []Timing{
        TIMING_DEFAULT,
        {kind = .CubicBezier, x1 = 0.42, y1 = 0, x2 = 1, y2 = 1},     // ease-in
        {kind = .CubicBezier, x1 = 0, y1 = 0, x2 = 0.58, y2 = 1},     // ease-out
        {kind = .CubicBezier, x1 = 0.42, y1 = 0, x2 = 0.58, y2 = 1},  // ease-in-out
        {kind = .CubicBezier, x1 = 0.68, y1 = -0.55, x2 = 0.27, y2 = 1.55}, // back (passa de 1)
    }
    for c, i in curvas {
        testing.expectf(t, near3(timing_eval(c, 0), 0), "curva %d: f(0)=0", i)
        testing.expectf(t, near3(timing_eval(c, 1), 1), "curva %d: f(1)=1", i)
    }
}

@(test)
test_m223_timing_bezier_e_a_curva_certa :: proc(t: ^testing.T) {
    // ease-in (0.42,0,1,1): no meio do TEMPO já andou MENOS que metade do valor.
    ein := Timing{kind = .CubicBezier, x1 = 0.42, y1 = 0, x2 = 1, y2 = 1}
    testing.expectf(t, timing_eval(ein, 0.5) < 0.45, "ease-in(0.5) devia ser < 0.45; veio %v", timing_eval(ein, 0.5))
    // ease-out é o espelho: já andou MAIS que metade
    eout := Timing{kind = .CubicBezier, x1 = 0, y1 = 0, x2 = 0.58, y2 = 1}
    testing.expectf(t, timing_eval(eout, 0.5) > 0.55, "ease-out(0.5) devia ser > 0.55; veio %v", timing_eval(eout, 0.5))
    // simetria de ease-in-out em torno de 0.5
    eio := Timing{kind = .CubicBezier, x1 = 0.42, y1 = 0, x2 = 0.58, y2 = 1}
    testing.expect(t, near3(timing_eval(eio, 0.5), 0.5, 0.02), "ease-in-out(0.5) ≈ 0.5")
    testing.expect(t, near3(timing_eval(eio, 0.25) + timing_eval(eio, 0.75), 1, 0.02), "simétrica")
    // `ease` (o DEFAULT) NÃO é ease-in-out: ele acelera antes
    testing.expectf(t, timing_eval(TIMING_DEFAULT, 0.25) > timing_eval(eio, 0.25),
        "`ease` anda mais que ease-in-out em 25%% do tempo (é o que o default muda)")
}

@(test)
test_m223_timing_steps :: proc(t: ^testing.T) {
    end := Timing{kind = .Steps, steps = 4}
    testing.expect(t, near3(timing_eval(end, 0), 0), "jump-end começa em 0")
    testing.expect(t, near3(timing_eval(end, 0.24), 0), "1º degrau")
    testing.expect(t, near3(timing_eval(end, 0.26), 0.25), "2º degrau")
    testing.expect(t, near3(timing_eval(end, 1), 1), "termina em 1")
    start := Timing{kind = .Steps, steps = 4, jump_start = true}
    testing.expect(t, near3(timing_eval(start, 0), 0.25), "jump-start pula já no 0")
    testing.expect(t, near3(timing_eval(start, 1), 1), "e não passa de 1")
}

// ── parsing ─────────────────────────────────────────────────────────────────

@(test)
test_m223_property_restringe_canal :: proc(t: ^testing.T) {
    // O bug que este marco fecha: `transition: opacity .3s` animava TUDO.
    c := test_apply("transition: opacity 0.3s")
    testing.expect(t, c.trans[.Opacity].on && near3(c.trans[.Opacity].dur, 0.3), "opacity anima")
    testing.expect(t, !c.trans[.Bg].on, "background NÃO deveria animar")
    testing.expect(t, !c.trans[.Transform].on, "transform NÃO deveria animar")
    testing.expect(t, !c.trans[.Color].on, "color NÃO deveria animar")

    all := test_apply("transition: all 0.2s")
    for ch in Trans_Chan do testing.expectf(t, all.trans[ch].on, "`all` liga o canal %v", ch)

    none := test_apply("transition: none 0.2s")
    for ch in Trans_Chan do testing.expectf(t, !none.trans[ch].on, "`none` não liga %v", ch)

    // prop que o motor NÃO sabe animar: parseia e ignora (mudança instantânea)
    w := test_apply("transition: width 0.4s")
    for ch in Trans_Chan do testing.expectf(t, !w.trans[ch].on, "`width` não cai em canal nenhum (%v)", ch)
}

@(test)
test_m223_lista_com_props_e_tempos_proprios :: proc(t: ^testing.T) {
    // a forma real de site: várias transições numa declaração só
    c := test_apply("transition: opacity 0.2s linear, transform 0.6s ease-in 0.1s")
    testing.expect(t, near3(c.trans[.Opacity].dur, 0.2), "opacity 0.2s")
    testing.expect(t, c.trans[.Opacity].timing.kind == .Linear, "opacity linear")
    testing.expect(t, near3(c.trans[.Opacity].delay, 0), "opacity sem atraso")
    testing.expect(t, near3(c.trans[.Transform].dur, 0.6), "transform 0.6s")
    testing.expect(t, near3(c.trans[.Transform].delay, 0.1), "transform atraso 0.1s")
    testing.expect(t, c.trans[.Transform].timing.kind == .CubicBezier, "transform ease-in")
}

@(test)
test_m223_dois_tempos_sao_dur_e_delay_nessa_ordem :: proc(t: ^testing.T) {
    // spec: o 1º tempo é a duração, o 2º é o atraso — a ordem dos tokens não é livre
    c := test_apply("transition: opacity 250ms 700ms")
    testing.expect(t, near3(c.trans[.Opacity].dur, 0.25), "1º tempo = duração")
    testing.expect(t, near3(c.trans[.Opacity].delay, 0.7), "2º tempo = atraso")
}

@(test)
test_m223_longhands_e_repeticao_ciclica :: proc(t: ^testing.T) {
    c := test_apply("transition-property: opacity, transform; transition-duration: 0.5s; transition-delay: 0.1s, 0.4s")
    testing.expect(t, near3(c.trans[.Opacity].dur, 0.5), "duração única REPETE p/ as duas props")
    testing.expect(t, near3(c.trans[.Transform].dur, 0.5), "idem transform")
    testing.expect(t, near3(c.trans[.Opacity].delay, 0.1), "atrasos vão em ordem")
    testing.expect(t, near3(c.trans[.Transform].delay, 0.4), "idem")

    // longhand de timing sozinho: sem property nem shorthand, assume `all`
    c2 := test_apply("transition-duration: 0.3s; transition-timing-function: linear")
    testing.expect(t, c2.trans[.Bg].on && c2.trans[.Bg].timing.kind == .Linear, "assume `all`")
}

@(test)
test_m223_timing_function_parseada :: proc(t: ^testing.T) {
    c := test_apply("transition: opacity 1s cubic-bezier(0.68, -0.55, 0.27, 1.55)")
    tm := c.trans[.Opacity].timing
    testing.expect(t, tm.kind == .CubicBezier, "cubic-bezier reconhecida")
    testing.expect(t, near3(tm.x1, 0.68) && near3(tm.y2, 1.55), "pontos de controle lidos")
    // a vírgula de dentro da função NÃO pode separar itens da lista
    testing.expect(t, near3(c.trans[.Opacity].dur, 1), "a lista continua com 1 item")

    s := test_apply("transition: opacity 1s steps(4, jump-start)")
    testing.expect(t, s.trans[.Opacity].timing.kind == .Steps && s.trans[.Opacity].timing.steps == 4, "steps()")
    testing.expect(t, s.trans[.Opacity].timing.jump_start, "jump-start")

    // curva INVÁLIDA (x fora de [0,1]) invalida a declaração inteira, per spec —
    // e o token não pode ser confundido com o NOME da propriedade.
    bad := test_apply("transition: opacity 1s cubic-bezier(2, 0, 0.5, 1)")
    testing.expect(t, !bad.trans[.Opacity].on, "curva inválida ⇒ sem transição (não é nome de prop)")
    bad2 := test_apply("transition: opacity 1s steps(0)")
    testing.expect(t, !bad2.trans[.Opacity].on, "steps(0) idem")
}

@(test)
test_m223_default_e_ease_nao_ease_in_out :: proc(t: ^testing.T) {
    // Antes deste marco a curva era ease-in-out (smoothstep) hardcoded; o default
    // da spec é `ease`, que é uma curva DIFERENTE.
    c := test_apply("transition: opacity 0.3s")
    tm := c.trans[.Opacity].timing
    testing.expect(t, tm.kind == .CubicBezier && near3(tm.x1, 0.25) && near3(tm.y1, 0.1), "default = ease")
}

// ── relógio ─────────────────────────────────────────────────────────────────

@(test)
test_m223_delay_segura_o_valor_inicial :: proc(t: ^testing.T) {
    tr := Transition{dur = 0.2, delay = 0.3, timing = Timing{kind = .Linear}, on = true}
    ch: Trans_FChan
    test_trans_step_f(&ch, 0, tr, 0, true) // settle em 0
    // durante o atraso o valor NÃO se mexe
    v := test_trans_step_f(&ch, 1, tr, 0.1, false)
    testing.expectf(t, near3(v, 0), "0.1s de 0.3s de atraso: ainda em 0; veio %v", v)
    v = test_trans_step_f(&ch, 1, tr, 0.15, false)
    testing.expectf(t, near3(v, 0), "0.25s: ainda em 0; veio %v", v)
    // passado o atraso, começa a andar
    v = test_trans_step_f(&ch, 1, tr, 0.1, false)  // fecha o atraso neste frame
    v = test_trans_step_f(&ch, 1, tr, 0.1, false)  // meio da duração
    testing.expectf(t, v > 0.4 && v < 0.6, "depois do atraso anda (≈meio); veio %v", v)
}

@(test)
test_m223_canal_desligado_salta_para_o_alvo :: proc(t: ^testing.T) {
    off := Transition{} // on=false: é o que um canal fora do transition-property recebe
    ch: Trans_FChan
    test_trans_step_f(&ch, 0, off, 0, true)
    v := test_trans_step_f(&ch, 1, off, 0.016, false)
    testing.expectf(t, near3(v, 1), "canal sem transição vai direto ao alvo; veio %v", v)
}

@(test)
test_m223_curva_muda_o_valor_no_meio :: proc(t: ^testing.T) {
    // O mesmo relógio com curvas diferentes tem de dar valores diferentes —
    // é o que prova que o timing-function chega ao stepper.
    passo :: proc(tm: Timing) -> f32 {
        tr := Transition{dur = 1, timing = tm, on = true}
        ch: Trans_FChan
        test_trans_step_f(&ch, 0, tr, 0, true)
        return test_trans_step_f(&ch, 1, tr, 0.5, false) // metade do tempo
    }
    lin  := passo(Timing{kind = .Linear})
    ein  := passo(Timing{kind = .CubicBezier, x1 = 0.42, y1 = 0, x2 = 1, y2 = 1})
    eout := passo(Timing{kind = .CubicBezier, x1 = 0, y1 = 0, x2 = 0.58, y2 = 1})
    testing.expect(t, near3(lin, 0.5, 0.02), "linear no meio = 0.5")
    testing.expectf(t, ein < lin - 0.05, "ease-in atrás do linear (%v vs %v)", ein, lin)
    testing.expectf(t, eout > lin + 0.05, "ease-out à frente do linear (%v vs %v)", eout, lin)
}
