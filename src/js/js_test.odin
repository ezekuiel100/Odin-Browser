package js

// Testes do pipeline lexer -> parser -> interp.
// Rodar:  odin test src/js   (a partir da raiz do projeto)

import "core:testing"

// ── M1: expressões aritméticas ────────────────────────────────────────────────

@(test)
test_soma :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("2 + 3")), f64(5))
}

@(test)
test_precedencia :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("2 + 3 * 4")), f64(14))
}

@(test)
test_parenteses :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("(2 + 3) * 4")), f64(20))
}

@(test)
test_divisao :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("10 / 4")), f64(2.5))
}

// ── M2: variáveis e atribuição ────────────────────────────────────────────────

@(test)
test_var :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 5; x + 1")), f64(6))
}

@(test)
test_reatribuicao :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 1; x = x + 10; x")), f64(11))
}

// ── M2: strings ───────────────────────────────────────────────────────────────

@(test)
test_concat_string :: proc(t: ^testing.T) {
    // resultado é bool (comparação), avaliado antes do vm_destroy liberar a string
    v, _ := run("var s = 'ab' + 'cd'; s == 'abcd'").(bool)
    testing.expect(t, v, "concatenação deve dar 'abcd'")
}

@(test)
test_concat_num_string :: proc(t: ^testing.T) {
    v, _ := run("'n=' + 42 == 'n=42'").(bool)
    testing.expect(t, v, "número deve virar string na concatenação")
}

// ── M2: comparações e booleanos ───────────────────────────────────────────────

@(test)
test_igualdade :: proc(t: ^testing.T) {
    a, _ := run("2 == 2").(bool)
    b, _ := run("2 != 3").(bool)
    testing.expect(t, a && b, "== e != devem funcionar")
}

@(test)
test_negacao :: proc(t: ^testing.T) {
    v, _ := run("!false").(bool)
    testing.expect(t, v, "!false deve ser true")
}

// ── M2: fluxo de controle ─────────────────────────────────────────────────────

@(test)
test_if_else :: proc(t: ^testing.T) {
    src := "var x = 0; if (1 < 2) { x = 10; } else { x = 20; } x"
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
test_while :: proc(t: ^testing.T) {
    // soma 0+1+2+3+4 = 10
    src := "var i = 0; var s = 0; while (i < 5) { s = s + i; i = i + 1; } s"
    testing.expect_value(t, as_number(run(src)), f64(10))
}

// ── M2: escopo de bloco ───────────────────────────────────────────────────────

@(test)
test_escopo_bloco :: proc(t: ^testing.T) {
    // `var` é FUNCTION-scoped: o `var x=2` no bloco reatribui o MESMO x → 2 (JS real).
    // (era testado como 1 assumindo block-scope; corrigido no fix de var-hoisting.)
    testing.expect_value(t, as_number(run("var x = 1; { var x = 2; } x")), f64(2))
    // `let` É block-scoped: o interno é outra variável → externo continua 1.
    testing.expect_value(t, as_number(run("let x = 1; { let x = 2; } x")), f64(1))
}

// ── M2: console.log não deve quebrar ──────────────────────────────────────────

@(test)
test_console_log :: proc(t: ^testing.T) {
    // imprime "oi 3" e devolve undefined (nil)
    r := run("console.log('oi', 1 + 2)")
    testing.expect(t, r == nil, "console.log deve devolver undefined")
}

// ── M3: funções, return, closures ─────────────────────────────────────────────

@(test)
test_funcao :: proc(t: ^testing.T) {
    src := "function add(a, b) { return a + b; } add(2, 3)"
    testing.expect_value(t, as_number(run(src)), f64(5))
}

@(test)
test_funcao_expressao :: proc(t: ^testing.T) {
    src := "var sq = function(x) { return x * x; }; sq(9)"
    testing.expect_value(t, as_number(run(src)), f64(81))
}

@(test)
test_recursao :: proc(t: ^testing.T) {
    // fib(10) = 55
    src := "function fib(n) { if (n < 2) { return n; } return fib(n-1) + fib(n-2); } fib(10)"
    testing.expect_value(t, as_number(run(src)), f64(55))
}

@(test)
test_closure :: proc(t: ^testing.T) {
    // o contador `c` é capturado pela função interna e persiste entre chamadas
    src := "function mk() { var c = 0; return function() { c = c + 1; return c; }; } var f = mk(); f(); f(); f()"
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
test_closures_independentes :: proc(t: ^testing.T) {
    // dois contadores criados por mk() não compartilham estado
    src := "function mk() { var c = 0; return function() { c = c + 1; return c; }; } var a = mk(); var b = mk(); a(); a(); b()"
    testing.expect_value(t, as_number(run(src)), f64(1)) // b() é a 1ª chamada de b
}

@(test)
test_funcao_sem_return :: proc(t: ^testing.T) {
    r := run("function f() { } f()")
    testing.expect(t, r == nil, "função sem return devolve undefined")
}

@(test)
test_argumento_faltando :: proc(t: ^testing.T) {
    // parâmetro não passado vira undefined; undefined em soma numérica -> NaN (spec)
    src := "function f(a, b) { return a + b; } isNaN(f(5)) ? 1 : 0"
    testing.expect_value(t, as_number(run(src)), f64(1))
}

// ── M4: objetos, arrays, this ─────────────────────────────────────────────────

@(test)
test_objeto_prop :: proc(t: ^testing.T) {
    src := "var o = { x: 10, y: 20 }; o.x + o.y"
    testing.expect_value(t, as_number(run(src)), f64(30))
}

@(test)
test_objeto_atribuicao :: proc(t: ^testing.T) {
    src := "var o = { x: 1 }; o.x = 42; o.x"
    testing.expect_value(t, as_number(run(src)), f64(42))
}

@(test)
test_objeto_indice :: proc(t: ^testing.T) {
    // acesso por string entre colchetes e chave nova
    src := "var o = {}; o['a'] = 5; o['a']"
    testing.expect_value(t, as_number(run(src)), f64(5))
}

@(test)
test_array_literal_e_indice :: proc(t: ^testing.T) {
    src := "var a = [10, 20, 30]; a[1]"
    testing.expect_value(t, as_number(run(src)), f64(20))
}

@(test)
test_array_length :: proc(t: ^testing.T) {
    src := "var a = [1, 2, 3, 4]; a.length"
    testing.expect_value(t, as_number(run(src)), f64(4))
}

@(test)
test_array_push :: proc(t: ^testing.T) {
    src := "var a = [1]; a.push(2); a.push(3); a[2] + a.length"
    testing.expect_value(t, as_number(run(src)), f64(6)) // a[2]=3, length=3
}

@(test)
test_array_atribuicao_indice :: proc(t: ^testing.T) {
    src := "var a = [0, 0, 0]; a[2] = 99; a[2]"
    testing.expect_value(t, as_number(run(src)), f64(99))
}

@(test)
test_this_em_metodo :: proc(t: ^testing.T) {
    // método usa `this` para acessar propriedade do próprio objeto
    src := "var o = { n: 7, dobro: function() { return this.n * 2; } }; o.dobro()"
    testing.expect_value(t, as_number(run(src)), f64(14))
}

@(test)
test_objeto_aninhado :: proc(t: ^testing.T) {
    src := "var o = { a: { b: { c: 123 } } }; o.a.b.c"
    testing.expect_value(t, as_number(run(src)), f64(123))
}

@(test)
test_array_de_objetos :: proc(t: ^testing.T) {
    src := "var xs = [{ v: 1 }, { v: 2 }]; xs[0].v + xs[1].v"
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
test_console_log_objeto :: proc(t: ^testing.T) {
    // console agora é um objeto real; não deve quebrar
    r := run("console.log([1, 2, 3])")
    testing.expect(t, r == nil, "console.log de array deve devolver undefined")
}

// ── M7 fatia 1: for, ++/--, +=, % ─────────────────────────────────────────────

@(test)
test_for_soma :: proc(t: ^testing.T) {
    // soma 0+1+...+9 = 45
    src := "var s = 0; for (var i = 0; i < 10; i = i + 1) { s = s + i; } s"
    testing.expect_value(t, as_number(run(src)), f64(45))
}

@(test)
test_for_com_incremento :: proc(t: ^testing.T) {
    src := "var s = 0; for (var i = 1; i <= 5; i++) { s += i; } s" // 1+2+3+4+5 = 15
    testing.expect_value(t, as_number(run(src)), f64(15))
}

@(test)
test_pos_incremento :: proc(t: ^testing.T) {
    // sufixo devolve o valor ANTES de incrementar
    src := "var i = 5; var a = i++; a * 100 + i" // a=5, i=6 -> 506
    testing.expect_value(t, as_number(run(src)), f64(506))
}

@(test)
test_pre_incremento :: proc(t: ^testing.T) {
    // prefixo devolve o valor JÁ incrementado
    src := "var i = 5; var a = ++i; a * 100 + i" // a=6, i=6 -> 606
    testing.expect_value(t, as_number(run(src)), f64(606))
}

@(test)
test_decremento :: proc(t: ^testing.T) {
    src := "var i = 3; i--; i--; i" // 1
    testing.expect_value(t, as_number(run(src)), f64(1))
}

@(test)
test_compostos :: proc(t: ^testing.T) {
    src := "var x = 10; x += 5; x -= 3; x *= 2; x /= 4; x" // ((10+5-3)*2)/4 = 6
    testing.expect_value(t, as_number(run(src)), f64(6))
}

@(test)
test_modulo :: proc(t: ^testing.T) {
    a, _ := run("17 % 5 == 2").(bool)
    b, _ := run("10 % 2 == 0").(bool)
    testing.expect(t, a && b, "módulo deve funcionar")
}

@(test)
test_for_array :: proc(t: ^testing.T) {
    // percorre um array acumulando com for + índice
    src := "var xs = [10, 20, 30, 40]; var t = 0; for (var i = 0; i < xs.length; i++) { t += xs[i]; } t"
    testing.expect_value(t, as_number(run(src)), f64(100))
}

@(test)
test_for_composto_em_membro :: proc(t: ^testing.T) {
    // += num campo de objeto
    src := "var o = { n: 0 }; for (var i = 0; i < 4; i++) { o.n += i; } o.n" // 0+1+2+3 = 6
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// ── M7 fatia 2: && || ?: === !== ──────────────────────────────────────────────

@(test)
test_and_or :: proc(t: ^testing.T) {
    a, _ := run("true && true").(bool)
    b, _ := run("false || true").(bool)
    c, _ := run("false && true").(bool)
    testing.expect(t, a && b && !c, "&& e || devem funcionar")
}

@(test)
test_curto_circuito_valor :: proc(t: ^testing.T) {
    // && devolve o operando (não um bool): 5 && 7 -> 7 ; 0 || 9 -> 9
    testing.expect_value(t, as_number(run("5 && 7")), f64(7))
    testing.expect_value(t, as_number(run("0 || 9")), f64(9))
}

@(test)
test_curto_circuito_nao_avalia :: proc(t: ^testing.T) {
    // o lado direito de && não roda quando o esquerdo é falsy
    src := "var x = 0; false && (x = 99); x" // x continua 0
    testing.expect_value(t, as_number(run(src)), f64(0))
}

@(test)
test_ternario :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("(3 > 2) ? 10 : 20")), f64(10))
    testing.expect_value(t, as_number(run("(1 > 2) ? 10 : 20")), f64(20))
}

@(test)
test_ternario_aninhado :: proc(t: ^testing.T) {
    src := "var n = 5; n < 0 ? -1 : n == 0 ? 0 : 1" // 1
    testing.expect_value(t, as_number(run(src)), f64(1))
}

@(test)
test_estrita_tipo :: proc(t: ^testing.T) {
    // == coage tipos; === não. '2' == 2 é true, mas '2' === 2 é false.
    a, _ := run("'2' == 2").(bool)
    b, _ := run("'2' === 2").(bool)
    c, _ := run("2 === 2").(bool)
    d, _ := run("2 !== 3").(bool)
    testing.expect(t, a && !b && c && d, "=== deve exigir mesmo tipo")
}

@(test)
test_guarda_com_and :: proc(t: ^testing.T) {
    // padrão comum: guarda antes de acessar propriedade
    src := "var o = { v: 42 }; (o && o.v) ? o.v : -1" // 42
    testing.expect_value(t, as_number(run(src)), f64(42))
}

// ── M7 fatia 3: métodos de Array/String, Math, globais ────────────────────────

@(test)
test_array_indexof_includes :: proc(t: ^testing.T) {
    a, _ := run("[10, 20, 30].indexOf(20) == 1").(bool)
    b, _ := run("[1, 2, 3].includes(3)").(bool)
    c, _ := run("[1, 2, 3].indexOf(9) == -1").(bool)
    testing.expect(t, a && b && c, "indexOf/includes")
}

@(test)
test_array_map_filter :: proc(t: ^testing.T) {
    // dobra e soma os pares: [1,2,3,4] -> map*2 -> [2,4,6,8] -> filter par (todos) -> soma
    src := "var xs = [1, 2, 3, 4]; var d = xs.map(function(x) { return x * 2; }); d[0] + d[3]" // 2 + 8 = 10
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
test_array_filter :: proc(t: ^testing.T) {
    src := "var xs = [1, 2, 3, 4, 5, 6]; xs.filter(function(x) { return x % 2 == 0; }).length" // 3 pares
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
test_array_foreach :: proc(t: ^testing.T) {
    src := "var s = 0; [10, 20, 30].forEach(function(x) { s += x; }); s" // 60
    testing.expect_value(t, as_number(run(src)), f64(60))
}

@(test)
test_array_pop_reverse :: proc(t: ^testing.T) {
    src := "var a = [1, 2, 3]; var last = a.pop(); a.reverse(); last * 10 + a[0]" // last=3, a=[2,1] -> 30+2=32
    testing.expect_value(t, as_number(run(src)), f64(32))
}

@(test)
test_array_join :: proc(t: ^testing.T) {
    v, _ := run("[1, 2, 3].join('-') == '1-2-3'").(bool)
    testing.expect(t, v, "join com separador")
}

@(test)
test_string_metodos :: proc(t: ^testing.T) {
    a, _ := run("'hello'.toUpperCase() == 'HELLO'").(bool)
    b, _ := run("'hello'.slice(1, 3) == 'el'").(bool)
    c, _ := run("'hello'.indexOf('ll') == 2").(bool)
    d, _ := run("'  hi  '.trim() == 'hi'").(bool)
    testing.expect(t, a && b && c && d, "métodos de string")
}

@(test)
test_string_split :: proc(t: ^testing.T) {
    src := "'a,b,c,d'.split(',').length" // 4
    testing.expect_value(t, as_number(run(src)), f64(4))
}

@(test)
test_string_split_e_indice :: proc(t: ^testing.T) {
    v, _ := run("'a,b,c'.split(',')[1] == 'b'").(bool)
    testing.expect(t, v, "split + índice")
}

@(test)
test_math :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("Math.floor(3.7)")), f64(3))
    testing.expect_value(t, as_number(run("Math.max(1, 9, 4)")), f64(9))
    testing.expect_value(t, as_number(run("Math.min(1, 9, 4)")), f64(1))
    testing.expect_value(t, as_number(run("Math.abs(-5)")), f64(5))
    testing.expect_value(t, as_number(run("Math.pow(2, 10)")), f64(1024))
    testing.expect_value(t, as_number(run("Math.sqrt(144)")), f64(12))
}

