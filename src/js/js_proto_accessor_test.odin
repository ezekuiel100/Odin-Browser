package js

import "core:testing"

// `__proto__` — acessor de Object.prototype (spec B.2.2.1) + a forma de literal
// `{__proto__: v}` (B.3.1).
//
// Era o último gap geral de protótipo anotado na memória. Não causava o bug do
// clipboard.js (lá o `_getPrototypeOf` do Babel é `o.__proto__ ||
// Object.getPrototypeOf(o)` e o `||` cura sozinho), mas todo código que depende
// dele SEM fallback quebrava.
//
// ⚠️ Quatro dos casos abaixo já passavam ANTES do conserto, por vacuidade — não
// existia nada, então "não é prop própria" e "create(null) dá undefined" eram
// verdade à toa. São eles que garantem que o conserto não trocou um erro por
// outro: um `__proto__` implementado como caso especial no get_member daria
// `null` (não `undefined`) para `Object.create(null)` e criaria prop própria.

@(test)
proto_get_nas_tres_variantes :: proc(t: ^testing.T) {
    // ⚠️ objeto, array e função são variantes DIFERENTES da union e resolvem
    // membro por caminhos diferentes — array e função nem percorrem os getters
    // de Object.prototype. Os três precisam ser afirmados.
    r := run(`
        ({}).__proto__ === Object.prototype &&
        [].__proto__ === Array.prototype &&
        (function(){}).__proto__ === Function.prototype
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "__proto__ lê o protótipo de objeto, array e função")
}

@(test)
proto_get_segue_o_create :: proc(t: ^testing.T) {
    r := run(`
        var p = { m: function () { return 1; } };
        Object.create(p).__proto__ === p
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "__proto__ acompanha o protótipo dado ao Object.create")
}

@(test)
proto_set_religa_a_cadeia :: proc(t: ^testing.T) {
    // Não basta gravar: a HERANÇA tem de passar a valer (`o.m()` resolve).
    r := run(`
        var p = { m: function () { return 1; } }, o = {};
        o.__proto__ = p;
        o.m() === 1 && Object.getPrototypeOf(o) === p
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "escrever __proto__ religa a cadeia de verdade")
}

@(test)
proto_set_null_e_nao_objeto :: proc(t: ^testing.T) {
    // `= null` desliga; `= 5` é NO-OP (a spec não lança nesse caso).
    r := run(`
        var a = {}; a.__proto__ = null;
        var b = {}; b.__proto__ = 5;
        Object.getPrototypeOf(a) === null && Object.getPrototypeOf(b) === Object.prototype
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "null desliga a cadeia; valor não-objeto é no-op silencioso")
}

@(test)
proto_em_literal_define_prototipo :: proc(t: ^testing.T) {
    // B.3.1: em literal, `__proto__: v` DEFINE o [[Prototype]]. `{__proto__:null}`
    // é o idioma de dicionário sem herança e depende disto.
    r := run(`
        var p = { m: function () { return 2; } };
        var o = { __proto__: p, x: 1 };
        o.m() === 2 && o.x === 1 && Object.getPrototypeOf({ __proto__: null }) === null
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "{__proto__: v} define o protótipo em vez de criar prop própria")
}

@(test)
proto_computado_em_literal_e_prop_normal :: proc(t: ^testing.T) {
    // ⚠️ O PAR do caso acima, e a spec distingue os dois DE PROPÓSITO: a chave
    // COMPUTADA cria prop própria e NÃO mexe no protótipo. Sem este caso, um
    // conserto guloso demais passaria despercebido.
    r := run(`
        var p = { m: function () { return 2; } };
        var o = { ["__proto__"]: p };
        Object.getPrototypeOf(o) === Object.prototype && o.hasOwnProperty("__proto__") === true
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "{['__proto__']: v} é prop própria e NÃO mexe no protótipo")
}

@(test)
proto_nao_e_propria_nem_enumeravel :: proc(t: ^testing.T) {
    // CONTROLE (já passava por vacuidade): o acessor mora em Object.prototype,
    // então não pode virar prop própria nem aparecer em Object.keys.
    r := run(`
        var o = { a: 1 };
        o.hasOwnProperty("__proto__") === false &&
        Object.keys(o).join() === "a" &&
        Object.keys(Object.prototype).indexOf("__proto__") === -1
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "__proto__ não é prop própria nem enumerável")
}

@(test)
proto_de_create_null_e_undefined :: proc(t: ^testing.T) {
    // ⚠️ CONTROLE que distingue "acessor herdado" de "caso especial no motor":
    // um objeto sem Object.prototype na cadeia NÃO tem o acessor, então o valor
    // é `undefined` — não `null`. Um caso especial global daria `null` e passaria
    // despercebido em todo o resto.
    r := run(`
        var o = Object.create(null);
        o.__proto__ === undefined && Object.getPrototypeOf(o) === null
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "Object.create(null).__proto__ é undefined (não null)")
}

@(test)
get_prototype_of_de_array :: proc(t: ^testing.T) {
    // Fechou junto, e pela MESMA fonte que o `[].__proto__` — se divergirem, um
    // dos dois está mentindo.
    r := run(`
        Object.getPrototypeOf([]) === Array.prototype &&
        Object.getPrototypeOf([]) === [].__proto__
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "Object.getPrototypeOf([]) é Array.prototype e concorda com __proto__")
}

@(test)
proto_herda_por_prototype_de_funcao :: proc(t: ^testing.T) {
    // O idioma ES5 clássico de herança, que era o que mais sofria.
    r := run(`
        function A() {} A.prototype.z = 9;
        function B() {} B.prototype.__proto__ = A.prototype;
        (new B()).z === 9
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "B.prototype.__proto__ = A.prototype faz a instância herdar")
}
