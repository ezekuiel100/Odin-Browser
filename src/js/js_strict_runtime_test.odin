package js

import "core:testing"

// ── Strict mode em RUNTIME ────────────────────────────────────────────────────
// Até aqui o strict só existia para `arguments`, `this` e octal: escrita
// rejeitada era ignorada em silêncio e atribuir a nome não declarado criava um
// global, MESMO em código strict (módulos, classes, "use strict"). Agora o
// parser marca os nós de escrita com a strictness (Node.strict) e o
// interpretador transforma o [[Set]] que devolveu false em TypeError e a
// referência irresolúvel em ReferenceError — só nesses nós.

// Roda `corpo` (statements) como função strict e devolve o NOME do erro, ou "ok".
@(private = "file")
STRICT_HARNESS :: `
    function tipo(f) { try { f(); return 'ok'; } catch (e) { return e.name; } }
`

@(test)
test_strict_escrita_rejeitada_lanca :: proc(t: ^testing.T) {
    src := STRICT_HARNESS + `
        var r = [];
        r.push(tipo(function(){ 'use strict'; Object.freeze({a: 1}).a = 2; }));
        r.push(tipo(function(){ 'use strict'; var o = { get a(){ return 1 } }; o.a = 2; }));
        r.push(tipo(function(){ 'use strict'; Object.preventExtensions({}).b = 1; }));
        r.push(tipo(function(){ 'use strict'; var o = {}; Object.defineProperty(o, 'x', { value: 1 }); o.x = 2; }));
        r.push(tipo(function(){ 'use strict'; Object.create(Object.freeze({x: 1})).x = 2; }));
        r.push(tipo(function(){ 'use strict'; 'abc'.foo = 1; }));
        r.push(tipo(function(){ 'use strict'; Object.freeze([1])[0] = 2; }));
        r.push(tipo(function(){ 'use strict'; Object.freeze([1]).length = 0; }));
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError",
        "escritas rejeitadas em strict: got %v", v)
}

// Os mesmos casos em SLOPPY seguem silenciosos, e o valor não muda.
@(test)
test_sloppy_escrita_rejeitada_ignora :: proc(t: ^testing.T) {
    src := `
        var f = Object.freeze({a: 1}); f.a = 2;
        var g = { get a(){ return 1 } }; g.a = 2;
        var n = Object.preventExtensions({}); n.b = 1;
        var arr = Object.freeze([1]); arr[0] = 2; arr.length = 0;
        'abc'.foo = 1;
        f.a + ':' + g.a + ':' + ('b' in n) + ':' + arr[0] + ':' + arr.length
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1:1:false:1:1", "sloppy ignora sem lançar: got %v", v)
}

@(test)
test_strict_nome_nao_declarado_lanca :: proc(t: ^testing.T) {
    src := STRICT_HARNESS + `
        var r = [];
        r.push(tipo(function(){ 'use strict'; naoDeclaradoA = 1; }));
        r.push(tipo(function(){ 'use strict'; [naoDeclaradoB] = [1]; }));
        r.push(tipo(function(){ 'use strict'; ({ x: naoDeclaradoC } = { x: 1 }); }));
        r.push(tipo(function(){ 'use strict'; for (naoDeclaradoD of [1]) {} }));
        r.push(tipo(function(){ 'use strict'; var jaTem = 0; jaTem = 1; }));
        r.push(typeof naoDeclaradoA);
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "ReferenceError,ReferenceError,ReferenceError,ReferenceError,ok,undefined",
        "nome não declarado em strict: got %v", v)
}

// Atribuição composta, ++ e destructuring passam pelo mesmo funil.
@(test)
test_strict_composta_update_destructuring :: proc(t: ^testing.T) {
    src := STRICT_HARNESS + `
        var r = [];
        r.push(tipo(function(){ 'use strict'; var o = Object.freeze({a: 1}); o.a += 1; }));
        r.push(tipo(function(){ 'use strict'; var o = Object.freeze({a: 1}); o.a++; }));
        r.push(tipo(function(){ 'use strict'; var o = Object.freeze({a: 1}); [o.a] = [5]; }));
        r.push(tipo(function(){ 'use strict'; var o = Object.freeze({a: 1}); ({ k: o.a } = { k: 5 }); }));
        r.push(tipo(function(){ 'use strict'; var o = Object.freeze({a: 1}); o.a ??= 5; })); // não atribui
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "TypeError,TypeError,TypeError,TypeError,ok", "composta/update/destructuring: got %v", v)
}

