package js

// M164 — modelo REAL de atributos de propriedade (writable/enumerable/configurable).
//
// Antes o motor tinha só dois bits grosseiros: `hidden` (enumerable=false) e
// `frozen` (bloqueia TODA escrita). Consequências medidas nas sondas:
// `writable:false` era ignorado, `preventExtensions`/`seal` eram no-op,
// `propertyIsEnumerable` devolvia true p/ qualquer prop própria, `isSealed` era
// um apelido de `isFrozen` e `Object.freeze([1,2])` não protegia nada.
//
// Agora cada prop tem um `Prop_Attrs` (bit_set) em `Object.attrs`, e o objeto tem
// `non_extensible`. A AUSÊNCIA da chave no mapa é o default de uma atribuição
// normal (os três verdadeiros) — é isso que mantém o caminho quente sem custo e
// o mapa nil na esmagadora maioria dos objetos.
//
// O grosso dos testes abaixo é do que NÃO pode mudar: uma escrita comum, um
// `delete` comum, `Object.keys` de objeto comum. Um erro de polaridade aqui
// (zero-value trocado) quebraria o motor inteiro em silêncio.

import "core:testing"

// ── o caminho comum não mudou ────────────────────────────────────────────────

@(test)
m164_objeto_comum_intocado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o = {}; o.a = 1; o.a`)), f64(1))
    testing.expect_value(t, as_number(run(`var o = {a:1}; o.a = 2; o.a`)), f64(2))
    testing.expect_value(t, run(`var o = {a:1}; delete o.a; "a" in o`).(bool), false)
    testing.expect_value(t, run(`Object.keys({a:1,b:2}).join(",")`).(string), "a,b")
    testing.expect_value(t, run(`var o={a:1}; o.propertyIsEnumerable("a")`).(bool), true)
    testing.expect_value(t, run(`Object.isExtensible({})`).(bool), true)
    testing.expect_value(t, run(`Object.isFrozen({})`).(bool), false)
    testing.expect_value(t, run(`Object.isSealed({})`).(bool), false)
    testing.expect_value(t, run(`JSON.stringify({a:1,b:2})`).(string), `{"a":1,"b":2}`)
    // for-in de objeto comum enxerga tudo
    testing.expect_value(t, run(`var s=""; for (var k in {x:1,y:2}) s+=k; s`).(string), "xy")
    // e o array comum segue gravável
    testing.expect_value(t, as_number(run(`var a=[1]; a[0]=9; a.push(2); a[0]+a.length`)), f64(11))
}

@(test)
m164_prototypes_do_motor_seguem_nao_enumeraveis :: proc(t: ^testing.T) {
    // `constructor` e os métodos instalados pelo motor usavam o mapa `hidden`;
    // migraram para `attrs` e têm de continuar fora de Object.keys.
    testing.expect_value(t, run(`Object.keys(Object.getPrototypeOf(new Date())).indexOf("constructor") < 0`).(bool), true)
    testing.expect_value(t, as_number(run(`var s=0; for (var k in {a:1}) s++; s`)), f64(1))
}

@(test)
m164_membro_de_classe_e_nao_enumeravel :: proc(t: ^testing.T) {
    // spec §15.7.14 — no navegador `Object.keys(C.prototype)` vem vazio. Só virou
    // expressável com o mapa de atributos (antes dava ["m"]).
    testing.expect_value(t, as_number(run(`class C { m(){} n(){} } Object.keys(C.prototype).length`)), f64(0))
    testing.expect_value(t, as_number(run(`class C { get v(){return 1} } Object.keys(C.prototype).length`)), f64(0))
    // mas o método continua LÁ e chamável — não-enumerável não é invisível
    testing.expect_value(t, as_number(run(`class C { m(){ return 7 } } new C().m()`)), f64(7))
    testing.expect_value(t, run(`class C { m(){} } typeof C.prototype.m`).(string), "function")
    testing.expect_value(t, run(`class C { m(){} } Object.getOwnPropertyNames(C.prototype).indexOf("m") >= 0`).(bool), true)
    // herança segue funcionando
    testing.expect_value(t, as_number(run(`class A { m(){ return 1 } } class B extends A {} new B().m()`)), f64(1))
}

@(test)
m164_prototypes_NATIVOS_ainda_enumeram :: proc(t: ^testing.T) {
    // ⚠️ DEGRADAÇÃO QUE PERMANECE: os métodos dos prototypes NATIVOS (Date, Array,
    // ...) seguem enumeráveis — `Object.keys(Date.prototype)` devolve 43 aqui e 0
    // no navegador. Não é regressão do M164 (medido igual no binário anterior);
    // marcá-los exigiria varrer a instalação de cada builtin. O impacto prático é
    // pequeno porque o nosso `for-in` NÃO sobe a cadeia de protótipos — este teste
    // fixa as duas coisas para que a diferença não seja descoberta por acidente.
    testing.expectf(t, as_number(run(`Object.keys(Object.getPrototypeOf(new Date())).length`)) > 0,
        "Date.prototype ainda enumera (degradação anotada)")
    testing.expect_value(t, run(`
        var o = new Date(); var s = [];
        for (var k in o) s.push(k);
        s.length
    `).(f64), f64(0)) // for-in de instância não vê o prototype
}

// ── writable ─────────────────────────────────────────────────────────────────

@(test)
m164_writable_false_bloqueia_escrita :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, writable: false });
        o.k = 5;
        o.k;
    `)), f64(1))
    // writable:true segue gravável
    testing.expect_value(t, as_number(run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, writable: true });
        o.k = 5;
        o.k;
    `)), f64(5))
    // omitido em prop NOVA = false (semântica de defineProperty, não de atribuição)
    testing.expect_value(t, as_number(run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1 });
        o.k = 5;
        o.k;
    `)), f64(1))
    // ++ e += também são bloqueados
    testing.expect_value(t, as_number(run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1 });
        o.k++; o.k += 10;
        o.k;
    `)), f64(1))
}

// ── enumerable ───────────────────────────────────────────────────────────────

@(test)
m164_enumerable_false :: proc(t: ^testing.T) {
    src := `
        var o = { vis: 1 };
        Object.defineProperty(o, "oculta", { value: 2, enumerable: false });
        [ Object.keys(o).join(","),
          o.propertyIsEnumerable("oculta"),
          o.propertyIsEnumerable("vis"),
          o.oculta,
          JSON.stringify(o),
          Object.getOwnPropertyNames(o).indexOf("oculta") >= 0
        ].join("|")
    `
    testing.expect_value(t, run(src).(string), "vis|false|true|2|{\"vis\":1}|true")
    // enumerable:true entra em keys
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, enumerable: true });
        Object.keys(o).join(",")
    `).(string), "k")
}