@(test)
test_parse_int_float :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("parseInt('42')")), f64(42))
    testing.expect_value(t, as_number(run("parseInt('42px')")), f64(42)) // para no 1º não-dígito
    testing.expect_value(t, as_number(run("parseFloat('3.14')")), f64(3.14))
    b, _ := run("isNaN(parseInt('abc'))").(bool)
    testing.expect(t, b, "parseInt('abc') deve ser NaN")
}

// ── M9 fatia 1: timers (setTimeout / setInterval) ─────────────────────────────

@(test)
test_set_timeout :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var x = 0; setTimeout(function() { x = 42; }, 100);")

    fired := vm_pump_timers(vm, 50) // relógio: 50ms — ainda não venceu
    testing.expect(t, !fired, "não deve disparar antes do prazo")
    testing.expect_value(t, as_number(vm_run(vm, "x")), f64(0))

    fired = vm_pump_timers(vm, 60) // relógio: 110ms — venceu
    testing.expect(t, fired, "deve disparar após o prazo")
    testing.expect_value(t, as_number(vm_run(vm, "x")), f64(42))

    fired = vm_pump_timers(vm, 100) // one-shot: não repete
    testing.expect(t, !fired, "setTimeout não deve repetir")
}

@(test)
test_clear_timeout :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var x = 0; var id = setTimeout(function() { x = 1; }, 50); clearTimeout(id);")
    fired := vm_pump_timers(vm, 100)
    testing.expect(t, !fired, "timer cancelado não dispara")
    testing.expect_value(t, as_number(vm_run(vm, "x")), f64(0))
}

@(test)
test_set_interval :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    // dispara a cada 10ms; o próprio handler se cancela na 3ª vez
    vm_run(vm, "var n = 0; var id = setInterval(function() { n++; if (n >= 3) { clearInterval(id); } }, 10);")
    for _ in 0 ..< 10 do vm_pump_timers(vm, 10) // 100ms em passos de 10
    testing.expect_value(t, as_number(vm_run(vm, "n")), f64(3))
}

@(test)
test_timeout_closure :: proc(t: ^testing.T) {
    // o callback captura variáveis por closure e vê o valor atual
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var s = 0; for (var i = 1; i <= 3; i++) { setTimeout(function() { s += 10; }, i * 10); }")
    vm_pump_timers(vm, 100) // todos vencem numa bombada só
    testing.expect_value(t, as_number(vm_run(vm, "s")), f64(30))
}

// ── M11: break / continue ─────────────────────────────────────────────────────

@(test)
test_break_for :: proc(t: ^testing.T) {
    src := "var s = 0; for (var i = 0; i < 10; i++) { if (i == 5) { break; } s += i; } s"
    testing.expect_value(t, as_number(run(src)), f64(10)) // 0+1+2+3+4
}

@(test)
test_continue_for :: proc(t: ^testing.T) {
    // continue AINDA precisa rodar o update (senão trava em loop infinito)
    src := "var s = 0; for (var i = 0; i < 5; i++) { if (i % 2 == 1) { continue; } s += i; } s"
    testing.expect_value(t, as_number(run(src)), f64(6)) // 0+2+4
}

@(test)
test_break_while_true :: proc(t: ^testing.T) {
    src := "var i = 0; while (true) { i++; if (i >= 7) { break; } } i"
    testing.expect_value(t, as_number(run(src)), f64(7))
}

@(test)
test_continue_while :: proc(t: ^testing.T) {
    src := "var i = 0; var s = 0; while (i < 5) { i++; if (i == 3) { continue; } s += i; } s"
    testing.expect_value(t, as_number(run(src)), f64(12)) // 1+2+4+5
}

