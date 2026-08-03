package js

// M182 — o teto de tempo por tarefa virou AJUSTÁVEL (`--js-timeout <ms>`).
//
// O watchdog (`TIME_BUDGET_MS :: 4000`) existe p/ não congelar a UI numa página
// patológica, e o default NÃO muda. O que a flag resolve é diagnóstico: com o teto
// padrão o bootstrap do open.spotify.com é abortado com `RangeError: tempo de
// execução excedido`, e com `--js-timeout 60000` ele roda sem exceção NENHUMA —
// isto é, a flag é o que separa "falta feature no motor" de "o motor é lento".
// Medido: padrão 8,6s→RangeError; 60000 e 0 (desligado) → 29s sem exceção.
//
// ⚠️ ESTE TESTE MEXE EM GLOBAL (`g_time_budget_ms`) e o runner do Odin roda testes
// em PARALELO — por isso ele só usa valores GRANDES ou 0 (que afrouxam, nunca
// apertam) e restaura o default no fim. Apertar o teto aqui poderia fazer OUTRO
// teste rodando junto estourar o watchdog. Mesma pedra do M179.

import "core:testing"

@(test)
m182_teto_de_tempo_configuravel :: proc(t: ^testing.T) {
    original := g_time_budget_ms
    defer set_time_budget_ms(original)

    // o default é o TIME_BUDGET_MS
    testing.expect_value(t, original, TIME_BUDGET_MS)

    // valor explícito: todo vm criado DEPOIS herda
    set_time_budget_ms(60_000)
    vm1 := vm_create()
    testing.expect_value(t, vm1.time_budget_ms, 60_000.0)

    // 0 = watchdog DESLIGADO (o guarda em vm_step testa `> 0`)
    set_time_budget_ms(0)
    vm2 := vm_create()
    testing.expect_value(t, vm2.time_budget_ms, 0.0)

    // negativo é entrada inválida → volta ao default, não vira "desligado"
    set_time_budget_ms(-5)
    testing.expect_value(t, g_time_budget_ms, TIME_BUDGET_MS)

    // e o vm que já existia NÃO é afetado retroativamente (o valor é copiado)
    testing.expect_value(t, vm1.time_budget_ms, 60_000.0)
}
