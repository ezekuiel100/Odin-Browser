package js

// M166 — chave de propriedade por SÍMBOLO com identidade + getOwnPropertySymbols.
//
// A sonda acusava `Object.getOwnPropertySymbols` devolvendo sempre `[]`, mas ao
// atacar isso apareceu a causa, que é bem pior: a chave-string de um símbolo era
// `to_text(sym)` = "Symbol(desc)", ou seja, só a DESCRIÇÃO. Dois símbolos
// diferentes com a mesma descrição colidiam:
//
//     var s1 = Symbol("a"), s2 = Symbol("a");
//     o[s1] = 1; o[s2] = 2;   →  o[s1] valia 2
//
// Corrupção silenciosa de dados, e o motivo de o mapa reverso (chave → ^Symbol)
// não poder existir. Agora `symbol_key` gera uma chave única por símbolo (o
// endereço dá a identidade, o mesmo critério do `===`), cacheada no próprio
// Symbol porque `o[sym]` a recalcularia em todo acesso, e o vm mantém o inverso.

import "core:testing"

// ── identidade da chave ──────────────────────────────────────────────────────

@(test)
m166_simbolos_homonimos_nao_colidem :: proc(t: ^testing.T) {
    src := `
        var s1 = Symbol("a"), s2 = Symbol("a");
        var o = {};
        o[s1] = 1; o[s2] = 2;
        [o[s1], o[s2]].join(",")
    `
    testing.expect_value(t, run(src).(string), "1,2")
    // sem descrição nenhuma também são distintos
    testing.expect_value(t, run(`
        var a = Symbol(), b = Symbol();
        var o = {}; o[a] = "x"; o[b] = "y";
        o[a] + o[b]
    `).(string), "xy")
}

@(test)
m166_mesmo_simbolo_acha_a_mesma_prop :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var s = Symbol("k"); var o = {}; o[s] = 7; o[s]`)), f64(7))
    // sobrescrever pelo mesmo símbolo substitui (não cria uma segunda)
    testing.expect_value(t, as_number(run(`
        var s = Symbol("k"); var o = {};
        o[s] = 1; o[s] = 2;
        Object.getOwnPropertySymbols(o).length * 100 + o[s]
    `)), f64(102))
    // Symbol.for devolve o MESMO símbolo → mesma prop
    testing.expect_value(t, as_number(run(`
        var o = {};
        o[Symbol.for("reg")] = 5;
        o[Symbol.for("reg")]
    `)), f64(5))
}

// ── getOwnPropertySymbols ────────────────────────────────────────────────────

@(test)
m166_get_own_property_symbols :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var s = Symbol("a"); var o = {}; o[s] = 1;
        Object.getOwnPropertySymbols(o).length
    `)), f64(1))
    // devolve O PRÓPRIO símbolo, não uma cópia
    testing.expect_value(t, run(`
        var s = Symbol("a"); var o = {}; o[s] = 1;
        Object.getOwnPropertySymbols(o)[0] === s
    `).(bool), true)
    // dois homônimos aparecem os DOIS, na ordem de inserção
    testing.expect_value(t, run(`
        var s1 = Symbol("a"), s2 = Symbol("a");
        var o = {}; o[s1] = 1; o[s2] = 2;
        var got = Object.getOwnPropertySymbols(o);
        (got.length === 2) + "|" + (got[0] === s1) + "|" + (got[1] === s2)
    `).(string), "true|true|true")
    // objeto sem símbolos → array vazio (e não estoura)
    testing.expect_value(t, as_number(run(`Object.getOwnPropertySymbols({a:1}).length`)), f64(0))
    testing.expect_value(t, as_number(run(`Object.getOwnPropertySymbols({}).length`)), f64(0))
    testing.expect_value(t, run(`Array.isArray(Object.getOwnPropertySymbols({}))`).(bool), true)
    // não-objeto não estoura
    testing.expect_value(t, as_number(run(`Object.getOwnPropertySymbols(1).length`)), f64(0))
    // símbolo usado em getter também conta
    testing.expect_value(t, as_number(run(`
        var s = Symbol("g"); var o = {};
        Object.defineProperty(o, s, { get: function(){ return 1 } });
        Object.getOwnPropertySymbols(o).length
    `)), f64(1))
}

@(test)
m166_simbolos_seguem_fora_das_chaves_string :: proc(t: ^testing.T) {
    // O invariante que a chave-string tem de preservar: prop por símbolo NÃO
    // aparece em Object.keys / for-in / JSON (o prefixo "Symbol(" é o que
    // is_symbol_key testa, e a chave nova o mantém no início).
    src := `
        var s = Symbol("escondido");
        var o = { visivel: 1 };
        o[s] = 2;
        var doFor = []; for (var k in o) doFor.push(k);
        [ Object.keys(o).join(","),
          doFor.join(","),
          JSON.stringify(o),
          Object.getOwnPropertyNames(o).join(",")
        ].join("|")
    `
    testing.expect_value(t, run(src).(string), `visivel|visivel|{"visivel":1}|visivel`)
}

@(test)
m166_simbolos_bem_conhecidos_seguem_funcionando :: proc(t: ^testing.T) {
    // Symbol.iterator & cia. são resolvidos pela MESMA key_string; se a chave
    // mudasse de forma incompatível, for-of/spread parariam de achar o método.
    testing.expect_value(t, run(`
        var o = {}; o[Symbol.iterator] = function(){ var i=0; return { next: function(){ return i<2 ? {value:++i,done:false} : {done:true} } } };
        [...o].join(",")
    `).(string), "1,2")
    testing.expect_value(t, run(`
        var o = { [Symbol.toStringTag]: "Foo" };
        Object.prototype.toString.call(o)
    `).(string), "[object Foo]")
    testing.expect_value(t, run(`
        var C = { [Symbol.hasInstance]: function(){ return true } };
        ({}) instanceof C
    `).(bool), true)
    testing.expect_value(t, as_number(run(`
        var o = { [Symbol.toPrimitive]: function(){ return 42 } };
        o * 1
    `)), f64(42))
    testing.expect_value(t, run(`var s=0; for (var x of [1,2]) s+=x; s`).(f64), f64(3)) // for-of comum
}

@(test)
m166_symbol_como_valor_nao_mudou :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Symbol("a") === Symbol("a")`).(bool), false)
    testing.expect_value(t, run(`var s = Symbol("a"); s === s`).(bool), true)
    testing.expect_value(t, run(`Symbol.for("x") === Symbol.for("x")`).(bool), true)
    testing.expect_value(t, run(`typeof Symbol("a")`).(string), "symbol")
    testing.expect_value(t, run(`String(Symbol("a"))`).(string), "Symbol(a)") // exibição sem o sufixo interno
    testing.expect_value(t, run(`Object.prototype.toString.call(Symbol("a"))`).(string), "[object Symbol]")
}
