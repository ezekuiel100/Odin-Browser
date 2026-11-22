package js

import "core:testing"

// ── Valor de conclusão VAZIO (UpdateEmpty) ────────────────────────────────────
// `break`, `continue`, `var`, `;` e bloco vazio não têm valor; numa lista o vazio
// herda o valor anterior. Antes o `break` devolvia undefined e APAGAVA o valor:
// `eval('1; do { 2; { 3; break; } } while (false)')` dava undefined, não 3.

@(test)
test_completion_break_herda_valor_do_bloco :: proc(t: ^testing.T) {
    src := `
        var r = [];
        r.push(eval('1; do { 2; { 3; break; } 4; } while (false);'));
        r.push(eval('5; do { 6; { break; } 7; } while (false);'));       // bloco vazio herda o 6
        r.push(eval('8; do { 9; { 10; continue; } 11; } while (false)'));
        r.push(eval('l: { 3; break l; }'));
        r.push(eval('for (var k of [1,2,3]) { k; { break; } }'));
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "3,6,10,3,1", "got %v", v)
}

// if/try/with trocam o vazio por undefined (UpdateEmpty(C, undefined)); por isso
// `{ 6; with({}) { break; } }` conclui com undefined, não com 6.
@(test)
test_completion_if_try_with_viram_undefined :: proc(t: ^testing.T) {
    src := `
        var r = [];
        r.push(eval('5; do { 6; with({}) { break; } 7; } while (false);'));
        r.push(eval('1; if (true) {}'));
        r.push(eval('1; try {} catch (e) {}'));
        r.push(eval('1; with ({}) {}'));
        r.push(eval('for (var q of [1,2,3]) { q; if (q === 2) break; }')); // {break, undefined}
        r.map(String).join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "undefined,undefined,undefined,undefined,undefined", "got %v", v)
}

@(test)
test_completion_declaracoes_sao_vazias :: proc(t: ^testing.T) {
    src := `
        var r = [];
        r.push(eval('1; var x = 2;'), eval('1;;'), eval('1; debugger;'), eval('1; {}'),
               eval('1; class C {}'), eval('1; function f() {}'), eval('1; let z = 3;'));
        r.push(String(eval('')), String(eval('var so;')));
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1,1,1,1,1,1,1,undefined,undefined", "got %v", v)
}

@(test)
test_completion_lacos_switch_try :: proc(t: ^testing.T) {
    src := `
        var r = [];
        r.push(eval('var i = 0; while (i < 3) { i++; }'));
        r.push(eval('for (var j = 0; j < 3; j++) j * 10;'));
        r.push(eval('for (var p in {a:1, b:2}) p;'));
        r.push(eval('switch (1) { case 1: 7; break; case 2: 8; }'));
        r.push(eval('switch (3) { case 1: 7; default: 9; }'));
        r.push(eval('1; try { 2; } finally { 3; }'));
        r.push(eval('1; try { throw 0; } catch (e) { 4; }'));
        r.push(String(eval('1; while (false) 2;')));
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "2,20,b,7,9,2,4,undefined", "got %v", v)
}

// O vazio NUNCA chega ao JS: corpo de função sem return dá undefined e o próprio
// script que termina em declaração conclui com o valor de antes.
@(test)
test_completion_vazio_nao_vaza :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`function h() { { 1; } var q; } typeof h()`), Value("undefined"))
    testing.expect_value(t, run(`7; var fim;`), Value(f64(7)))
    testing.expect(t, run(`var so;`) == nil, "script só com declaração deve concluir com undefined")
}