@(test)
test_break_aninhado :: proc(t: ^testing.T) {
    // break sai só do loop INTERNO
    src := "var c = 0; for (var i = 0; i < 3; i++) { for (var j = 0; j < 10; j++) { if (j == 2) { break; } c++; } } c"
    testing.expect_value(t, as_number(run(src)), f64(6)) // 2 por iteração externa
}

// ── M11: try / catch / throw / finally ────────────────────────────────────────

@(test)
test_try_catch :: proc(t: ^testing.T) {
    src := "var r = ''; try { throw 'boom'; r = 'nao'; } catch (e) { r = 'pego:' + e; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "pego:boom")
}

@(test)
test_try_sem_throw :: proc(t: ^testing.T) {
    src := "var r = 'a'; try { r = 'b'; } catch (e) { r = 'c'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "b")
}

@(test)
test_finally :: proc(t: ^testing.T) {
    src := "var r = ''; try { throw 1; } catch (e) { r += 'c'; } finally { r += 'f'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "cf")
}

@(test)
test_finally_com_throw_pendente :: proc(t: ^testing.T) {
    // finally interno roda ANTES do catch externo pegar a exceção
    src := "var r = ''; try { try { throw 'x'; } finally { r += 'f'; } } catch (e) { r += 'c' + e; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "fcx")
}

@(test)
test_throw_atravessa_funcao :: proc(t: ^testing.T) {
    src := "function f() { throw 'err'; } var r = ''; try { f(); } catch (e) { r = e; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "err")
}

@(test)
test_throw_objeto :: proc(t: ^testing.T) {
    src := "var c = 0; try { throw { code: 42 }; } catch (e) { c = e.code; } c"
    testing.expect_value(t, as_number(run(src)), f64(42))
}

@(test)
test_uncaught_nao_envenena :: proc(t: ^testing.T) {
    // um throw sem catch é logado e limpo; o vm continua utilizável
    vm := vm_create()
    defer vm_free(vm)
    r1 := vm_run(vm, "throw 'perdido';")
    testing.expect(t, r1 == nil, "throw sem catch devolve undefined")
    testing.expect_value(t, as_number(vm_run(vm, "1 + 1")), f64(2))
}

@(test)
test_throw_interrompe_foreach :: proc(t: ^testing.T) {
    // exceção no callback para a iteração e é capturável fora
    src := "var n = 0; try { [1,2,3,4].forEach(function(x) { n++; if (x == 2) { throw 'stop'; } }); } catch (e) {} n"
    testing.expect_value(t, as_number(run(src)), f64(2))
}

// ── M15: arrow functions ──────────────────────────────────────────────────────

@(test)
test_arrow_um_param :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var f = x => x * 2; f(21)")), f64(42))
}

@(test)
test_arrow_dois_params :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var f = (a, b) => a + b; f(2, 3)")), f64(5))
}

@(test)
test_arrow_sem_params :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var f = () => 7; f()")), f64(7))
}

@(test)
test_arrow_corpo_bloco :: proc(t: ^testing.T) {
    src := "var f = (n) => { var s = 0; for (var i = 0; i <= n; i++) { s += i; } return s; }; f(4)"
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
test_arrow_em_map :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("[1, 2, 3].map(x => x * x)[2]")), f64(9))
}

@(test)
test_arrow_closure :: proc(t: ^testing.T) {
    src := "var mk = () => { var c = 0; return () => ++c; }; var f = mk(); f(); f()"
    testing.expect_value(t, as_number(run(src)), f64(2))
}

@(test)
test_arrow_this_lexico :: proc(t: ^testing.T) {
    // a arrow herda o this do método envolvente (função normal perderia)
    src := "var o = { n: 5, m: function() { var f = () => this.n; return f(); } }; o.m()"
    testing.expect_value(t, as_number(run(src)), f64(5))
}

@(test)
test_parens_nao_arrow :: proc(t: ^testing.T) {
    // (x + y) * 2 NÃO é arrow — o lookahead não pode engolir parênteses comuns
    src := "var x = 3; var y = 4; (x + y) * 2"
    testing.expect_value(t, as_number(run(src)), f64(14))
}

// ── M15: template literals ────────────────────────────────────────────────────

@(test)
test_template_basico :: proc(t: ^testing.T) {
    v, _ := run("var x = `ola ${1 + 1} mundo`; x == 'ola 2 mundo'").(bool)
    testing.expect(t, v, "template com expressão")
}

@(test)
test_template_so_numeros :: proc(t: ^testing.T) {
    // o "" inicial força concat de string: `${1}${2}` é "12", não 3
    v, _ := run("`${1}${2}` == '12'").(bool)
    testing.expect(t, v, "duas interpolações numéricas concatenam")
}

@(test)
test_template_varias_partes :: proc(t: ^testing.T) {
    v, _ := run("var a = 'A'; `x${a}y${2 * 2}z` == 'xAy4z'").(bool)
    testing.expect(t, v, "múltiplas interpolações")
}

@(test)
test_template_objeto_dentro :: proc(t: ^testing.T) {
    // chaves de objeto dentro de ${} não fecham a interpolação
    v, _ := run("`v=${ {k: 3}.k }` == 'v=3'").(bool)
    testing.expect(t, v, "objeto literal dentro de ${}")
}

@(test)
test_template_aninhado :: proc(t: ^testing.T) {
    v, _ := run("`a${ `[${9}]` }b` == 'a[9]b'").(bool)
    testing.expect(t, v, "template dentro de template")
}

@(test)
test_template_com_arrow :: proc(t: ^testing.T) {
    v, _ := run("var f = n => `#${n}`; f(7) == '#7'").(bool)
    testing.expect(t, v, "arrow devolvendo template")
}

// ── M16: escapes de string ────────────────────────────────────────────────────

@(test)
test_escape_newline :: proc(t: ^testing.T) {
    // 'a\nb' tem 3 chars, e o do meio é LF (código 10)
    testing.expect_value(t, as_number(run(`'a\nb'.length`)), f64(3))
    testing.expect_value(t, as_number(run(`'a\nb'.charCodeAt(1)`)), f64(10))
}

@(test)
test_escape_tab :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'\t'.charCodeAt(0)`)), f64(9))
}

@(test)
test_escape_aspas :: proc(t: ^testing.T) {
    // aspas escapadas dentro do mesmo tipo de aspas
    testing.expect_value(t, as_number(run(`'a\'b'.length`)), f64(3))
    testing.expect_value(t, as_number(run(`"x\"y".length`)), f64(3))
}

@(test)
test_escape_barra :: proc(t: ^testing.T) {
    // '\\' é UMA barra invertida (código 92)
    testing.expect_value(t, as_number(run(`'\\'.length`)), f64(1))
    testing.expect_value(t, as_number(run(`'\\'.charCodeAt(0)`)), f64(92))
}

@(test)
test_escape_em_template :: proc(t: ^testing.T) {
    // \n decodifica dentro de template; crase escapada não termina o template
    testing.expect_value(t, as_number(run("`a\\nb`.length")), f64(3))
    testing.expect_value(t, as_number(run("`x\\`y`.length")), f64(3))
}

@(test)
test_escape_interpolacao :: proc(t: ^testing.T) {
    // \${ escapado NÃO abre interpolação: fica literal "a${1}b" (6 chars)
    testing.expect_value(t, as_number(run("`a\\${1}b`.length")), f64(6))
}

@(test)
test_string_sem_escape_nao_aloca :: proc(t: ^testing.T) {
    // sanidade do caminho rápido (fatia crua, sem decode)
    v, _ := run(`'sem escapes' == 'sem escapes'`).(bool)
    testing.expect(t, v, "strings simples continuam funcionando")
}

// ── M17: new (Error e funções construtoras) ───────────────────────────────────

@(test)
test_new_error :: proc(t: ^testing.T) {
    v, _ := run("var e = new Error('boom'); e.name == 'Error' && e.message == 'boom'").(bool)
    testing.expect(t, v, "new Error deve criar {name, message}")
}

@(test)
test_throw_new_error :: proc(t: ^testing.T) {
    // O caso que motivou tudo: throw new Error capturável com mensagem útil
    src := "var r = ''; try { throw new Error('falhou'); } catch (e) { r = e.name + ': ' + e.message; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "Error: falhou")
}

@(test)
test_error_to_string :: proc(t: ^testing.T) {
    // concatenação usa o pretty-print de erro ("Name: message")
    v, _ := run("('' + new Error('x')) == 'Error: x'").(bool)
    testing.expect(t, v, "erro concatenado vira 'Error: x'")
}

@(test)
test_error_tipos :: proc(t: ^testing.T) {
    v, _ := run("new TypeError('t').name == 'TypeError' && new RangeError('r').name == 'RangeError'").(bool)
    testing.expect(t, v, "TypeError/RangeError")
}

@(test)
test_new_sem_parenteses :: proc(t: ^testing.T) {
    v, _ := run("var e = new Error; e.name == 'Error'").(bool)
    testing.expect(t, v, "new sem parênteses")
}

@(test)
test_new_construtora :: proc(t: ^testing.T) {
    // função construtora do usuário: this = objeto novo
    src := "function Point(x, y) { this.x = x; this.y = y; } var p = new Point(3, 4); p.x + p.y"
    testing.expect_value(t, as_number(run(src)), f64(7))
}

