package ui

// M235 — `filter: blur(<len>)` tinha ALCANCE de menos da metade do certo.
//
// `blur(<length>)` é um Gaussiano cujo comprimento é o DESVIO-PADRÃO σ, não um raio
// de janela. Fazíamos UMA passada de box de raio σ: o borrão acabava em σ em vez de
// ~3σ. Medido numa caixa de 120px com `blur(24px)`, contra o Chrome:
//
//   antes   6..203 → espalhava 24px por lado, 50 cores na linha do meio
//   agora   6..233 → 54px por lado, 98 cores      (Chrome: 3..236, 102 cores)
//
// Origem: o brilho difuso do hero da cloudflare (`blur-3xl` = σ 64px) saía como
// mancha de borda dura. ⚠️ E a causa NÃO era a que eu tinha anotado na memória: as
// quatro grafias de `filter` — literal, `var()` de 1 nível, `var()` ANINHADA e a
// lista do Tailwind v4 com fallback VAZIO (`var(--tw-blur,) var(--tw-brightness,)…`)
// — já eram todas parseadas e todas borravam. O que faltava era FORÇA.
//
// Receita da spec (SVG 1.1 §15.17): d = floor(σ·3·√(2π)/4 + 0.5); d ímpar → três
// janelas de tamanho d centradas; d PAR → duas de tamanho d centradas em cada borda
// do pixel + uma de d+1 centrada. O par espelhado é o que cancela a deriva de meio
// pixel — e é exatamente isso que estes testes travam, porque um borrão deslocado
// meio pixel passa despercebido em qualquer gate de pintura.

import "core:testing"

@(test)
m235_gauss_impar_e_simetrico :: proc(t: ^testing.T) {
    // σ=2 → d = floor(2*1.87997+0.5) = 4 (par). σ=3 → floor(6.14) = 6 (par).
    // Procuro um σ que dê d ÍMPAR para exercitar o ramo: σ=1 → floor(2.38) = 2 (par);
    // σ=1.6 → floor(3.5) = 3 (ímpar).
    los, his := test_gauss_boxes(1.6)
    testing.expect_value(t, los[0], 1) // d=3 → janela [-1,+1]
    for p in 0 ..< 3 {
        testing.expect_value(t, los[p], his[p]) // centrada: lo == hi
        testing.expect_value(t, los[p] + his[p] + 1, 3)
    }
}

@(test)
m235_gauss_par_nao_deriva :: proc(t: ^testing.T) {
    // O ramo que importa: com d PAR não existe janela centrada no pixel. Se as duas
    // passadas de tamanho d não forem ESPELHADAS, a imagem inteira escorrega meio
    // pixel por passada — deslocamento que nenhum teste de cor detecta.
    los, his := test_gauss_boxes(2) // d = floor(3.76+0.5) = 4
    somaL := los[0] + los[1] + los[2]
    somaR := his[0] + his[1] + his[2]
    testing.expect_value(t, somaL, somaR) // simetria do núcleo combinado = sem deriva
    testing.expect_value(t, los[0] + his[0] + 1, 4)     // tamanho d
    testing.expect_value(t, los[1] + his[1] + 1, 4)     // tamanho d
    testing.expect_value(t, los[2] + his[2] + 1, 5)     // tamanho d+1
    testing.expect_value(t, los[0], his[1])             // a 2ª é o espelho da 1ª
    testing.expect_value(t, his[0], los[1])
}

@(test)
m235_gauss_sem_borrao_para_sigma_zero :: proc(t: ^testing.T) {
    // CONTROLE: σ=0 (e σ minúsculo) não pode produzir janela nenhuma — senão
    // `filter: blur(0)`, que o Tailwind emite como estado inicial de transição,
    // custaria três passadas sobre a textura inteira por frame.
    for s in ([]f32{0, 0.1, 0.25}) {
        los, his := test_gauss_boxes(s)
        testing.expect_value(t, los[0] + his[0], 0)
    }
}

@(test)
m235_alcance_e_tres_sigmas :: proc(t: ^testing.T) {
    // A margem da textura da layer TEM de ser o alcance, não σ: com margem σ o
    // borrão certo seria cortado numa borda reta justo onde deveria se apagar.
    testing.expect_value(t, test_blur_spread(24), f32(72))
    testing.expect_value(t, test_blur_spread(0), f32(0))
}

@(test)
m235_janela_cresce_com_sigma :: proc(t: ^testing.T) {
    // Monotonicidade: σ maior ⇒ janela maior. Trava a fórmula contra um erro de
    // unidade (usar diâmetro no lugar de raio, ou px no lugar de σ) que ainda
    // passaria nos testes de paridade acima.
    ant := 0
    for s in ([]f32{1, 4, 16, 64}) {
        los, his := test_gauss_boxes(s)
        tam := los[0] + his[0] + 1
        testing.expect(t, tam > ant, "janela tem de crescer com sigma")
        ant = tam
    }
    // σ=64 é o `blur-3xl` do Tailwind (o caso da cloudflare): d = floor(120.3) = 120.
    los64, his64 := test_gauss_boxes(64)
    testing.expect_value(t, los64[0] + his64[0] + 1, 120)
}
