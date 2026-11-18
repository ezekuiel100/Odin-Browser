package js

import "core:strings"

// ── metadata das funções nativas dos builtins do ECMAScript ─────────────────
// Boa parte das nativas nasce por `mk_native` (sem nome, length 0) e mora em
// `props` com os atributos default (enumerável, gravável, configurável). Na spec
// toda propriedade de um objeto builtin é NÃO-enumerável, as constantes (Math.PI,
// Number.EPSILON, os símbolos bem-conhecidos, `prototype` dos construtores) são
// imutáveis, todo método tem `name`/`length` próprios e nenhum método é
// construtor. Em vez de corrigir centenas de sítios de instalação, esta passada
// roda UMA vez no fim do vm_init e corrige tudo o que é alcançável a partir dos
// globais do ECMAScript listados abaixo.
//
// Só os globais da LINGUAGEM: interfaces do DOM/WebIDL têm regras próprias
// (operações e atributos de prototype de interface são ENUMERÁVEIS lá).

@(private = "file")
ES_GLOBALS := [?]string{
    "Object", "Function", "Array", "String", "Number", "Boolean", "Symbol",
    "Math", "JSON", "Reflect", "Promise", "Map", "Set", "WeakMap", "WeakSet",
    "WeakRef", "FinalizationRegistry", "Date", "RegExp", "Proxy", "BigInt",
    "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
    "EvalError", "URIError", "AggregateError",
    "ArrayBuffer", "DataView",
    "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
    "Int32Array", "Uint32Array", "Float32Array", "Float64Array",
    "BigInt64Array", "BigUint64Array",
    "parseInt", "parseFloat", "isNaN", "isFinite",
    "encodeURIComponent", "decodeURIComponent", "encodeURI", "decodeURI",
    "escape", "unescape",
}

@(private = "file")
Len_Entry :: struct { key: string, n: int }