@(test)
test_new_construtora_com_metodo :: proc(t: ^testing.T) {
    src := "function C(v) { this.v = v; this.dobro = function() { return this.v * 2; }; } var c = new C(21); c.dobro()"
    testing.expect_value(t, as_number(run(src)), f64(42))
}

@(test)
test_new_return_objeto_vence :: proc(t: ^testing.T) {
    // se o construtor devolve um objeto, ele substitui o this novo (JS)
    src := "function F() { this.k = 1; return { k: 9 }; } var f = new F(); f.k"
    testing.expect_value(t, as_number(run(src)), f64(9))
}

// ── M18: typeof / switch / do-while / comentários de bloco ────────────────────

@(test)
test_typeof :: proc(t: ^testing.T) {
    v, _ := run(`typeof 1 == 'number' && typeof 'a' == 'string' && typeof true == 'boolean'`).(bool)
    testing.expect(t, v, "typeof de primitivos")
}

@(test)
test_typeof_especiais :: proc(t: ^testing.T) {
    // typeof de variável NÃO declarada não é erro; typeof null é 'object' (JS)
    v, _ := run(`typeof nao_existe == 'undefined' && typeof null == 'object'`).(bool)
    testing.expect(t, v, "typeof undefined/null")
}

@(test)
test_typeof_objetos :: proc(t: ^testing.T) {
    v, _ := run(`typeof {} == 'object' && typeof [] == 'object' && typeof (x => x) == 'function'`).(bool)
    testing.expect(t, v, "typeof de objeto/array/função")
}

@(test)
test_comentario_bloco :: proc(t: ^testing.T) {
    src := "var x = 1; /* comentário\n de várias\n linhas */ x + /* no meio */ 2"
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
test_do_while :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var i = 0; do { i++; } while (i < 5); i")), f64(5))
    // corpo roda pelo menos uma vez, mesmo com condição falsa
    testing.expect_value(t, as_number(run("var n = 0; do { n++; } while (false); n")), f64(1))
}

@(test)
test_do_while_break_continue :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var i = 0; do { i++; if (i == 3) { break; } } while (true); i")), f64(3))
    // continue pula direto para a condição
    src := "var i = 0; var s = 0; do { i++; if (i == 2) { continue; } s += i; } while (i < 4); s"
    testing.expect_value(t, as_number(run(src)), f64(8)) // 1+3+4
}

@(test)
test_switch_basico :: proc(t: ^testing.T) {
    src := "function f(x) { switch (x) { case 1: return 'um'; case 2: return 'dois'; default: return 'outro'; } } f(2) + '/' + f(9)"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "dois/outro")
}

@(test)
test_switch_fallthrough :: proc(t: ^testing.T) {
    // sem break, cai para os cases seguintes
    src := "var r = ''; switch (2) { case 1: r += 'a'; case 2: r += 'b'; case 3: r += 'c'; break; case 4: r += 'd'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "bc")
}

@(test)
test_switch_estrito :: proc(t: ^testing.T) {
    // case usa igualdade ESTRITA: '1' não casa com 1
    src := "var r = ''; switch ('1') { case 1: r = 'num'; break; default: r = 'def'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "def")
}

@(test)
test_switch_case_vazio_e_break_do_switch :: proc(t: ^testing.T) {
    // case vazio cai no seguinte; break sai do switch mas NÃO do for
    src := "var c = 0; for (var i = 0; i < 3; i++) { switch (i) { case 0: case 1: c++; break; default: c += 10; } } c"
    testing.expect_value(t, as_number(run(src)), f64(12)) // 1 + 1 + 10
}

@(test)
test_switch_continue_atravessa :: proc(t: ^testing.T) {
    // continue dentro do switch age no LOOP externo
    src := "var s = 0; for (var i = 0; i < 4; i++) { switch (i % 2) { case 0: continue; } s += i; } s"
    testing.expect_value(t, as_number(run(src)), f64(4)) // só ímpares: 1+3
}

// ── M19: Promise ──────────────────────────────────────────────────────────────

@(test)
test_promise_resolve_then :: proc(t: ^testing.T) {
    // reação é microtask: na mesma tarefa `got` ainda é -1; depois do checkpoint, 42
    src := "var got = -1; Promise.resolve(42).then(v => got = v); var sync = got;"
    testing.expect_value(t, as_number(run_settled(src, "sync")), f64(-1))
    testing.expect_value(t, as_number(run_settled(src, "got")), f64(42))
}

@(test)
test_promise_encadeamento :: proc(t: ^testing.T) {
    // then devolve promise derivada; o valor flui transformado pela cadeia
    src := "var r = -1; Promise.resolve(5).then(v => v * 2).then(v => v + 1).then(v => r = v);"
    testing.expect_value(t, as_number(run_settled(src, "r")), f64(11))
}

@(test)
test_promise_catch :: proc(t: ^testing.T) {
    src := "var e = ''; Promise.reject('falhou').catch(x => e = 'pego:' + x);"
    v, _ := run_settled(src, "e").(string)
    testing.expect_value(t, v, "pego:falhou")
}

@(test)
test_promise_throw_no_then_vira_reject :: proc(t: ^testing.T) {
    // exceção dentro do then rejeita a derivada -> catch a pega
    src := "var e = ''; Promise.resolve(1).then(function(v) { throw new Error('boom'); }).catch(x => e = x.message);"
    v, _ := run_settled(src, "e").(string)
    testing.expect_value(t, v, "boom")
}

@(test)
test_promise_reject_passa_pelo_then :: proc(t: ^testing.T) {
    // then sem handler de erro é passthrough: a rejeição segue até o catch
    src := "var e = ''; Promise.reject('x').then(v => 'nunca').catch(r => e = 'fim:' + r);"
    v, _ := run_settled(src, "e").(string)
    testing.expect_value(t, v, "fim:x")
}

@(test)
test_promise_executor :: proc(t: ^testing.T) {
    // new Promise(executor) com resolve guardado e chamado DEPOIS
    src := `
        var res;
        var p = new Promise(function(resolve, reject) { res = resolve; });
        var got = 'pendente';
        p.then(v => got = v);
        var antes = got;    // ainda pendente quando o then registrou
        res('agora');
        var depois = got;   // settle só ENFILEIRA: na mesma tarefa continua pendente
    `
    v, _ := run_settled(src, "antes + '/' + depois + '/' + got").(string)
    testing.expect_value(t, v, "pendente/pendente/agora")
}

@(test)
test_promise_executor_throw :: proc(t: ^testing.T) {
    src := "var e = ''; new Promise(function() { throw 'no executor'; }).catch(x => e = x);"
    v, _ := run_settled(src, "e").(string)
    testing.expect_value(t, v, "no executor")
}

@(test)
test_promise_adocao :: proc(t: ^testing.T) {
    // then que devolve OUTRA promise: a derivada espera/adota a interna
    // (é o padrão fetch(u).then(r => r.json()).then(data => ...))
    src := "var r = -1; Promise.resolve(3).then(v => Promise.resolve(v * 10)).then(v => r = v);"
    testing.expect_value(t, as_number(run_settled(src, "r")), f64(30))
}

// ── M20: async / await ────────────────────────────────────────────────────────

@(test)
test_async_devolve_promise :: proc(t: ^testing.T) {
    // o retorno de uma async fn vira Promise cumprida; o then roda no checkpoint
    src := "async function f() { return 5; } var got = -1; f().then(v => got = v);"
    testing.expect_value(t, as_number(run_settled(src, "got")), f64(5))
}

@(test)
test_await_valor_e_promise :: proc(t: ^testing.T) {
    // await de não-promise devolve o valor; de promise, o valor assentado
    src := "async function f() { var a = await 3; var b = await Promise.resolve(4); return a + b; } var g = -1; f().then(v => g = v);"
    testing.expect_value(t, as_number(run_settled(src, "g")), f64(7))
}

@(test)
test_await_sequencial :: proc(t: ^testing.T) {
    src := "async function f() { var a = await Promise.resolve(1); var b = await Promise.resolve(a + 1); return b * 10; } var g = -1; f().then(v => g = v);"
    testing.expect_value(t, as_number(run_settled(src, "g")), f64(20))
}

@(test)
test_await_rejeicao_try_catch :: proc(t: ^testing.T) {
    // await de promise rejeitada lança — capturável com try/catch normal
    src := "async function f() { try { await Promise.reject('x'); return 'nao'; } catch (e) { return 'pego:' + e; } } var g = ''; f().then(v => g = v);"
    v, _ := run_settled(src, "g").(string)
    testing.expect_value(t, v, "pego:x")
}

@(test)
test_async_throw_vira_rejeicao :: proc(t: ^testing.T) {
    src := "async function f() { throw new Error('e1'); } var g = ''; f().catch(e => g = e.message);"
    v, _ := run_settled(src, "g").(string)
    testing.expect_value(t, v, "e1")
}

@(test)
test_async_arrow :: proc(t: ^testing.T) {
    src := "var f = async x => (await Promise.resolve(x)) * 2; var g = -1; f(21).then(v => g = v);"
    testing.expect_value(t, as_number(run_settled(src, "g")), f64(42))
}

@(test)
test_await_top_level :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var v = await Promise.resolve(9); v")), f64(9))
}