// ── configurable ─────────────────────────────────────────────────────────────

@(test)
m164_configurable_false_bloqueia_delete :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, configurable: false });
        delete o.k;
        "k" in o
    `).(bool), true)
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, configurable: true });
        delete o.k;
        "k" in o
    `).(bool), false)
    // delete por índice/chave computada segue a mesma regra
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "k", { value: 1, configurable: false });
        delete o["k"];
        "k" in o
    `).(bool), true)
}

// ── extensibilidade: preventExtensions / seal / freeze ───────────────────────

@(test)
m164_prevent_extensions :: proc(t: ^testing.T) {
    src := `
        var o = { a: 1 };
        Object.preventExtensions(o);
        o.b = 2;          // barrada: prop NOVA
        o.a = 9;          // permitida: prop existente segue gravável
        var deletou = (delete o.a, !("a" in o));  // permitida: segue configurável
        [ o.b === undefined, o.a === undefined || deletou, Object.isExtensible(o) ].join("|")
    `
    testing.expect_value(t, run(src).(string), "true|true|false")
}

@(test)
m164_seal_difere_de_freeze :: proc(t: ^testing.T) {
    // seal: não cresce, não deleta, mas AINDA GRAVA — é exatamente o que o
    // modelo antigo não conseguia expressar (seal era no-op).
    src := `
        var o = { a: 1 };
        Object.seal(o);
        o.a = 9;      // permitida
        o.b = 2;      // barrada (nova)
        delete o.a;   // barrada (não-configurável)
        [ o.a, o.b === undefined, Object.isSealed(o), Object.isFrozen(o), Object.isExtensible(o) ].join("|")
    `
    testing.expect_value(t, run(src).(string), "9|true|true|false|false")
}

@(test)
m164_freeze_bloqueia_tudo :: proc(t: ^testing.T) {
    src := `
        var o = { a: 1 };
        Object.freeze(o);
        o.a = 9;      // barrada
        o.b = 2;      // barrada
        delete o.a;   // barrada
        [ o.a, o.b === undefined, Object.isFrozen(o), Object.isSealed(o), Object.isExtensible(o) ].join("|")
    `
    testing.expect_value(t, run(src).(string), "1|true|true|true|false")
}

@(test)
m164_freeze_e_seal_de_array :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var a = Object.freeze([1,2]); a[0] = 9; a[0]`)), f64(1))
    testing.expect_value(t, as_number(run(`var a = Object.freeze([1,2]); a[5] = 9; a.length`)), f64(2))
    testing.expect_value(t, run(`Object.isFrozen(Object.freeze([1]))`).(bool), true)
    // seal de array: item existente muda, mas não cresce
    testing.expect_value(t, as_number(run(`var a = Object.seal([1,2]); a[0] = 9; a[0]`)), f64(9))
    testing.expect_value(t, as_number(run(`var a = Object.seal([1,2]); a[5] = 9; a.length`)), f64(2))
    testing.expect_value(t, run(`Object.isExtensible([1])`).(bool), true)
    testing.expect_value(t, run(`Object.isExtensible(Object.freeze([1]))`).(bool), false)
}