// `length` da spec por "Dono.chave" (dono = global; prototype vira "Dono.prototype").
// Grupos que compartilham métodos usam um dono genérico: "TypedArray" (as 11
// construtoras tipadas), "Coll" (Map/Set/WeakMap/WeakSet) e "NativeError".
// Só entram aqui os que diferem do que a instalação já dá ou que nascem sem length.
@(private = "file")
SPEC_LENGTHS := [?]Len_Entry{
    // construtoras
    {"Object", 1}, {"Function", 1}, {"Array", 1}, {"String", 1}, {"Number", 1},
    {"Boolean", 1}, {"Symbol", 0}, {"Promise", 1}, {"Map", 0}, {"Set", 0},
    {"WeakMap", 0}, {"WeakSet", 0}, {"WeakRef", 1}, {"FinalizationRegistry", 1},
    {"Date", 7}, {"RegExp", 2}, {"Proxy", 2}, {"BigInt", 1}, {"Error", 1},
    {"NativeError", 1}, {"AggregateError", 2}, {"ArrayBuffer", 1}, {"DataView", 1},
    {"TypedArray", 3},
    {"parseInt", 2}, {"parseFloat", 1}, {"isNaN", 1}, {"isFinite", 1},
    {"encodeURIComponent", 1}, {"decodeURIComponent", 1}, {"encodeURI", 1},
    {"decodeURI", 1}, {"escape", 1}, {"unescape", 1},

    {"Function.prototype.bind", 1}, {"Function.prototype.apply", 2},
    {"Function.prototype.call", 1},

    {"String.raw", 1}, {"String.fromCharCode", 1}, {"String.fromCodePoint", 1},
    {"String.prototype.replace", 2}, {"String.prototype.replaceAll", 2},
    {"String.prototype.matchAll", 1}, {"String.prototype.match", 1},
    {"String.prototype.search", 1}, {"String.prototype.split", 2},
    {"String.prototype.padEnd", 1}, {"String.prototype.padStart", 1},
    {"String.prototype.repeat", 1}, {"String.prototype.charAt", 1},
    {"String.prototype.charCodeAt", 1}, {"String.prototype.codePointAt", 1},
    {"String.prototype.substr", 2}, {"String.prototype.substring", 2},
    {"String.prototype.localeCompare", 1}, {"String.prototype.startsWith", 1},
    {"String.prototype.endsWith", 1}, {"String.prototype.includes", 1},
    {"String.prototype.indexOf", 1}, {"String.prototype.lastIndexOf", 1},

    {"Number.parseInt", 2}, {"Number.parseFloat", 1}, {"Number.isInteger", 1},
    {"Number.isNaN", 1}, {"Number.isFinite", 1}, {"Number.isSafeInteger", 1},
    {"Number.prototype.toPrecision", 1}, {"Number.prototype.toFixed", 1},
    {"Number.prototype.toExponential", 1}, {"Number.prototype.toString", 1},

    {"Symbol.for", 1}, {"Symbol.keyFor", 1},

    {"Math.abs", 1}, {"Math.acos", 1}, {"Math.acosh", 1}, {"Math.asin", 1},
    {"Math.asinh", 1}, {"Math.atan", 1}, {"Math.atanh", 1}, {"Math.atan2", 2},
    {"Math.cbrt", 1}, {"Math.ceil", 1}, {"Math.clz32", 1}, {"Math.cos", 1},
    {"Math.cosh", 1}, {"Math.exp", 1}, {"Math.expm1", 1}, {"Math.floor", 1},
    {"Math.fround", 1}, {"Math.hypot", 2}, {"Math.imul", 2}, {"Math.log", 1},
    {"Math.log1p", 1}, {"Math.log10", 1}, {"Math.log2", 1}, {"Math.max", 2},
    {"Math.min", 2}, {"Math.pow", 2}, {"Math.round", 1}, {"Math.sign", 1},
    {"Math.sin", 1}, {"Math.sinh", 1}, {"Math.sqrt", 1}, {"Math.tan", 1},
    {"Math.tanh", 1}, {"Math.trunc", 1},

    {"JSON.parse", 2}, {"JSON.stringify", 3},

    {"Reflect.apply", 3}, {"Reflect.construct", 2}, {"Reflect.defineProperty", 3},
    {"Reflect.deleteProperty", 2}, {"Reflect.get", 2},
    {"Reflect.getOwnPropertyDescriptor", 2}, {"Reflect.getPrototypeOf", 1},
    {"Reflect.has", 2}, {"Reflect.isExtensible", 1}, {"Reflect.ownKeys", 1},
    {"Reflect.preventExtensions", 1}, {"Reflect.set", 3}, {"Reflect.setPrototypeOf", 2},

    {"Promise.all", 1}, {"Promise.allSettled", 1}, {"Promise.any", 1},
    {"Promise.race", 1}, {"Promise.reject", 1}, {"Promise.resolve", 1},
    {"Promise.prototype.then", 2}, {"Promise.prototype.catch", 1},
    {"Promise.prototype.finally", 1},

    {"Coll.prototype.has", 1}, {"Coll.prototype.delete", 1}, {"Coll.prototype.get", 1},
    {"Coll.prototype.set", 2}, {"Coll.prototype.add", 1}, {"Coll.prototype.forEach", 1},

    {"Date.parse", 1}, {"Date.UTC", 7},
    {"Date.prototype.setDate", 1}, {"Date.prototype.setUTCDate", 1},
    {"Date.prototype.setFullYear", 3}, {"Date.prototype.setUTCFullYear", 3},
    {"Date.prototype.setHours", 4}, {"Date.prototype.setUTCHours", 4},
    {"Date.prototype.setMinutes", 3}, {"Date.prototype.setUTCMinutes", 3},
    {"Date.prototype.setSeconds", 2}, {"Date.prototype.setUTCSeconds", 2},
    {"Date.prototype.setMilliseconds", 1}, {"Date.prototype.setUTCMilliseconds", 1},
    {"Date.prototype.setMonth", 2}, {"Date.prototype.setUTCMonth", 2},
    {"Date.prototype.setTime", 1}, {"Date.prototype.setYear", 1},
    {"Date.prototype.toJSON", 1},

    {"RegExp.prototype.exec", 1}, {"RegExp.prototype.test", 1},

    {"BigInt.asIntN", 2}, {"BigInt.asUintN", 2},

    {"ArrayBuffer.isView", 1}, {"ArrayBuffer.prototype.slice", 2},

    {"TypedArray.from", 1},
    {"TypedArray.prototype.at", 1}, {"TypedArray.prototype.copyWithin", 2},
    {"TypedArray.prototype.every", 1}, {"TypedArray.prototype.fill", 1},
    {"TypedArray.prototype.filter", 1}, {"TypedArray.prototype.find", 1},
    {"TypedArray.prototype.findIndex", 1}, {"TypedArray.prototype.findLast", 1},
    {"TypedArray.prototype.findLastIndex", 1}, {"TypedArray.prototype.forEach", 1},
    {"TypedArray.prototype.includes", 1}, {"TypedArray.prototype.indexOf", 1},
    {"TypedArray.prototype.join", 1}, {"TypedArray.prototype.lastIndexOf", 1},
    {"TypedArray.prototype.map", 1}, {"TypedArray.prototype.reduce", 1},
    {"TypedArray.prototype.reduceRight", 1}, {"TypedArray.prototype.set", 1},
    {"TypedArray.prototype.slice", 2}, {"TypedArray.prototype.some", 1},
    {"TypedArray.prototype.sort", 1}, {"TypedArray.prototype.subarray", 2},
    {"TypedArray.prototype.with", 2}, {"TypedArray.prototype.toSorted", 1},
}

@(private = "file")
Meta_Pass :: struct {
    lengths: map[string]int,
    seen:    map[rawptr]bool,
    object_proto: ^Object,
}