@(test)
test_await_timer_real :: proc(t: ^testing.T) {
    // M130: o await deixou de ser BLOQUEANTE — a async function suspende e retoma
    // por microtask quando a promise assenta. Logo `done` NÃO está pronto ao voltar
    // de f(): é preciso rodar o loop de eventos, como num navegador de verdade.
    // (A expectativa antiga — ler `done` na linha seguinte — codificava o modelo
    // bloqueante antigo, não a semântica de JS.)
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var done = -1;
        async function f() {
            var v = await new Promise(function(res) { setTimeout(function() { res(7); }, 20); });
            done = v * 2;
        }
        f();
    `)
    for _ in 0 ..< 200 { // ~200 x 1ms: o timer de 20ms vence e a corrotina retoma
        vm_pump_timers(vm, 1)
        if as_number(vm_run(vm, "done")) == 14 do break
    }
    testing.expect_value(t, as_number(vm_run(vm, "done")), f64(14))
}

@(test)
test_async_nao_e_asincrona_o_nome :: proc(t: ^testing.T) {
    // `async` como nome de variável/chamada comum não confunde o parser
    src := "var async = 10; async + 1"
    testing.expect_value(t, as_number(run(src)), f64(11))
}

@(test)
test_promise_settle_uma_vez :: proc(t: ^testing.T) {
    // resolve/reject depois de assentada são ignorados (idempotência)
    src := `
        var n = 0;
        var p = new Promise(function(resolve, reject) { resolve(1); resolve(2); reject(3); });
        p.then(function(v) { n = v; });
    `
    testing.expect_value(t, as_number(run_settled(src, "n")), f64(1))
}

// ── M12: JSON ─────────────────────────────────────────────────────────────────

@(test)
test_json_stringify :: proc(t: ^testing.T) {
    a, _ := run("JSON.stringify([1, 'a', true, null]) == '[1,\"a\",true,null]'").(bool)
    b, _ := run("JSON.stringify({ x: 42 }) == '{\"x\":42}'").(bool)
    testing.expect(t, a && b, "stringify de array e objeto")
}

@(test)
test_json_stringify_pula_funcao :: proc(t: ^testing.T) {
    // função em objeto some; undefined em array vira null
    a, _ := run("JSON.stringify({ f: function() {} }) == '{}'").(bool)
    b, _ := run("JSON.stringify([1, undefined, 2]) == '[1,null,2]'").(bool)
    testing.expect(t, a && b, "função some; undefined em array vira null")
}

@(test)
test_json_parse :: proc(t: ^testing.T) {
    src := `var o = JSON.parse('{"nome": "ana", "nums": [1, 2.5, true, null]}');
            o.nome + ':' + o.nums.length + ':' + o.nums[1]`
    v, _ := run(src).(string)
    testing.expect_value(t, v, "ana:4:2.5")
}

@(test)
test_json_roundtrip :: proc(t: ^testing.T) {
    src := "var o = { a: [1, 2, { b: 'x' }] }; JSON.parse(JSON.stringify(o)).a[2].b"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "x")
}

@(test)
test_json_parse_erro_lanca :: proc(t: ^testing.T) {
    src := "var r = 'ok'; try { JSON.parse('{invalido'); } catch (e) { r = 'erro'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "erro")
}

@(test)
test_json_circular_lanca :: proc(t: ^testing.T) {
    src := "var o = {}; o.self = o; var r = ''; try { JSON.stringify(o); } catch (e) { r = 'circ'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "circ")
}

// ── M12: métodos de array restantes ──────────────────────────────────────────

@(test)
test_sort :: proc(t: ^testing.T) {
    a, _ := run("[3, 1, 2].sort(function(a, b) { return a - b; }).join(',') == '1,2,3'").(bool)
    b, _ := run("[10, 9, 1].sort().join(',') == '1,10,9'").(bool) // default = ordem de STRING
    c, _ := run("[3, 1, 2].sort(function(a, b) { return b - a; }).join(',') == '3,2,1'").(bool)
    testing.expect(t, a && b && c, "sort com e sem comparador")
}

@(test)
test_reduce :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("[1,2,3,4].reduce(function(a, b) { return a + b; }, 0)")), f64(10))
    testing.expect_value(t, as_number(run("[1,2,3].reduce(function(a, b) { return a + b; })")), f64(6)) // sem init
}

@(test)
test_reduce_vazio_lanca :: proc(t: ^testing.T) {
    src := "var r = ''; try { [].reduce(function(a, b) { return a + b; }); } catch (e) { r = 'x'; } r"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "x")
}

@(test)
test_concat_find_some_every :: proc(t: ^testing.T) {
    a, _ := run("[1,2].concat([3,4], 5).join('') == '12345'").(bool)
    b, _ := run("[5,8,12].find(function(x) { return x > 6; }) == 8").(bool)
    c, _ := run("[5,8,12].findIndex(function(x) { return x > 6; }) == 1").(bool)
    d, _ := run("[1,2,3].some(function(x) { return x == 2; }) && [2,4].every(function(x) { return x % 2 == 0; })").(bool)
    testing.expect(t, a && b && c && d, "concat/find/findIndex/some/every")
}

@(test)
test_shift_unshift :: proc(t: ^testing.T) {
    src := "var a = [2, 3]; a.unshift(0, 1); var x = a.shift(); x + ':' + a.join('')"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "0:123")
}

@(test)
test_splice :: proc(t: ^testing.T) {
    src := "var a = [1,2,3,4,5]; var rem = a.splice(1, 2, 9); rem.join('') + ':' + a.join('')"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "23:1945")
}

// ── M12: métodos de string restantes ──────────────────────────────────────────

@(test)
test_replace :: proc(t: ^testing.T) {
    a, _ := run("'a-b-c'.replace('-', '+') == 'a+b-c'").(bool)      // só a 1ª
    b, _ := run("'a-b-c'.replaceAll('-', '+') == 'a+b+c'").(bool)   // todas
    testing.expect(t, a && b, "replace/replaceAll")
}

@(test)
test_starts_ends_pad :: proc(t: ^testing.T) {
    a, _ := run("'arquivo.png'.endsWith('.png') && 'http://x'.startsWith('http')").(bool)
    b, _ := run("'7'.padStart(3, '0') == '007'").(bool)
    c, _ := run("'ab'.padEnd(5, '.') == 'ab...'").(bool)
    testing.expect(t, a && b && c, "startsWith/endsWith/padStart/padEnd")
}

@(test)
test_boolean_ctor :: proc(t: ^testing.T) {
    // Boolean(x) = ToBoolean. Faltava como global; quebrava `arr.filter(Boolean)`.
    a, _ := run("Boolean(1) === true && Boolean(0) === false").(bool)
    b, _ := run("Boolean('') === false && Boolean('x') === true").(bool)
    c, _ := run("Boolean() === false && Boolean(null) === false").(bool)
    d, _ := run("typeof Boolean === 'function'").(bool)
    e, _ := run("[1,0,2,'',3,null].filter(Boolean).join(',') === '1,2,3'").(bool)
    testing.expect(t, a && b && c && d && e, "Boolean(x) + filter(Boolean)")
}

@(test)
test_computed_set_on_function :: proc(t: ^testing.T) {
    // `fn[k] = v` (chave computada) numa FUNÇÃO precisa gravar como propriedade —
    // set_index não tratava ^Function e ignorava a escrita (só `fn.x` nomeado
    // funcionava). Era a RAIZ de "$ is not a function": jQuery.extend copia via
    // `target[c] = src[c]` sobre o jQuery (função) → nada colava → init abortava.
    a, _ := run(`var f = function(){}; f['y'] = 7; f.y`).(f64)
    b, _ := run(`var f = function(){}; var k = 'z'; f[k] = 9; f.z`).(f64)
    // padrão exato do jQuery.extend: copiar props de um objeto p/ uma função via for-in
    c, _ := run(`
        var jq = function(){};
        var src = { ready: function(){ return 'R'; }, foo: 42 };
        for (var c in src) jq[c] = src[c];
        typeof jq.ready + '|' + jq.foo
    `).(string)
    testing.expect(t, a == 7 && b == 9 && c == "function|42", "computed set em ^Function")
}

@(test)
test_string_concat :: proc(t: ^testing.T) {
    // String.prototype.concat: ToString(this) + ToString de cada arg. Faltava —
    // era o gap de motor mais comum entre sites reais (gap-miner, 17 sites).
    a, _ := run("'ab'.concat('cd') === 'abcd'").(bool)
    b, _ := run("'a'.concat('b', 'c', 'd') === 'abcd'").(bool)
    c, _ := run("'n='.concat(1, true, null) === 'n=1truenull'").(bool) // args coagidos via ToString
    d, _ := run("''.concat() === ''").(bool)
    e, _ := run("String.prototype.concat.call('x', 'y') === 'xy'").(bool)
    f, _ := run("typeof ''.concat === 'function'").(bool)
    testing.expect(t, a && b && c && d && e && f, "String.prototype.concat")
}

// ── M21 fatia 0: protótipos + Object.* ────────────────────────────────────────

@(test)
test_object_keys_values :: proc(t: ^testing.T) {
    n := as_number(run("var o = {a:1, b:2, c:3}; Object.keys(o).length"))
    testing.expect_value(t, n, f64(3))
    // ordem do map é instável: somamos os valores em vez de comparar posições
    s := as_number(run("var o = {a:1, b:2, c:3}; var t = 0; Object.values(o).forEach(v => t += v); t"))
    testing.expect_value(t, s, f64(6))
}

@(test)
test_object_entries :: proc(t: ^testing.T) {
    // 1 chave => ordem determinística
    v, _ := run("var e = Object.entries({x: 9}); e[0][0] + '=' + e[0][1]").(string)
    testing.expect_value(t, v, "x=9")
}

@(test)
test_object_assign :: proc(t: ^testing.T) {
    n := as_number(run("var d = Object.assign({a:1}, {b:2}, {a:5}); d.a + d.b"))
    testing.expect_value(t, n, f64(7)) // a sobrescrito por 5, b = 2
}

@(test)
test_prototype_chain :: proc(t: ^testing.T) {
    // método herdado via cadeia de protótipo (Object.create)
    n := as_number(run("var base = {saudar: function(){ return 42; }}; var o = Object.create(base); o.saudar()"))
    testing.expect_value(t, n, f64(42))
}

@(test)
test_prototype_shadowing :: proc(t: ^testing.T) {
    // escrita cria prop PRÓPRIA (não muda o proto); leitura acha a própria antes
    src := "var base = {x: 1}; var o = Object.create(base); o.x = 9; o.x * 100 + base.x"
    testing.expect_value(t, as_number(run(src)), f64(901))
}

@(test)
test_object_freeze :: proc(t: ^testing.T) {
    // escrita em objeto congelado é ignorada silenciosamente
    testing.expect_value(t, as_number(run("var o = Object.freeze({v: 3}); o.v = 99; o.v")), f64(3))
}

@(test)
test_has_own_property :: proc(t: ^testing.T) {
    a, _ := run("({a:1}).hasOwnProperty('a')").(bool)
    b, _ := run("var o = Object.create({herdado: 1}); o.hasOwnProperty('herdado')").(bool)
    testing.expect(t, a && !b, "hasOwnProperty: própria sim, herdada não")
}

@(test)
test_get_prototype_of :: proc(t: ^testing.T) {
    // getPrototypeOf devolve o objeto base; lemos uma prop dele pra confirmar
    n := as_number(run("var base = {tag: 7}; var o = Object.create(base); Object.getPrototypeOf(o).tag"))
    testing.expect_value(t, n, f64(7))
}

// ── M21 fatia 1: class ────────────────────────────────────────────────────────

@(test)
test_class_basica :: proc(t: ^testing.T) {
    src := `
        class Ponto {
            constructor(x, y) { this.x = x; this.y = y; }
            soma() { return this.x + this.y; }
        }
        var p = new Ponto(3, 4);
        p.soma()
    `
    testing.expect_value(t, as_number(run(src)), f64(7))
}

@(test)
test_class_metodo_no_prototype :: proc(t: ^testing.T) {
    // duas instâncias compartilham o método (vive no prototype, não na instância)
    src := `
        class C { constructor(v){ this.v = v; } dobro(){ return this.v * 2; } }
        var a = new C(5); var b = new C(10);
        a.dobro() + b.dobro()
    `
    testing.expect_value(t, as_number(run(src)), f64(30))
}

@(test)
test_class_heranca :: proc(t: ^testing.T) {
    // método herdado da superclasse via cadeia de prototype
    src := `
        class Animal { som(){ return 'generico'; } patas(){ return 4; } }
        class Cachorro extends Animal { som(){ return 'au'; } }
        var d = new Cachorro();
        d.som() + ':' + d.patas()
    `
    v, _ := run(src).(string)
    testing.expect_value(t, v, "au:4")
}

@(test)
test_class_super_construtor :: proc(t: ^testing.T) {
    // super(...) chama a construtora da base com o mesmo this
    src := `
        class Base { constructor(n){ this.n = n; } }
        class Sub extends Base {
            constructor(n){ super(n); this.dobro = n * 2; }
        }
        var s = new Sub(6);
        s.n + s.dobro
    `
    testing.expect_value(t, as_number(run(src)), f64(18)) // 6 + 12
}

@(test)
test_class_super_metodo :: proc(t: ^testing.T) {
    // super.metodo() chama a versão da base, mas com o this atual
    src := `
        class A { desc(){ return 'A'; } }
        class B extends A { desc(){ return super.desc() + 'B'; } }
        var b = new B();
        b.desc()
    `
    v, _ := run(src).(string)
    testing.expect_value(t, v, "AB")
}

@(test)
test_class_default_ctor_deriva :: proc(t: ^testing.T) {
    // classe derivada SEM construtor: o default encaminha os args ao super
    src := `
        class Base { constructor(x){ this.x = x; } }
        class Sub extends Base {}
        var s = new Sub(42);
        s.x
    `
    testing.expect_value(t, as_number(run(src)), f64(42))
}

@(test)
test_class_static :: proc(t: ^testing.T) {
    // método static vive na própria classe, não nas instâncias
    src := `
        class M { static origem(){ return 100; } }
        M.origem()
    `
    testing.expect_value(t, as_number(run(src)), f64(100))
}

@(test)
test_class_expressao :: proc(t: ^testing.T) {
    // class como expressão + método chamado na hora
    src := "var C = class { valor(){ return 9; } }; new C().valor()"
    testing.expect_value(t, as_number(run(src)), f64(9))
}

// ── M21 fatia 2: destructuring ────────────────────────────────────────────────

@(test)
test_destruct_objeto :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var {a, b} = {a: 3, b: 4}; a + b")), f64(7))
}

@(test)
test_destruct_objeto_rename :: proc(t: ^testing.T) {
    // {a: x} liga a chave `a` à variável `x`
    testing.expect_value(t, as_number(run("var {a: x, b: y} = {a: 10, b: 5}; x - y")), f64(5))
}

@(test)
test_destruct_objeto_default :: proc(t: ^testing.T) {
    // default entra só quando a chave está ausente (undefined)
    n := as_number(run("var {a = 1, b = 2} = {a: 100}; a + b")) // 100 + 2
    testing.expect_value(t, n, f64(102))
}

@(test)
test_destruct_array :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var [x, y, z] = [1, 2, 3]; x*100 + y*10 + z")), f64(123))
}

@(test)
test_destruct_array_buraco :: proc(t: ^testing.T) {
    // buraco: pula o índice do meio
    testing.expect_value(t, as_number(run("var [a, , c] = [7, 8, 9]; a*10 + c")), f64(79))
}

@(test)
test_destruct_aninhado :: proc(t: ^testing.T) {
    // objeto dentro de objeto e array dentro de objeto
    src := "var {p: {x}, arr: [primeiro]} = {p: {x: 5}, arr: [9, 8]}; x*10 + primeiro"
    testing.expect_value(t, as_number(run(src)), f64(59))
}

@(test)
test_destruct_param :: proc(t: ^testing.T) {
    // parâmetro desestruturado — o padrão React ({props}) => ...
    src := "var f = ({titulo, n}) => titulo + ':' + n; f({titulo: 'oi', n: 3})"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "oi:3")
}

@(test)
test_destruct_param_default :: proc(t: ^testing.T) {
    // default dentro de param desestruturado, chave ausente
    src := "function g({x, y = 9}) { return x + y; } g({x: 1})"
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
test_destruct_array_param :: proc(t: ^testing.T) {
    src := "function h([a, b]) { return a * b; } h([6, 7])"
    testing.expect_value(t, as_number(run(src)), f64(42))
}

// ── M21 fatia 3: spread/rest ──────────────────────────────────────────────────

@(test)
test_spread_call :: proc(t: ^testing.T) {
    // f(...arr) espalha o array como argumentos
    src := "function soma(a, b, c) { return a + b + c; } var v = [1, 2, 3]; soma(...v)"
    testing.expect_value(t, as_number(run(src)), f64(6))
}

@(test)
test_spread_call_misto :: proc(t: ^testing.T) {
    // args fixos + spread no meio
    src := "function f(a, b, c, d) { return a*1000 + b*100 + c*10 + d; } f(1, ...[2, 3], 4)"
    testing.expect_value(t, as_number(run(src)), f64(1234))
}

@(test)
test_spread_array :: proc(t: ^testing.T) {
    // [...a, x, ...b] concatena
    src := "var a = [1, 2]; var b = [4, 5]; var c = [...a, 3, ...b]; c.join('')"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "12345")
}

@(test)
test_spread_objeto :: proc(t: ^testing.T) {
    // {...o, k: v} copia e sobrescreve
    src := "var o = {a: 1, b: 2}; var n = {...o, b: 9, c: 3}; n.a*100 + n.b*10 + n.c"
    testing.expect_value(t, as_number(run(src)), f64(193)) // a=1, b=9(sobrescrito), c=3
}

@(test)
test_rest_param :: proc(t: ^testing.T) {
    // ...args recolhe os argumentos restantes num array
    src := "function f(primeiro, ...resto) { return primeiro + ':' + resto.length + ':' + resto.join(','); } f(9, 1, 2, 3)"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "9:3:1,2,3")
}

@(test)
test_rest_array_pattern :: proc(t: ^testing.T) {
    // [a, ...resto] no destructuring
    src := "var [a, ...resto] = [10, 20, 30, 40]; a + ':' + resto.join('')"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "10:203040")
}

@(test)
test_rest_object_pattern :: proc(t: ^testing.T) {
    // {a, ...resto} recolhe as chaves não citadas
    src := "var {a, ...resto} = {a: 1, b: 2, c: 3}; a*100 + resto.b*10 + resto.c"
    testing.expect_value(t, as_number(run(src)), f64(123))
}

@(test)
test_object_shorthand :: proc(t: ^testing.T) {
    // {x, y} == {x: x, y: y}
    src := "var x = 4; var y = 7; var o = {x, y}; o.x*10 + o.y"
    testing.expect_value(t, as_number(run(src)), f64(47))
}

// ── M21 fatia 4: for-of / for-in ──────────────────────────────────────────────

@(test)
test_for_of_array :: proc(t: ^testing.T) {
    src := "var s = 0; for (const x of [10, 20, 30]) { s += x; } s"
    testing.expect_value(t, as_number(run(src)), f64(60))
}

@(test)
test_for_of_string :: proc(t: ^testing.T) {
    // itera code points; concatena invertendo via unshift
    src := "var out = ''; for (var c of 'abc') { out = c + out; } out"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "cba")
}

@(test)
test_for_of_destructuring :: proc(t: ^testing.T) {
    // for-of com padrão no binding (pares [chave, valor])
    src := "var t = 0; for (const [k, v] of [[1, 2], [3, 4]]) { t += k * v; } t"
    testing.expect_value(t, as_number(run(src)), f64(14)) // 1*2 + 3*4
}

@(test)
test_for_in_objeto :: proc(t: ^testing.T) {
    // soma os valores percorrendo as chaves (ordem instável -> soma)
    src := "var o = {a: 1, b: 2, c: 3}; var s = 0; for (var k in o) { s += o[k]; } s"
    testing.expect_value(t, as_number(run(src)), f64(6))
}

@(test)
test_for_in_array_indices :: proc(t: ^testing.T) {
    // for-in de array dá os índices (como strings "0","1",...)
    src := "var arr = [9, 8, 7]; var idx = ''; for (var i in arr) { idx += i; } idx"
    v, _ := run(src).(string)
    testing.expect_value(t, v, "012")
}

@(test)
test_for_of_break_continue :: proc(t: ^testing.T) {
    // continue pula pares, break encerra
    src := `
        var s = 0;
        for (const x of [1, 2, 3, 4, 5, 6]) {
            if (x == 2) continue;
            if (x == 5) break;
            s += x;
        }
        s
    `
    testing.expect_value(t, as_number(run(src)), f64(8)) // 1 + 3 + 4
}

@(test)
test_for_of_nao_quebra_classico :: proc(t: ^testing.T) {
    // garante que o for clássico segue funcionando (com let no init)
    src := "var s = 0; for (let i = 0; i < 4; i++) { s += i; } s"
    testing.expect_value(t, as_number(run(src)), f64(6)) // 0+1+2+3
}

// ── M22: regex (fatia 1) — JS em raw strings (crases) p/ backslash literal ────

@(test)
test_regex_test_basico :: proc(t: ^testing.T) {
    a, _ := run(`/abc/.test('xabcy')`).(bool)
    b, _ := run(`/abc/.test('xyz')`).(bool)
    testing.expect(t, a && !b, "test: acha 'abc' em 'xabcy', não em 'xyz'")
}

@(test)
test_regex_ancoras_digitos :: proc(t: ^testing.T) {
    a, _ := run(`/^\d+$/.test('123')`).(bool)
    b, _ := run(`/^\d+$/.test('12a')`).(bool)
    testing.expect(t, a && !b, "^\\d+$ casa só dígitos do início ao fim")
}

@(test)
test_regex_classe_quantificador :: proc(t: ^testing.T) {
    v, _ := run(`/[a-c]+/.exec('xxbcay')[0]`).(string)
    testing.expect_value(t, v, "bca")
}

@(test)
test_regex_grupos_captura :: proc(t: ^testing.T) {
    a, _ := run(`/(\d+)-(\d+)/.exec('12-34')[1] === '12'`).(bool)
    b, _ := run(`/(\d+)-(\d+)/.exec('12-34')[2] === '34'`).(bool)
    testing.expect(t, a && b, "grupos capturam '12' e '34'")
}

@(test)
test_regex_alternancia :: proc(t: ^testing.T) {
    a, _ := run(`/cat|dog/.test('hotdog')`).(bool)
    b, _ := run(`/cat|dog/.test('bird')`).(bool)
    testing.expect(t, a && !b, "cat|dog casa 'hotdog', não 'bird'")
}

@(test)
test_regex_quantificadores :: proc(t: ^testing.T) {
    a, _ := run(`/ab?c/.test('ac')`).(bool)          // ? opcional
    v, _ := run(`/a{2,3}/.exec('aaaa')[0]`).(string)  // {2,3} greedy
    testing.expect(t, a, "ab?c casa 'ac'")
    testing.expect_value(t, v, "aaa")
}

@(test)
test_regex_flag_i :: proc(t: ^testing.T) {
    a, _ := run(`/ABC/i.test('xabcy')`).(bool)
    testing.expect(t, a, "flag i: ABC casa 'abc'")
}

@(test)
test_regex_word_boundary :: proc(t: ^testing.T) {
    a, _ := run(`/\bword\b/.test('a word here')`).(bool)
    b, _ := run(`/\bword\b/.test('sword')`).(bool)
    testing.expect(t, a && !b, "\\bword\\b: palavra isolada sim, dentro de 'sword' não")
}

@(test)
test_regex_lazy :: proc(t: ^testing.T) {
    v, _ := run(`/a.*?b/.exec('axbxb')[0]`).(string) // lazy pega o menor
    testing.expect_value(t, v, "axb")
}

@(test)
test_regex_new_regexp :: proc(t: ^testing.T) {
    a, _ := run(`new RegExp('\\d+').test('a5')`).(bool)
    b, _ := run(`new RegExp('ab', 'i').test('XAB')`).(bool)
    testing.expect(t, a && b, "new RegExp(padrão, flags)")
}

@(test)
test_regex_exec_global_loop :: proc(t: ^testing.T) {
    src := `
        var re = /\d+/g; var s = '1 22 333'; var out = '';
        var m;
        while ((m = re.exec(s)) !== null) out += m[0] + ',';
        out
    `
    v, _ := run(src).(string)
    testing.expect_value(t, v, "1,22,333,")
}

@(test)
test_regex_source_flags :: proc(t: ^testing.T) {
    a, _ := run(`/ab/gi.source === 'ab'`).(bool)
    b, _ := run(`/ab/gi.flags === 'gi'`).(bool)
    c, _ := run(`/x/g.global`).(bool)
    testing.expect(t, a && b && c, "source/flags/global")
}

@(test)
test_regex_typeof :: proc(t: ^testing.T) {
    v, _ := run(`typeof /x/`).(string)
    testing.expect_value(t, v, "object")
}

@(test)
test_regex_divisao_nao_confunde :: proc(t: ^testing.T) {
    // `/` como divisão ainda funciona (não vira regex após identificador/número)
    testing.expect_value(t, as_number(run(`var a = 10; var b = 2; a / b / 1`)), f64(5))
}

// ── Map / Set / WeakMap / WeakSet ─────────────────────────────────────────────

@(test)
test_map_basico :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var m=new Map(); m.set('a',1); m.set('b',2); m.get('a')+m.get('b')`)), f64(3))
}

