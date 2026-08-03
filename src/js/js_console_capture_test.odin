package js

import "core:testing"

// Passo #1 do DevTools — console.log/warn/error capturam a linha em vm.console_buf
// (além de imprimir em stdout/stderr). O painel Console da UI lê esse buffer.

@(test)
console_capture_niveis :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_run(vm, `console.log('a', 1, true); console.warn('w'); console.error('boom')`)

    testing.expectf(t, len(vm.console_buf) == 3, "esperava 3 linhas, veio %d", len(vm.console_buf))
    if len(vm.console_buf) != 3 do return

    testing.expectf(t, vm.console_buf[0].level == .Log   && vm.console_buf[0].text == "a 1 true",
        "linha 0: %v %q", vm.console_buf[0].level, vm.console_buf[0].text)
    testing.expectf(t, vm.console_buf[1].level == .Warn  && vm.console_buf[1].text == "w",
        "linha 1: %v %q", vm.console_buf[1].level, vm.console_buf[1].text)
    testing.expectf(t, vm.console_buf[2].level == .Error && vm.console_buf[2].text == "boom",
        "linha 2: %v %q", vm.console_buf[2].level, vm.console_buf[2].text)
}

// info/debug/trace são apelidos de console.log → também capturam como .Log.
@(test)
console_capture_apelidos :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_run(vm, `console.info('i'); console.debug('d'); console.trace('t')`)
    testing.expectf(t, len(vm.console_buf) == 3, "info/debug/trace: esperava 3, veio %d", len(vm.console_buf))
    for e in vm.console_buf {
        testing.expectf(t, e.level == .Log, "apelido deveria ser .Log, veio %v", e.level)
    }
}

// vm_console_clear (botão "Limpar" do painel) esvazia o buffer.
@(test)
console_capture_clear :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_run(vm, `console.log('x'); console.log('y')`)
    testing.expect(t, len(vm.console_buf) == 2)
    vm_console_clear(vm)
    testing.expectf(t, len(vm.console_buf) == 0, "após clear esperava 0, veio %d", len(vm.console_buf))
}

// Ring: passar do teto descarta as linhas mais antigas, retém as recentes.
@(test)
console_capture_ring :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    // gera CONSOLE_LOG_MAX + 10 linhas; o buffer nunca deve exceder o teto.
    vm_run(vm, `for (var i = 0; i < 2058; i++) console.log(i)`)
    testing.expectf(t, len(vm.console_buf) <= CONSOLE_LOG_MAX,
        "buffer excedeu o teto: %d > %d", len(vm.console_buf), CONSOLE_LOG_MAX)
    // a última linha deve ser a mais recente (2057), não uma antiga descartada.
    last := vm.console_buf[len(vm.console_buf) - 1].text
    testing.expectf(t, last == "2057", "última linha deveria ser '2057', veio %q", last)
}

// ── REPL (passo #4) ─────────────────────────────────────────────────────────

// vm_repl_eval ecoa a entrada (.Input) e o resultado (.Result) no console.
@(test)
repl_eco_e_resultado :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_repl_eval(vm, `1 + 2 * 3`)
    testing.expectf(t, len(vm.console_buf) == 2, "esperava 2 linhas (eco+resultado), veio %d", len(vm.console_buf))
    if len(vm.console_buf) != 2 do return
    testing.expectf(t, vm.console_buf[0].level == .Input  && vm.console_buf[0].text == "1 + 2 * 3",
        "eco: %v %q", vm.console_buf[0].level, vm.console_buf[0].text)
    testing.expectf(t, vm.console_buf[1].level == .Result && vm.console_buf[1].text == "7",
        "resultado: %v %q", vm.console_buf[1].level, vm.console_buf[1].text)
}

// O REPL compartilha o escopo global: um comando enxerga o que outro definiu.
@(test)
repl_escopo_compartilhado :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_repl_eval(vm, `var x = 40`)
    vm_repl_eval(vm, `x + 2`)
    last := vm.console_buf[len(vm.console_buf) - 1]
    testing.expectf(t, last.level == .Result && last.text == "42",
        "esperava Result '42', veio %v %q", last.level, last.text)
}

// Uma exceção no REPL vira uma linha .Error — e NÃO envenena o próximo comando.
@(test)
repl_erro_nao_envenena :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_repl_eval(vm, `foo.bar`)         // ReferenceError/TypeError
    errline := vm.console_buf[len(vm.console_buf) - 1]
    testing.expectf(t, errline.level == .Error, "esperava .Error, veio %v %q", errline.level, errline.text)
    testing.expect(t, !vm.throwing) // estado de exceção limpo

    vm_repl_eval(vm, `2 + 2`)           // o comando seguinte roda normal
    ok := vm.console_buf[len(vm.console_buf) - 1]
    testing.expectf(t, ok.level == .Result && ok.text == "4",
        "comando após erro deveria dar '4', veio %v %q", ok.level, ok.text)
}