// O que NÃO pode lançar: polyfill sobrescrevendo nativo, setter, sombra de
// herdado writable, prop estática em função, prop em Map (limitação do motor).
@(test)
test_strict_escritas_validas_seguem :: proc(t: ^testing.T) {
    src := `
        'use strict';
        var r = [];
        var velho = Array.prototype.includes;
        Array.prototype.includes = function(){ return 42; };
        r.push([].includes());
        Array.prototype.includes = velho;
        var x; var s = { set a(v){ x = v; } }; s.a = 7; r.push(x);
        var p = { y: 1 }; var o = Object.create(p); o.y = 2; r.push(o.y + '/' + p.y);
        function F(){} F.cache = 3; r.push(F.cache);
        var m = new Map(); m.extra = 1; r.push('map');
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "42,7,2/1,3,map", "escritas válidas em strict: got %v", v)
}

// delete de não-configurável: false em sloppy (antes devolvia true), TypeError em strict.
@(test)
test_delete_nao_configuravel :: proc(t: ^testing.T) {
    src := STRICT_HARNESS + `
        var o = {}; Object.defineProperty(o, 'k', { value: 1 });
        var r = [delete o.k, delete [].length, delete Object.prototype, delete ({a: 1}).a];
        r.push(tipo(function(){ 'use strict'; delete o.k; }));
        r.push(tipo(function(){ 'use strict'; delete Object.prototype; }));
        r.push(tipo(function(){ 'use strict'; var q = {a: 1}; delete q.a; }));
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "false,false,false,true,TypeError,TypeError,ok", "delete não-configurável: got %v", v)
}

// eval strict (herdado ou pelo próprio "use strict") não vaza var, mas vê e altera locais.
@(test)
test_eval_strict_nao_vaza_var :: proc(t: ^testing.T) {
    src := `
        var r = [];
        (function(){ 'use strict'; var q = 1; eval('var dentro1 = q + 1; q = 5'); r.push(q + '/' + typeof dentro1); })();
        (function(){ eval('"use strict"; var dentro2 = 1'); r.push(typeof dentro2); })();
        (function(){ eval('var dentro3 = 1'); r.push(typeof dentro3); })(); // sloppy: vaza p/ a função
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "5/undefined,undefined,number", "eval strict: got %v", v)
}

// Módulo e corpo de classe são strict sem diretiva.
@(test)
test_classe_e_strict_sem_diretiva :: proc(t: ^testing.T) {
    src := STRICT_HARNESS + `
        class C { m() { Object.freeze({a: 1}).a = 2; } n() { naoDeclaradoE = 1; } }
        tipo(function(){ new C().m(); }) + ',' + tipo(function(){ new C().n(); })
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "TypeError,ReferenceError", "corpo de classe é strict: got %v", v)
}

// Método mutador de Array usa Set(..., true): LANÇA em qualquer modo, inclusive
// sloppy, quando o array é congelado/selado (antes o push crescia o length e o
// item sumia).
@(test)
test_mutador_de_array_congelado_lanca :: proc(t: ^testing.T) {
    src := `
        function tipo(f) { try { f(); return 'ok'; } catch (e) { return e.name; } }
        var fr = Object.freeze([1, 2]);
        var se = Object.seal([1, 2]);
        var r = [
            tipo(function(){ fr.push(3); }), tipo(function(){ fr.unshift(0); }),
            tipo(function(){ fr.fill(9); }), tipo(function(){ fr.reverse(); }),
            tipo(function(){ se.push(3); }), tipo(function(){ se.fill(9); }),
            fr.length + ':' + fr.join('') + ':' + se.join('')
        ];
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "TypeError,TypeError,TypeError,TypeError,TypeError,ok,2:12:99", "mutador em array congelado: got %v", v)
}