@(test)
test_map_has_size_delete :: proc(t: ^testing.T) {
    v, _ := run(`var m=new Map(); m.set('x',1); m.has('x') && m.size===1 && m.delete('x') && m.size===0 && !m.has('x')`).(bool)
    testing.expect(t, v, "has/size/delete")
}

@(test)
test_map_chave_objeto :: proc(t: ^testing.T) {
    // chaves por identidade (SameValueZero): o mesmo objeto acha; outro literal não
    testing.expect_value(t, as_number(run(`var k={}; var m=new Map(); m.set(k,42); m.get(k)`)), f64(42))
    v, _ := run(`var k={}; var m=new Map(); m.set(k,42); m.get({}) === undefined`).(bool)
    testing.expect(t, v, "objeto diferente não acha")
}

@(test)
test_map_set_chaining :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var m=new Map(); m.set('a',1).set('b',2); m.size`)), f64(2))
}

@(test)
test_map_init_e_forof :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var m=new Map([['a',1],['b',2]]); var s=0; for(const [k,v] of m) s+=v; s`)), f64(3))
}

@(test)
test_map_foreach :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var m=new Map([['a',1],['b',2]]); var s=0; m.forEach(function(v,k){s+=v}); s`)), f64(3))
}

@(test)
test_map_chave_nan :: proc(t: ^testing.T) {
    // SameValueZero: NaN é igual a NaN como chave
    testing.expect_value(t, as_number(run(`var m=new Map(); m.set(0/0,7); m.get(0/0)`)), f64(7))
}

@(test)
test_set_basico :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var s=new Set([1,2,2,3]); s.size`)), f64(3))
}

