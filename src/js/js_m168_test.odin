package js

// M168 — todo objeto nasce ligado em Object.prototype.
//
// `new_object` deixava `proto` nil, então o objeto literal não tinha
// [[Prototype]]. Os métodos funcionavam mesmo assim (get_member cai no fallback
// `vm.object_methods` quando a cadeia acaba), e foi isso que escondeu o buraco
// por muitos marcos — mas a INTROSPECÇÃO da cadeia mentia:
//
//     Object.getPrototypeOf({})   →  null   (deve ser Object.prototype)
//     ({}) instanceof Object      →  false  (deve ser true)
//
// Quem paga é o `isPlainObject`, o teste mais comum de "isto é um objeto
// simples?" em lib de verdade. O do Redux sobe a cadeia até null e compara com o
// topo; com proto nil o laço não roda e a comparação vira `null === obj` →
// false. Resultado: o Redux recusava TODA action com "Actions must be plain
// objects. Use custom middleware for async actions." — era o erro do
// `ext.popups.main` na Wikipedia.
//
// O que NÃO pode mudar (o risco real da mudança, e por isso metade dos testes
// daqui é sobre o que continua igual):
//   - for-in / Object.keys / JSON.stringify seguem só nas PRÓPRIAS. Já eram
//     own-only neste motor (own_enum_keys não sobe cadeia); os membros de
//     Object.prototype ainda ganharam a marca de não-enumerável por garantia.
//   - `Object.create(null)` segue SEM cadeia: new_object liga, obj_create
//     desliga. É o idioma de dicionário puro.
//   - custom element cujo `.prototype` não estende HTMLElement continua ganhando
//     a cadeia do DOM (o guarda em upgrade_element era `proto.proto == nil` e
//     passou a aceitar Object.prototype também).

import "core:testing"

// ── A cadeia agora existe ────────────────────────────────────────────────────

@(test)
m168_objeto_literal_tem_object_prototype :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.getPrototypeOf({}) === Object.prototype`).(bool), true)
    testing.expect_value(t, run(`Object.getPrototypeOf({a:1}) === Object.prototype`).(bool), true)
    testing.expect_value(t, run(`({}) instanceof Object`).(bool), true)
    testing.expect_value(t, run(`({a:1}) instanceof Object`).(bool), true)
    // objeto vindo do JSON e de construtor também
    testing.expect_value(t, run(`JSON.parse('{"a":1}') instanceof Object`).(bool), true)
    testing.expect_value(t, run(`(new Object()) instanceof Object`).(bool), true)
    // e a cadeia TERMINA: Object.prototype não pode apontar p/ si mesmo (laço
    // infinito no get_member) nem p/ outro objeto
    testing.expect_value(t, run(`Object.getPrototypeOf(Object.prototype) === null`).(bool), true)
}

@(test)
m168_instancia_de_classe_chega_em_object_prototype :: proc(t: ^testing.T) {
    src := `
        class A { constructor(){ this.x = 1 } }
        var a = new A();
        (a instanceof A) + "|" + (a instanceof Object) + "|" +
        (Object.getPrototypeOf(Object.getPrototypeOf(a)) === Object.prototype)
    `
    testing.expect_value(t, run(src).(string), "true|true|true")
}

// O caso que motivou o marco: o isPlainObject do Redux, transcrito.
@(test)
m168_is_plain_object_do_redux :: proc(t: ^testing.T) {
    src := `
        function isPlainObject(obj) {
            if (typeof obj !== 'object' || obj === null) return false
            var proto = obj
            while (Object.getPrototypeOf(proto) !== null) proto = Object.getPrototypeOf(proto)
            return Object.getPrototypeOf(obj) === proto
        }
        isPlainObject({type:'X'}) + "|" + isPlainObject(null) + "|" +
        isPlainObject(function(){}) + "|" + isPlainObject(new (class C {})())
    `
    // literal: sim. null/função: não. instância de classe: NÃO (a cadeia dela tem
    // C.prototype no meio) — é exatamente o que o Redux quer distinguir.
    testing.expect_value(t, run(src).(string), "true|false|false|false")
}

// A variante do jQuery/lodash: pega o constructor VIA A CADEIA.
@(test)
m168_is_plain_object_por_constructor :: proc(t: ^testing.T) {
    src := `
        var proto = Object.getPrototypeOf({});
        var temCtor = Object.prototype.hasOwnProperty.call(proto, 'constructor');
        temCtor + "|" + (proto.constructor === Object)
    `
    testing.expect_value(t, run(src).(string), "true|true")
}

// ── O que NÃO pode ter mudado ────────────────────────────────────────────────

// A enumeração é o risco nº1: se subisse a cadeia, TODO for-in/Object.keys/JSON
// passaria a ver constructor e toString. Este teste falharia alto.
@(test)
m168_enumeracao_segue_so_nas_proprias :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`(function(){ var n = 0; for (var k in {}) n++; return n })()`)), f64(0))
    testing.expect_value(t, run(`(function(){ var s = ""; for (var k in {a:1,b:2}) s += k; return s })()`).(string), "ab")
    testing.expect_value(t, as_number(run(`Object.keys({}).length`)), f64(0))
    testing.expect_value(t, run(`Object.keys({a:1,b:2}).join(",")`).(string), "a,b")
    testing.expect_value(t, run(`JSON.stringify({a:1})`).(string), `{"a":1}`)
    testing.expect_value(t, as_number(run(`Object.entries({a:1}).length`)), f64(1))
    testing.expect_value(t, run(`JSON.stringify(Object.assign({}, {a:1}))`).(string), `{"a":1}`)
    // e o próprio Object.prototype não expõe membro enumerável
    testing.expect_value(t, as_number(run(`Object.keys(Object.prototype).length`)), f64(0))
}

// hasOwnProperty é OWN: o que vem da cadeia não conta (mas `in` conta).
@(test)
m168_own_versus_herdado :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`({}).hasOwnProperty('toString')`).(bool), false)
    testing.expect_value(t, run(`({a:1}).hasOwnProperty('a')`).(bool), true)
    testing.expect_value(t, run(`'toString' in {}`).(bool), true)
    testing.expect_value(t, run(`'naoExiste' in {}`).(bool), false)
}

@(test)
m168_object_create_null_segue_sem_cadeia :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.getPrototypeOf(Object.create(null)) === null`).(bool), true)
    testing.expect_value(t, run(`Object.create(null) instanceof Object`).(bool), false)
    testing.expect_value(t, run(`(function(){ var d = Object.create(null); d.k = 1; return Object.keys(d).join() })()`).(string), "k")
    // ⚠️ DEGRADAÇÃO ANOTADA (pré-existente, não introduzida aqui): get_member cai em
    // `vm.object_methods` quando a cadeia acaba, então um objeto de cadeia NULA ainda
    // alcança toString/hasOwnProperty. Na spec ele não alcançaria. O que realmente
    // importa no idioma de dicionário puro — for-in/Object.keys limpos e
    // getPrototypeOf null — está certo, e é o que os asserts acima fixam.
    testing.expect_value(t, run(`typeof Object.create(null).toString`).(string), "function")
    // create(proto) continua encadeando, e o topo agora é Object.prototype
    testing.expect_value(t, as_number(run(`(function(){ var b = {t:7}; return Object.create(b).t })()`)), f64(7))
    testing.expect_value(t, run(`(function(){ var b = {t:7}; return Object.create(b) instanceof Object })()`).(bool), true)
}

