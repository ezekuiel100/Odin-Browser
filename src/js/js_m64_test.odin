package js

// M64 (grupo 6 das sondas): stdlib restante — String.matchAll/codePointAt/
// fromCodePoint/localeCompare/normalize, Object.fromEntries/setPrototypeOf/is,
// Function.prototype.toString, JSON.stringify com indentação e JSON.parse com
// reviver. Rodar: odin test src/js

import "core:testing"

// ── String ────────────────────────────────────────────────────────────────────

@(test)
test_match_all :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var out = [];
        for (var m of 'a1b22c'.matchAll(/\d+/g)) out.push(m[0] + '@' + m.index);
        out.join(',')
    `).(string), "1@1,22@3")
}

@(test)
test_match_all_groups :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var out = [];
        for (var m of 'x=1 y=2'.matchAll(/(\w)=(\d)/g)) out.push(m[1] + m[2]);
        out.join('')
    `).(string), "x1y2")
}

@(test)
test_match_all_requires_g :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { 'ab'.matchAll(/a/); } catch(e){ r = e.name; }
        r
    `).(string), "TypeError")
}

@(test)
test_code_point_at_from_code_point :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        'ção'.codePointAt(0) + ':' + String.fromCodePoint(97, 98)
    `).(string), "231:ab")
}

@(test)
test_locale_compare_normalize :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        ('a'.localeCompare('b') < 0) && ('b'.localeCompare('a') > 0) &&
        ('a'.localeCompare('a') === 0) && ('café'.normalize() === 'café')
    `).(bool), true)
}

// ── Object ────────────────────────────────────────────────────────────────────

@(test)
test_object_from_entries :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = Object.fromEntries([['a', 1], ['b', 2]]);
        var m = Object.fromEntries(new Map([['k', 'v']]));
        o.a + o.b + ':' + m.k
    `).(string), "3:v")
}

@(test)
test_object_from_entries_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = { x: 1, y: 2 };
        var o2 = Object.fromEntries(Object.entries(o));
        JSON.stringify(o2)
    `).(string), `{"x":1,"y":2}`)
}

@(test)
test_set_prototype_of :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var base = { saudacao: function(){ return 'oi ' + this.nome; } };
        var o = { nome: 'Ana' };
        Object.setPrototypeOf(o, base);
        var antes = o.saudacao();
        Object.setPrototypeOf(o, null);
        antes + ':' + typeof o.saudacao
    `).(string), "oi Ana:undefined")
}

@(test)
test_set_prototype_of_es5_inheritance :: proc(t: ^testing.T) {
    // o padrão _inherits do Babel/TS
    testing.expect_value(t, run(`
        function Animal(nome){ this.nome = nome; }
        Animal.prototype.fala = function(){ return this.nome + ' faz som'; };
        function Cao(nome){ Animal.call(this, nome); }
        Cao.prototype = Object.create(Animal.prototype);
        Object.setPrototypeOf(Cao, Animal); // herda estáticos
        new Cao('Rex').fala()
    `).(string), "Rex faz som")
}

@(test)
test_object_is :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Object.is(NaN, NaN) && Object.is(1, 1) && Object.is('a', 'a') &&
        !Object.is(1, 2) && !Object.is({}, {}) &&
        (function(){ var o = {}; return Object.is(o, o); })()
    `).(bool), true)
}

// ── Function.prototype.toString ───────────────────────────────────────────────

@(test)
test_function_to_string :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function minhaFn(){}
        var s = minhaFn.toString();
        (typeof s === 'string') && s.indexOf('minhaFn') >= 0 && s.indexOf('native code') >= 0
    `).(bool), true)
}

// ── JSON indent + reviver ─────────────────────────────────────────────────────

@(test)
test_json_stringify_indent :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`JSON.stringify({a:1,b:[2,3]}, null, 2)`).(string),
        "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}")
}

@(test)
test_json_stringify_indent_string :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`JSON.stringify({a:1}, null, '\t')`).(string), "{\n\t\"a\": 1\n}")
}

@(test)
test_json_stringify_no_indent_unchanged :: proc(t: ^testing.T) {
    // regressão: sem space, formato compacto de sempre
    testing.expect_value(t, run(`JSON.stringify({a:1,b:[2]})`).(string), `{"a":1,"b":[2]}`)
}

@(test)
test_json_parse_reviver :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = JSON.parse('{"a":1,"b":{"c":2}}', function(k, v){
            return typeof v === 'number' ? v * 10 : v;
        });
        o.a + ':' + o.b.c
    `).(string), "10:20")
}

@(test)
test_json_parse_reviver_removes :: proc(t: ^testing.T) {
    // reviver devolvendo undefined REMOVE a chave
    testing.expect_value(t, run(`
        var o = JSON.parse('{"manter":1,"tirar":2}', function(k, v){
            if (k === 'tirar') return undefined;
            return v;
        });
        JSON.stringify(o)
    `).(string), `{"manter":1}`)
}

@(test)
test_json_parse_reviver_array_keys :: proc(t: ^testing.T) {
    // em arrays a chave é o índice como string
    testing.expect_value(t, run(`
        var ks = [];
        JSON.parse('[5,6]', function(k, v){ if (k !== '') ks.push(k); return v; });
        ks.join(',')
    `).(string), "0,1")
}