@(test)
test_set_add_has :: proc(t: ^testing.T) {
    v, _ := run(`var s=new Set(); s.add(5); s.has(5) && !s.has(6)`).(bool)
    testing.expect(t, v, "add/has")
}

@(test)
test_set_forof :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var s=new Set([1,2,3]); var t=0; for(const x of s) t+=x; t`)), f64(6))
}

@(test)
test_set_spread :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var s=new Set([1,2,3]); [...s].length`)), f64(3))
}

@(test)
test_weakmap :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var wm=new WeakMap(); var k={}; wm.set(k,7); wm.get(k)`)), f64(7))
}

@(test)
test_weakset :: proc(t: ^testing.T) {
    v, _ := run(`var ws=new WeakSet(); var o={}; ws.add(o); ws.has(o) && !ws.has({})`).(bool)
    testing.expect(t, v, "weakset add/has")
}

@(test)
test_coll_typeof :: proc(t: ^testing.T) {
    v, _ := run(`typeof new Map()`).(string)
    testing.expect_value(t, v, "object")
}

@(test)
test_private_field_helper_esbuild :: proc(t: ^testing.T) {
    // Replica o lowering de campos privados do esbuild (`#x` -> WeakMap/WeakSet).
    // Antes de Map/Set/WeakMap/WeakSet, isto lançava "Cannot write to private field".
    src := `
        var wm = new WeakMap();
        var add = function(o){ if (wm.has(o)) throw "dup"; wm.set(o, void 0); };
        var check = function(o){ if (!wm.has(o)) throw "Cannot write to private field"; return true; };
        var obj = {};
        add(obj);
        check(obj)
    `
    v, _ := run(src).(bool)
    testing.expect(t, v, "helper de campo privado do esbuild funciona")
}

