package js

// M70 (2026-07-10): HOISTING de `var` function-scoped em blocos ANINHADOS.
// Bug: `var` declarado dentro de um bloco (case de switch, if, loop, try) NÃO
// era içado ao escopo de função — só os `var` no topo do corpo existiam. Quando
// a execução caía num ramo SEM a declaração e atribuía ao nome, `env_assign`
// subia a cadeia e criava a variável no GLOBAL (M54), corrompendo um homônimo de
// outra função. Era a raiz da tela-branca do tradebig: o `setInitialProperties`
// do React (`case"img": var a; ... case"meta": a=l[C]`) escrevia num `a` global
// que colidia com o `a` (elemento) do completeWork → `fiber.stateNode` virava a
// string do conteúdo → `stateNode.parentNode.removeChild` lançava no unmount.

import "core:testing"

// ── var em case de switch é içado (o caso EXATO do React setInitialProperties) ──

@(test)
test_var_hoist_switch_case :: proc(t: ^testing.T) {
    // `var a` só aparece no case 1, mas é usado (sem var) no case 2. Deve ser a
    // MESMA local hoisted, não um global implícito.
    testing.expect_value(t, run(`
        a = "GLOBAL";
        function f(k){
            switch(k){
                case 1: var a = "one"; break;
                case 2: a = "two"; return a;
            }
        }
        var r = f(2);
        r === "two" && a === "GLOBAL"
    `).(bool), true)
}

@(test)
test_var_hoist_cross_function :: proc(t: ^testing.T) {
    // reprodução direta do bug tradebig: duas funções, ambas com `var a` aninhado
    // em case; o callee (Pt) reatribui seu `a` local — NÃO pode corromper o `a`
    // (objeto) do caller.
    testing.expect_value(t, run(`
        function Pt(tag){
            switch(tag){
                case "img":  var a = false; break;
                case "meta": a = "LEAK"; return;
            }
        }
        function complete(){
            switch("go"){
                case "x": var a = 1; break;
                default:
                    a = { tag: "EL" };
                    Pt("meta");
                    return typeof a;
            }
        }
        complete()
    `).(string), "object")
}

// ── var em outros blocos aninhados ───────────────────────────────────────────

@(test)
test_var_hoist_if_block :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(c){
            if (c) { var x = 10; }
            return x;                 // x visível fora do if (function-scoped)
        }
        f(false) === undefined && f(true) === 10
    `).(bool), true)
}

@(test)
test_var_hoist_try_catch :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){
            try { var v = "T"; throw 1; }
            catch(e) { var w = "C"; }
            return v + w;             // v e w içados p/ a função
        }
        f()
    `).(string), "TC")
}

@(test)
test_var_hoist_for_body :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){
            for (var i = 0; i < 3; i++) { var last = i; }
            return i + "," + last;    // i e last vazam p/ a função
        }
        f()
    `).(string), "3,2")
}

@(test)
test_var_hoist_nested_blocks :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){
            { { { var deep = 42; } } }
            return deep;
        }
        f()
    `).(f64), 42)
}

// ── não vaza indevidamente: local sombreia; let/const continuam block-scoped ──

@(test)
test_var_hoist_no_leak_to_caller_local :: proc(t: ^testing.T) {
    // caller tem `var a` LOCAL; callee com `var a` aninhado não o toca.
    testing.expect_value(t, run(`
        function callee(){ switch(1){ case 2: var a; break; default: a = "X"; } }
        function caller(){ var a = "keep"; callee(); return a; }
        caller()
    `).(string), "keep")
}

@(test)
test_let_still_block_scoped :: proc(t: ^testing.T) {
    // let NÃO é içado à função — continua no bloco.
    testing.expect_value(t, run(`
        function f(){
            if (true) { let y = 1; }
            return typeof y;          // y não existe fora do if
        }
        f()
    `).(string), "undefined")
}

// ── declaração multi + destructuring içados ──────────────────────────────────

@(test)
test_var_hoist_destructuring :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(c){
            if (c) { var {p, q} = {p:1, q:2}; }
            return (p === undefined) + "," + (q === undefined);
        }
        f(false)                      // p e q existem (undefined), não lançam ReferenceError
    `).(string), "true,true")
}

// ── for (var x of/in ...): loop-var function-scoped (vaza + é içado) ──────────

@(test)
test_for_of_var_leaks_out :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){ for (var x of [10, 20, 30]) {} return x; } // x vaza c/ o último
        f()
    `).(f64), 30)
}

@(test)
test_for_in_var_leaks_out :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){ var last; for (var k in {a:1, b:2, c:3}) last = k; return k + last; }
        f()
    `).(string), "cc")
}

@(test)
test_for_of_let_does_not_leak :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){ for (let y of [1, 2]) {} return typeof y; } // let continua block-scoped
        f()
    `).(string), "undefined")
}

@(test)
test_for_of_var_closures_share_binding :: proc(t: ^testing.T) {
    // var é UM binding p/ o loop todo (não por iteração): closures veem o último valor
    testing.expect_value(t, run(`
        function f(){
            var fns = [];
            for (var i of [1, 2, 3]) fns.push(function(){ return i; });
            return fns[0]() + "," + fns[2]();
        }
        f()
    `).(string), "3,3")
}

@(test)
test_for_of_var_destructuring :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){ for (var [a, b] of [[1, 2]]) {} return a + "," + b; } // vaza
        f()
    `).(string), "1,2")
}

@(test)
test_for_of_var_hoisted_before_loop :: proc(t: ^testing.T) {
    // o loop pode nem rodar (ramo não tomado) e a var já existe (undefined), não lança
    testing.expect_value(t, run(`
        function f(cond){ if (cond) { for (var x of [7]) {} } return x; }
        (f(false) === undefined) && (f(true) === 7)
    `).(bool), true)
}