// Dono genérico para grupos de globais que compartilham a tabela de métodos.
@(private = "file")
meta_owner :: proc(g: string) -> string {
    switch g {
    case "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
         "Int32Array", "Uint32Array", "Float32Array", "Float64Array",
         "BigInt64Array", "BigUint64Array":
        return "TypedArray"
    case "Map", "Set", "WeakMap", "WeakSet":
        return "Coll"
    case "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError":
        return "NativeError"
    }
    return g
}

// Um método (não uma construtora): sem `prototype` próprio e com nome minúsculo.
// O nome minúsculo é a trava de segurança — uma construtora nativa que por acaso
// não tenha `prototype` (Intl.X, por ex.) continua aceitando `new`.
@(private = "file")
meta_is_method :: proc(key: string, f: ^Function) -> bool {
    if f.props != nil { if _, has := f.props["prototype"]; has do return false }
    return len(key) > 0 && key[0] >= 'a' && key[0] <= 'z'
}

@(private = "file")
meta_fix_fn :: proc(p: ^Meta_Pass, path, key: string, f: ^Function, method: bool) {
    if f == nil || f.native == nil do return
    if f.name == "" do f.name = key
    full := strings.concatenate({path, ".", key}, context.temp_allocator) if path != "" else key
    if n, ok := p.lengths[full]; ok do f.native_length = n
    if method && meta_is_method(key, f) do f.non_constructor = true
}

// Corrige as propriedades próprias (props + attrs) de um holder builtin.
@(private = "file")
meta_fix_props :: proc(p: ^Meta_Pass, path: string, props: map[string]Value, attrs: ^map[string]Prop_Attrs) {
    for k, v in props {
        if is_non_enumerable_key(k) do continue // símbolo / campo interno: já fora
        a := ATTRS_DEFAULT
        if attrs^ != nil { if x, ok := attrs^[k]; ok do a = x }
        a -= {.Enumerable}
        #partial switch x in v {
        case f64, ^Symbol:
            a = {} // constantes: Math.PI, Number.EPSILON, Symbol.iterator, BYTES_PER_ELEMENT
        case ^Function:
            if k != "constructor" do meta_fix_fn(p, path, k, x, true)
        }
        if k == "prototype" do a = {}
        if attrs^ == nil do attrs^ = make(map[string]Prop_Attrs)
        attrs^[k] = a
    }
}

@(private = "file")
meta_fix_object :: proc(p: ^Meta_Pass, path: string, o: ^Object) {
    if o == nil || p.seen[o] do return
    p.seen[o] = true
    // Prototypes instalados ANTES de install_object nasceram com [[Prototype]]
    // nulo (Object.prototype ainda não existia): String.prototype, Math, ...
    // A spec liga todos a Object.prototype.
    if o.proto == nil && o != p.object_proto do o.proto = p.object_proto
    meta_fix_props(p, path, o.props, &o.attrs)
    for k, g in o.getters do if g != nil && g.name == "" do g.name = k
}

@(private = "file")
meta_fix_ctor :: proc(p: ^Meta_Pass, path: string, f: ^Function) {
    if f == nil || p.seen[f] do return
    p.seen[f] = true
    if f.props != nil {
        meta_fix_props(p, path, f.props, &f.attrs)
        if proto, ok := f.props["prototype"].(^Object); ok {
            meta_fix_object(p, strings.concatenate({path, ".prototype"}, context.temp_allocator), proto)
        }
    }
}

finalize_builtin_metadata :: proc(vm: ^Interp) {
    p: Meta_Pass
    p.lengths = make(map[string]int, len(SPEC_LENGTHS), context.temp_allocator)
    p.seen = make(map[rawptr]bool, 256, context.temp_allocator)
    p.object_proto = vm.object_proto
    for e in SPEC_LENGTHS do p.lengths[e.key] = e.n
    // Os prototypes foram povoados com cópias dos mapas de dispatch no meio da
    // instalação; quem trocou um método DEPOIS (o Intl troca toLocaleString) só
    // trocou no mapa. O primitivo agora lê o prototype primeiro — sincroniza.
    sync :: proc(proto: ^Object, methods: map[string]^Function) {
        if proto == nil do return
        for k, fn in methods do proto.props[k] = fn
    }
    sync(vm.string_proto, vm.string_methods)
    sync(vm.number_proto, vm.number_methods)
    sync(vm.boolean_proto, vm.boolean_methods)
    for g in ES_GLOBALS {
        v, ok := vm.global.vars[g]
        if !ok do continue
        owner := meta_owner(g)
        #partial switch x in v {
        case ^Function:
            if x.native != nil {
                if x.name == "" do x.name = g
                if n, has := p.lengths[owner]; has do x.native_length = n
                // função global solta (parseInt...) não é construtora
                if g[0] >= 'a' && g[0] <= 'z' do x.non_constructor = true
            }
            meta_fix_ctor(&p, owner, x)
        case ^Object:
            meta_fix_object(&p, owner, x)
        }
    }
}