@(test)
test_instanceof_colecoes :: proc(t: ^testing.T) {
    a, _ := run(`new Map() instanceof Map`).(bool)
    b, _ := run(`new WeakSet() instanceof WeakSet`).(bool)
    c, _ := run(`new Set() instanceof Map`).(bool) // falso: tipo errado
    testing.expect(t, a && b && !c, "instanceof de coleções")
}

@(test)
test_instanceof_classe :: proc(t: ^testing.T) {
    v, _ := run(`class A {}; class B extends A {}; var b = new B(); b instanceof A`).(bool)
    testing.expect(t, v, "instanceof sobe a cadeia de protótipo")
}

@(test)
test_instanceof_ternario_esbuild :: proc(t: ^testing.T) {
    // o padrão exato do helper do esbuild: `x instanceof WeakSet ? ... : ...`
    v, _ := run(`
        var privateAdd = function(o, member, value){
            if (member.has(o)) throw "dup";
            member instanceof WeakSet ? member.add(o) : member.set(o, value);
        };
        var wm = new WeakMap();
        var obj = {};
        privateAdd(obj, wm, 123);
        wm.get(obj)
    `).(bool)
    _ = v
    n := as_number(run(`
        var privateAdd = function(o, member, value){
            if (member.has(o)) throw "dup";
            member instanceof WeakSet ? member.add(o) : member.set(o, value);
        };
        var wm = new WeakMap();
        var obj = {};
        privateAdd(obj, wm, 123);
        wm.get(obj)
    `))
    testing.expect_value(t, n, f64(123))
}

@(test)
test_operador_virgula :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var x = (1, 2, 3); x`)), f64(3))         // grupo devolve o último
    testing.expect_value(t, as_number(run(`var a=0; var b=0; (a=5, b=7); a+b`)), f64(12)) // efeitos colaterais de todos
    testing.expect_value(t, as_number(run(`function f(){ return 1, 2, 3; } f()`)), f64(3)) // return sequência
}

@(test)
test_virgula_nao_afeta_args :: proc(t: ^testing.T) {
    // a vírgula em lista de args/array continua separando (não é sequência)
    testing.expect_value(t, as_number(run(`function f(a,b,c){ return a+b+c; } f(1,2,3)`)), f64(6))
    testing.expect_value(t, as_number(run(`var a=[1,2,3]; a.length`)), f64(3))
}

// ── M22 Fatia 2: String methods com regex ─────────────────────────────────────

@(test)
test_str_match_sem_g :: proc(t: ^testing.T) {
    // match sem g devolve [match, grupo1] como exec
    v, _ := run(`"abc123def".match(/(\d+)/)[0] === "123"`).(bool)
    testing.expect(t, v, "match sem g: match inteiro")
    v2, _ := run(`"abc123def".match(/(\d+)/)[1] === "123"`).(bool)
    testing.expect(t, v2, "match sem g: grupo 1")
}

@(test)
test_str_match_com_g :: proc(t: ^testing.T) {
    // match com g devolve array de todos os casamentos (sem grupos)
    testing.expect_value(t, as_number(run(`"a1b2c3".match(/\d/g).length`)), f64(3))
    v, _ := run(`"a1b2c3".match(/\d/g).join(",") === "1,2,3"`).(bool)
    testing.expect(t, v, "match /g coleta todos")
}

@(test)
test_str_match_sem_resultado :: proc(t: ^testing.T) {
    v, _ := run(`"abc".match(/\d/) === null`).(bool)
    testing.expect(t, v, "match sem resultado devolve null")
    v2, _ := run(`"abc".match(/\d/g) === null`).(bool)
    testing.expect(t, v2, "match /g sem resultado devolve null")
}

@(test)
test_str_match_string :: proc(t: ^testing.T) {
    // match com string compila regex
    v, _ := run(`"hello world".match("world")[0] === "world"`).(bool)
    testing.expect(t, v, "match com string")
}

@(test)
test_str_search :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`"abc123".search(/\d+/)`)), f64(3))
    testing.expect_value(t, as_number(run(`"abc".search(/\d+/)`)), f64(-1))
}

@(test)
test_str_search_string :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`"hello world".search("world")`)), f64(6))
}

@(test)
test_str_replace_regex :: proc(t: ^testing.T) {
    v, _ := run(`"abc123def".replace(/\d+/, "X") === "abcXdef"`).(bool)
    testing.expect(t, v, "replace regex sem g: 1ª ocorrência")
}

@(test)
test_str_replace_regex_global :: proc(t: ^testing.T) {
    v, _ := run(`"a1b2c3".replace(/\d/g, "X") === "aXbXcX"`).(bool)
    testing.expect(t, v, "replace regex /g: todas")
}

@(test)
test_str_replace_dollar_refs :: proc(t: ^testing.T) {
    v, _ := run(`"John Smith".replace(/(\w+) (\w+)/, "$2, $1") === "Smith, John"`).(bool)
    testing.expect(t, v, "$1 $2 substituição")
}

@(test)
test_str_replace_dollar_ampersand :: proc(t: ^testing.T) {
    v, _ := run(`"hello".replace(/ll/, "[$&]") === "he[ll]o"`).(bool)
    testing.expect(t, v, "$& = match inteiro")
}

@(test)
test_str_replace_dollar_escape :: proc(t: ^testing.T) {
    v, _ := run(`"abc".replace(/b/, "$$") === "a$c"`).(bool)
    testing.expect(t, v, "$$ vira $ literal")
}

@(test)
test_str_replace_funcao :: proc(t: ^testing.T) {
    v, _ := run(`"abc".replace(/[a-c]/g, function(m){ return m.toUpperCase(); }) === "ABC"`).(bool)
    testing.expect(t, v, "replace com função")
}

@(test)
test_str_replace_funcao_grupos :: proc(t: ^testing.T) {
    v, _ := run(`"12-34".replace(/(\d+)-(\d+)/, function(m,a,b){ return b+"-"+a; }) === "34-12"`).(bool)
    testing.expect(t, v, "função recebe grupos")
}

@(test)
test_str_replace_string_funcao :: proc(t: ^testing.T) {
    v, _ := run(`"hello".replace("l", function(m){ return "L"; }) === "heLlo"`).(bool)
    testing.expect(t, v, "replace string com função")
}

@(test)
test_str_replace_all_regex :: proc(t: ^testing.T) {
    v, _ := run(`"a1b2c3".replaceAll(/\d/g, "X") === "aXbXcX"`).(bool)
    testing.expect(t, v, "replaceAll com regex /g")
}

@(test)
test_str_replace_all_regex_sem_g_erro :: proc(t: ^testing.T) {
    // replaceAll com regex sem g deve lançar TypeError
    v, _ := run(`var r="ok"; try { "abc".replaceAll(/b/, "X"); } catch(e) { r=e.name; } r`).(string)
    testing.expect_value(t, v, "TypeError")
}

@(test)
test_str_split_regex :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`"a1b2c3d".split(/\d/).length`)), f64(4))
    v, _ := run(`"a1b2c3d".split(/\d/).join("|") === "a|b|c|d"`).(bool)
    testing.expect(t, v, "split por regex")
}

@(test)
test_str_split_regex_com_grupo :: proc(t: ^testing.T) {
    // grupo capturante inclui o separador no resultado
    v, _ := run(`"a1b2c".split(/(\d)/).join("|") === "a|1|b|2|c"`).(bool)
    testing.expect(t, v, "split regex com grupo inclui captura")
}

@(test)
test_str_split_limit :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`"a,b,c,d".split(",", 2).length`)), f64(2))
}

@(test)
test_str_last_index_of :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`"abcabc".lastIndexOf("bc")`)), f64(4))
    testing.expect_value(t, as_number(run(`"abc".lastIndexOf("x")`)), f64(-1))
}

@(test)
test_str_trim_start_end :: proc(t: ^testing.T) {
    v, _ := run(`"  hi  ".trimStart() === "hi  "`).(bool)
    testing.expect(t, v, "trimStart")
    v2, _ := run(`"  hi  ".trimEnd() === "  hi"`).(bool)
    testing.expect(t, v2, "trimEnd")
}

@(test)
test_str_at :: proc(t: ^testing.T) {
    v, _ := run(`"hello".at(0) === "h"`).(bool)
    testing.expect(t, v, "at(0)")
    v2, _ := run(`"hello".at(-1) === "o"`).(bool)
    testing.expect(t, v2, "at(-1)")
}

@(test)
test_array_from :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`Array.from([1,2,3]).length`)), f64(3))
    testing.expect_value(t, as_number(run(`Array.from("abc").length`)), f64(3))
}

@(test)
test_array_is_array :: proc(t: ^testing.T) {
    v, _ := run(`Array.isArray([1,2]) && !Array.isArray({})`).(bool)
    testing.expect(t, v, "isArray")
}

@(test)
test_is_finite :: proc(t: ^testing.T) {
    v, _ := run(`isFinite(42) && !isFinite(1/0) && !isFinite(0/0)`).(bool)
    testing.expect(t, v, "isFinite")
}

@(test)
test_number_string_ctors :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`Number("42")`)), f64(42))
    v, _ := run(`String(42) === "42"`).(bool)
    testing.expect(t, v, "String(42)")
}
