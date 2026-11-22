package js

import "core:testing"

// ── `with` (sloppy) ───────────────────────────────────────────────────────────
// Até aqui `with (o) stmt` parseava e lançava TypeError("not supported") em
// runtime. Agora o corpo roda com um AMBIENTE DE OBJETO na frente da cadeia
// (Env.with_obj): leitura, escrita, `typeof`, `delete`, `var` com inicializador,
// o `this` de `f()`, @@unscopables e referência resolvida UMA vez.

@(test)
test_with_leitura_escrita_e_fallback :: proc(t: ^testing.T) {
    src := `
        var r = [];
        var o = {x: 1}; var x = 'fora';
        with (o) { r.push(x); x = 2; }
        r.push(o.x, x);
        with (o) { novoGlobal = 5; }            // nome que o objeto não tem: escopo de fora
        r.push(novoGlobal, 'novoGlobal' in o);
        with (o) { r.push(typeof x, typeof naoExiste); }
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1,2,fora,5,false,number,undefined", "got %v", v)
}

@(test)
test_with_this_da_chamada_e_closure_viva :: proc(t: ^testing.T) {
    src := `
        var o = {k: 1, f: function(){ return this; }};
        var r = [];
        with (o) { r.push(f() === o); }
        var c; with (o) { c = function(){ return k; }; }
        o.k = 42; r.push(c());                   // a closure enxerga o objeto VIVO
        var tag = {t: function(){ return this; }};
        with (tag) { r.push(t` + "`x`" + ` === tag); }
        with ({this: 5}) { r.push(this !== 5); } // this não é referência de identificador
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "true,42,true,true", "got %v", v)
}

@(test)
test_with_var_delete_e_update :: proc(t: ^testing.T) {
    src := `
        var r = [];
        function g() { var o = {x: 0}; with (o) { var x = 9; } return [o.x, x]; }
        r.push(g().join('/'));                   // o inicializador vai p/ o objeto
        var p = {a: 1}; with (p) { delete a; } r.push('a' in p);
        var n = {v: 1}; with (n) { v++; v += 10; } r.push(n.v);
        var i; with ({}) { for (var i = 0; i < 3; i++) {} } r.push(i);
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "9/,false,12,3", "got %v", v)
}

@(test)
test_with_unscopables_e_tipos :: proc(t: ^testing.T) {
    src := `
        var r = [];
        var values = 'v'; with ([1,2,3]) { r.push(values, length); }   // Array.prototype[@@unscopables]
        var u = {k: 1}; u[Symbol.unscopables] = {k: true}; var k = 'kk';
        with (u) { r.push(k); }
        with ('abc') { r.push(length); }         // ToObject: wrapper de string
        try { with (null) {} } catch (e) { r.push(e.name); }
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "v,3,kk,3,TypeError", "got %v", v)
}

// Um getter de @@unscopables que muda a resposta a cada leitura: `x++` lê e escreve
// a MESMA referência (Test262 unscopables-inc-dec).
@(test)
test_with_referencia_resolvida_uma_vez :: proc(t: ^testing.T) {
    src := `
        var chamadas = 0, flag = true, a, b;
        with (a = {x: 7}) {
            with (b = {x: 4, get [Symbol.unscopables]() { chamadas++; return {x: flag = !flag}; }}) {
                x++;
            }
        }
        [chamadas, a.x, b.x].join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1,7,5", "got %v", v)
}

@(test)
test_with_proxy_has_trap :: proc(t: ^testing.T) {
    src := `
        var log = [];
        var px = new Proxy({q: 1}, { has: function(t, k){ log.push(String(k)); return k in t; } });
        var v; with (px) { v = q; }
        v + ':' + log.join('|')
    `
    v, _ := run(src).(string)
    // o alvo `v` resolve ANTES do RHS (has:v, false) e depois `q`: HasBinding (has)
    // + GetBindingValue (has de novo)
    testing.expectf(t, v == "1:v|q|q", "got %v", v)
}

@(test)
test_with_early_errors :: proc(t: ^testing.T) {
    m1, r1 := early_error_of("'use strict'; with ({}) {}")
    testing.expect(t, r1 && m1 == "Strict mode code may not include a with statement", m1)
    m2, r2 := early_error_of("with ({}) l1: l2: function f(){}")
    testing.expect(t, r2 && m2 == "In non-strict mode code, functions can only be declared at top level, inside a block, or as the body of an if statement.", m2)
    _, r3 := early_error_of("with ({}) { l: function f(){} }") // dentro de bloco é válido
    testing.expect(t, !r3, "label + function dentro de bloco no with foi rejeitado")
}