// ── descritores: ida e volta ─────────────────────────────────────────────────

@(test)
m164_descritor_reflete_os_atributos :: proc(t: ^testing.T) {
    src := `
        var o = {};
        Object.defineProperty(o, "k", { value: 1, writable: false, enumerable: true, configurable: false });
        var d = Object.getOwnPropertyDescriptor(o, "k");
        [d.value, d.writable, d.enumerable, d.configurable].join("|")
    `
    testing.expect_value(t, run(src).(string), "1|false|true|false")
    // prop criada por ATRIBUIÇÃO tem os três verdadeiros
    src2 := `
        var o = { k: 1 };
        var d = Object.getOwnPropertyDescriptor(o, "k");
        [d.value, d.writable, d.enumerable, d.configurable].join("|")
    `
    testing.expect_value(t, run(src2).(string), "1|true|true|true")
    // depois de freeze, o descritor acompanha
    src3 := `
        var o = { k: 1 };
        Object.freeze(o);
        var d = Object.getOwnPropertyDescriptor(o, "k");
        [d.writable, d.configurable].join("|")
    `
    testing.expect_value(t, run(src3).(string), "false|false")
}

@(test)
m164_redefinicao_preserva_atributo_omitido :: proc(t: ^testing.T) {
    // Redefinir mexendo só no `value` mantém os atributos que já valiam (spec).
    src := `
        var o = {};
        Object.defineProperty(o, "k", { value: 1, enumerable: true, configurable: true });
        Object.defineProperty(o, "k", { value: 2 });
        var d = Object.getOwnPropertyDescriptor(o, "k");
        [d.value, d.enumerable, d.configurable].join("|")
    `
    testing.expect_value(t, run(src).(string), "2|true|true")
}

@(test)
m164_define_property_via_getter_ainda_funciona :: proc(t: ^testing.T) {
    // accessors continuam sendo o caminho de get/set (não viraram data props)
    testing.expect_value(t, as_number(run(`
        var o = {};
        Object.defineProperty(o, "k", { get: function(){ return 7 } });
        o.k;
    `)), f64(7))
    testing.expect_value(t, as_number(run(`
        var n = 0;
        var o = {};
        Object.defineProperty(o, "k", { set: function(v){ n = v } });
        o.k = 5;
        n;
    `)), f64(5))
    // e o descritor de accessor traz enumerable/configurable do mapa
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "k", { get: function(){ return 1 }, enumerable: true });
        var d = Object.getOwnPropertyDescriptor(o, "k");
        (typeof d.get === "function") + "|" + d.enumerable
    `).(string), "true|true")
}

@(test)
m164_object_assign_e_spread_so_copiam_enumeraveis :: proc(t: ^testing.T) {
    src := `
        var src = { vis: 1 };
        Object.defineProperty(src, "oculta", { value: 2, enumerable: false });
        var viaAssign = Object.assign({}, src);
        var viaSpread = { ...src };
        [ Object.keys(viaAssign).join(","), Object.keys(viaSpread).join(",") ].join("|")
    `
    testing.expect_value(t, run(src).(string), "vis|vis")
}