// Os métodos que já funcionavam pelo fallback vm.object_methods continuam iguais
// (agora podem resolver pela cadeia — tem de ser a MESMA função).
@(test)
m168_metodos_de_object_prototype_intactos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`String({})`).(string), "[object Object]")
    testing.expect_value(t, run(`Object.prototype.toString.call({})`).(string), "[object Object]")
    testing.expect_value(t, run(`Object.prototype.toString.call([])`).(string), "[object Array]")
    testing.expect_value(t, run(`({}).toString === Object.prototype.toString`).(bool), true)
    testing.expect_value(t, run(`({}).constructor === Object`).(bool), true)
    testing.expect_value(t, run(`({}).propertyIsEnumerable('x')`).(bool), false)
    testing.expect_value(t, run(`(function(){ var b = {}; return Object.prototype.isPrototypeOf.call(Object.prototype, b) })()`).(bool), true)
}

// Uma prop própria tem de continuar SOMBREANDO a herdada — o nível mais próximo
// vence. Se a ordem do get_member tivesse invertido, isto pegaria.
@(test)
m168_prop_propria_sombreia_a_herdada :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`(function(){ var o = { toString: function(){ return "meu" } }; return String(o) })()`).(string), "meu")
    testing.expect_value(t, as_number(run(`(function(){ var o = { constructor: 42 }; return o.constructor })()`)), f64(42))
    testing.expect_value(t, as_number(run(`(function(){ var o = {}; o.x = 1; return o.x })()`)), f64(1))
}

// Nem tudo é Object: os outros tipos não podem ter regredido.
@(test)
m168_outros_tipos_inalterados :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[] instanceof Array`).(bool), true)
    testing.expect_value(t, run(`({}) instanceof Array`).(bool), false)
    testing.expect_value(t, run(`(function(){}) instanceof Function`).(bool), true)
    testing.expect_value(t, run(`new Map() instanceof Map`).(bool), true)
    testing.expect_value(t, run(`(new Date()) instanceof Date`).(bool), true)
    testing.expect_value(t, run(`/a/ instanceof RegExp`).(bool), true)
    testing.expect_value(t, run(`(new Error("x")) instanceof Error`).(bool), true)
}
