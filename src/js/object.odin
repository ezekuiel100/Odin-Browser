package js

import "core:math"
import "core:strings"

// O objeto/função global `Object` e seus estáticos (keys/values/entries/assign/
// create/freeze/getPrototypeOf), mais o método `hasOwnProperty` comum a todo
// objeto. Fundação de protótipos do M21 (fatia 0): a cadeia `Object.proto` já é
// percorrida por get_member (interp.odin); aqui só expomos a API de usuário.
//
// install_object é chamado por install_builtins (builtins.odin).

install_object :: proc(vm: ^Interp) {
    // método presente em todo objeto sem exigir prototype montado (get_member
    // faz fallback em vm.object_methods)
    vm.object_methods = make(map[string]^Function)
    vm.object_methods["hasOwnProperty"] = mk_builtin_method(vm, obj_has_own_property, "hasOwnProperty", 1)
    // Restante do Object.prototype que libs acessam via `{}.metodo` ou uncurryThis
    // (core-js: `l={}.propertyIsEnumerable; l.call(...)` — sem isto, `reading 'call'`
    // de undefined matava o bundle → página em branco).
    vm.object_methods["propertyIsEnumerable"] = mk_builtin_method(vm, obj_property_is_enumerable, "propertyIsEnumerable", 1)
    vm.object_methods["isPrototypeOf"]        = mk_builtin_method(vm, obj_is_prototype_of, "isPrototypeOf", 1)
    vm.object_methods["valueOf"]              = mk_builtin_method(vm, obj_value_of, "valueOf", 0)

    // `Object` é uma função (chamável: `new Object()`) que carrega os estáticos
    // nos seus props (get_member lê props de ^Function).
    ctor := mk_native(vm, obj_ctor)
    ctor.name = "Object"
    ctor.props = make(map[string]Value)
    ctor.props["keys"]            = mk_builtin_method(vm, obj_keys, "keys", 1)
    ctor.props["values"]          = mk_builtin_method(vm, obj_values, "values", 1)
    ctor.props["entries"]         = mk_builtin_method(vm, obj_entries, "entries", 1)
    ctor.props["assign"]          = mk_builtin_method(vm, obj_assign, "assign", 2)
    ctor.props["create"]          = mk_builtin_method(vm, obj_create, "create", 2)
    ctor.props["freeze"]          = mk_builtin_method(vm, obj_freeze, "freeze", 1)
    ctor.props["getPrototypeOf"]  = mk_builtin_method(vm, obj_get_prototype_of, "getPrototypeOf", 1)
    ctor.props["defineProperty"]  = mk_builtin_method(vm, obj_define_property, "defineProperty", 3)
    ctor.props["defineProperties"] = mk_builtin_method(vm, obj_define_properties, "defineProperties", 2)
    ctor.props["getOwnPropertyDescriptor"] = mk_builtin_method(vm, obj_get_own_property_descriptor, "getOwnPropertyDescriptor", 2)
    ctor.props["getOwnPropertyNames"]      = mk_builtin_method(vm, obj_get_own_property_names, "getOwnPropertyNames", 1)
    ctor.props["fromEntries"]     = mk_builtin_method(vm, obj_from_entries, "fromEntries", 1)
    ctor.props["setPrototypeOf"]  = mk_builtin_method(vm, obj_set_prototype_of, "setPrototypeOf", 2)
    ctor.props["is"]              = mk_builtin_method(vm, obj_is, "is", 2)
    // Família de integridade/extensibilidade. Desde o M164 são REAIS (antes seal e
    // preventExtensions eram no-op e isSealed era um apelido de isFrozen): o objeto
    // tem `non_extensible` e cada prop tem writable/enumerable/configurable.
    ctor.props["isExtensible"]      = mk_builtin_method(vm, obj_is_extensible, "isExtensible", 1)
    ctor.props["isFrozen"]          = mk_builtin_method(vm, obj_is_frozen, "isFrozen", 1)
    ctor.props["isSealed"]          = mk_builtin_method(vm, obj_is_sealed, "isSealed", 1)
    ctor.props["preventExtensions"] = mk_builtin_method(vm, obj_prevent_extensions, "preventExtensions", 1)
    ctor.props["seal"]              = mk_builtin_method(vm, obj_seal, "seal", 1)
    ctor.props["getOwnPropertyDescriptors"] = mk_builtin_method(vm, obj_get_own_property_descriptors, "getOwnPropertyDescriptors", 1)
    ctor.props["getOwnPropertySymbols"]     = mk_builtin_method(vm, obj_get_own_property_symbols, "getOwnPropertySymbols", 1)
    // Object.hasOwn(o,k) (ES2022) — 3 sites do corpus. É hasOwnProperty com o
    // receptor como 1º argumento (a forma recomendada hoje).
    ctor.props["hasOwn"]  = mk_builtin_method(vm, obj_has_own_static, "hasOwn", 2)
    ctor.props["groupBy"] = mk_builtin_method(vm, obj_group_by, "groupBy", 2) // ES2024
    // `Object.prototype`: objeto real. get_member(^Object) faz fallback em
    // vm.object_methods, então `Object.prototype.hasOwnProperty` resolve — React
    // faz `Object.prototype.hasOwnProperty.call(config, k)` em createElement.
    obj_proto := new_object(vm)
    obj_proto.props["constructor"] = ctor
    // Object.prototype.toString → "[object Tipo]". Idioma CLÁSSICO de detecção de
    // tipo: `Object.prototype.toString.call(x)`. Sem ele, checagens como
    // `{}.toString.call(e)=="[object Number]"` davam FALSE p/ números → libs
    // entravam em recursão/erro (ex.: clamp do PostHog no ultra-photo loopava).
    ts := mk_native(vm, obj_proto_to_string)
    obj_proto.props["toString"] = ts
    // Object.prototype é o topo da cadeia de TODO objeto desde que new_object passou
    // a ligá-lo. Os membros dele são não-enumeráveis na spec — sem marcar,
    // `Object.keys(Object.prototype)` listaria constructor/toString. (for-in e
    // Object.keys deste motor são own-only, então isto é defesa, não correção de bug.)
    mark_non_enumerable(obj_proto, "constructor")
    mark_non_enumerable(obj_proto, "toString")
    // `__proto__` é um ACESSOR em Object.prototype (spec B.2.2.1), não uma prop
    // de cada objeto — e a diferença importa: `Object.create(null).__proto__` tem
    // de ser `undefined` (esse objeto não herda de Object.prototype), e
    // `({}).hasOwnProperty('__proto__')` tem de ser false. Instalar aqui dá as
    // duas de graça; um caso especial no get_member daria `null` no 1º e
    // quebraria o 2º.
    // Delega ao MESMO código de Object.getPrototypeOf/setPrototypeOf para os dois
    // caminhos não divergirem (o `set` já é no-op para valor que não é objeto nem
    // null, como a spec manda — não lança).
    if obj_proto.getters == nil do obj_proto.getters = make(map[string]^Function)
    if obj_proto.setters == nil do obj_proto.setters = make(map[string]^Function)
    obj_proto.getters["__proto__"] = mk_native(vm, proto_accessor_get)
    obj_proto.setters["__proto__"] = mk_native(vm, proto_accessor_set)
    mark_non_enumerable(obj_proto, "__proto__")
    vm.object_methods["toString"] = ts // todo objeto sem toString próprio herda este
    vm.object_methods["toLocaleString"] = ts // default: mesmo que toString
    // Os demais métodos de Object.prototype também têm de ser propriedades
    // PRÓPRIAS dele (não só o fallback do get_member): o zod (github.com) decide
    // "objeto simples" por `hasOwnProperty.call(Ctor.prototype, "isPrototypeOf")`
    // e, com false, `schema.extend({...})` lançava "expected a plain object" —
    // o bundle da home morria. Mesmas ^Function do mapa: identidade preservada.
    for nome in ([]string{"hasOwnProperty", "propertyIsEnumerable", "isPrototypeOf", "valueOf", "toLocaleString"}) {
        obj_proto.props[nome] = vm.object_methods[nome]
        mark_non_enumerable(obj_proto, nome)
    }
    ctor.props["prototype"] = obj_proto
    vm.object_proto = obj_proto // base da cadeia de protótipos (p/ %IteratorPrototype% etc.)
    env_define(vm.global, "Object", ctor)
}

// Object.fromEntries(iterável de pares): aceita Array de [k,v] e Map.
@(private = "file")
obj_from_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    #partial switch src in arg(args, 0) {
    case ^Array:
        for it in src.items {
            if pair, pok := it.(^Array); pok && len(pair.items) >= 1 {
                v: Value = nil
                if len(pair.items) >= 2 do v = pair.items[1]
                oput(o, key_string(vm, pair.items[0]), v)
            }
        }
    case ^Collection:
        if src.kind == .Map || src.kind == .Weak_Map {
            for e in src.entries do if !e.dead do oput(o, key_string(vm, e.key), e.val)
        }
    }
    return o
}

// Object.setPrototypeOf(obj, proto): religa a cadeia (base da herança ES5
// transpilada — Babel/TS usam em _inherits). proto null desliga.
@(private = "file")
obj_set_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target, proto := arg(args, 0), arg(args, 1)
    if target == nil || target == (JS_Null{}) {
        throw_type_error(vm, "Cannot set prototype of null or undefined")
        return nil
    }
    if is_primitive(proto) && proto != (JS_Null{}) {
        throw_type_error(vm, "Object prototype may only be an Object or null")
        return nil
    }
    if is_primitive(target) do return target
    current := obj_get_prototype_of(vm, nil, []Value{target})
    if current == proto do return target
    if o, ok := target.(^Object); ok && o.non_extensible {
        throw_type_error(vm, "Cannot set prototype of a non-extensible object")
        return nil
    }
    // Validate before changing links, including chains crossing functions.
    for cur := proto; cur != (JS_Null{}) && cur != nil; cur = obj_get_prototype_of(vm, nil, []Value{cur}) {
        if cur == target {
            throw_type_error(vm, "Cyclic prototype value")
            return nil
        }
    }
    #partial switch o in target {
    case ^Function:
        #partial switch p in proto {
        case ^Function: o.super_ctor = p
        case JS_Null: o.super_ctor = nil
        }
    case ^Object:
        set_proto_value(o, proto)
    }
    return target
}

// Object.is(a, b): SameValue da spec — como === com duas diferenças, e as duas
// importam: NaN é igual a NaN, e +0 NÃO é igual a -0.
//
// O `==` do Odin sobre f64 segue o IEEE, onde +0 == -0 é true; a distinção mora no
// BIT DE SINAL, então os zeros são comparados por ele. Não confundir com
// `same_value_zero` (collections.odin), que é o SameValueZero usado por Map/Set e
// por `includes` — lá +0 e -0 são o MESMO valor de propósito.
@(private = "file")
obj_is :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, b := arg(args, 0), arg(args, 1)
    if x, xok := a.(f64); xok {
        if y, yok := b.(f64); yok {
            if x != x && y != y do return true // NaN é igual a NaN (≠ do ===)
            if x == 0 && y == 0 do return math.sign_bit(x) == math.sign_bit(y)
            return x == y
        }
        return false
    }
    return a == b // union ==: variante + valor (identidade p/ ponteiros)
}

// Object.prototype.toString.call(x) → "[object Tipo]" pelo tipo de `this`.
@(private = "file")
obj_proto_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    switch v in this {
    case f64:       return own_str(vm, "[object Number]")
    case bool:      return own_str(vm, "[object Boolean]")
    case string:    return own_str(vm, "[object String]")
    case JS_Null:   return own_str(vm, "[object Null]")
    case ^Function: return own_str(vm, "[object Function]")
    case ^Array:
        // o outro jeito de uma lib distinguir arguments de array de verdade
        if v.is_arguments do return own_str(vm, "[object Arguments]")
        return own_str(vm, "[object Array]")
    case ^Regex:    return own_str(vm, "[object RegExp]")
    case ^Symbol:   return own_str(vm, "[object Symbol]")
    case ^BigInt:   return own_str(vm, "[object BigInt]")
    case ^Collection:
        switch v.kind {
        case .Map:      return own_str(vm, "[object Map]")
        case .Set:      return own_str(vm, "[object Set]")
        case .Weak_Map: return own_str(vm, "[object WeakMap]")
        case .Weak_Set: return own_str(vm, "[object WeakSet]")
        }
        return own_str(vm, "[object Object]")
    case ^Object:
        // Symbol.toStringTag do USUÁRIO vem primeiro (spec): `{[Symbol.toStringTag]:
        // "Foo"}` → "[object Foo]". Lido por get_member, então um getter e uma tag
        // herdada do prototype (idioma de classe) também valem. Só string conta —
        // a spec ignora tag de qualquer outro tipo e cai no default.
        if vm.sym_tostring_tag_key != "" {
            tag := get_member(vm, v, vm.sym_tostring_tag_key)
            if vm.throwing do return nil
            if s, ok := tag.(string); ok {
                sb: strings.Builder
                strings.builder_init(&sb)
                defer strings.builder_destroy(&sb)
                strings.write_string(&sb, "[object ")
                strings.write_string(&sb, s)
                strings.write_byte(&sb, ']')
                return own_str(vm, strings.to_string(sb))
            }
        }
        // [[Class]] interno: Math/JSON/arguments guardam a tag já pronta
        // ("[object Math]") em #class (não-enumerável, padrão do #t do Date).
        if cls, ok := v.props["#class"].(string); ok do return own_str(vm, cls)
        // wrapper de primitivo: o builtinTag vem do slot interno
        if p, ok := wrapper_value(v); ok {
            #partial switch _ in p {
            case string: return own_str(vm, "[object String]")
            case f64:    return own_str(vm, "[object Number]")
            case bool:   return own_str(vm, "[object Boolean]")
            }
        }
        if _, isdate := v.props["#t"].(f64); isdate do return own_str(vm, "[object Date]")
        return own_str(vm, "[object Object]")
    }
    return own_str(vm, "[object Undefined]") // nil = undefined
}

// Object() / new Object(x): sem arg ou nulo => objeto vazio; com objeto existente
// => devolve o próprio (identidade, como no JS); primitivo => ToObject, o WRAPPER
// (`Object("a") instanceof String`). Antes o primitivo virava `{}` — e
// `Object(x) === x`, o idioma de "x é objeto?", dava a resposta certa por acaso.
@(private = "file")
obj_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := arg(args, 0)
    #partial switch _ in a {
    case ^Object, ^Array, ^Function, ^Regex, ^Collection:
        return a
    case string, f64, bool:
        return make_wrapper(vm, a)
    }
    return new_object(vm)
}

// Chaves PRÓPRIAS enumeráveis de QUALQUER valor, não só de ^Object.
//
// ⚠️ neste motor Function, Array e string NÃO são ^Object — cada um é seu próprio
// tipo, com seu próprio `props`. Todo `arg(args,0).(^Object)` daqui os descartava
// EM SILÊNCIO: `Object.keys(fn)` devolvia `[]` mesmo com propriedades próprias, e
// idem para `Object.keys([10,20])`.
//
// Foi o que deixou o open.spotify.com em branco. O runtime do webpack 5 decide se
// já pode rodar a entrada com:
//     Object.keys(__webpack_require__.O).every(k => O[k](chunkId))
// — e `[].every(...)` é **true por vacuidade**. Com a lista vazia o portão sempre
// abria: a entrada rodava durante o 1º bundle, antes de o chunk `vendor` chegar, e
// pedia um módulo que ainda não existia (`l[96175].call` → undefined).
//
// Ordem: índices primeiro (crescente) e depois as demais, como manda a spec.
// package-visible: o spread de object literal (`{...src}`) em interp.odin reusa —
// era a MESMA lista de tipos escrita duas vezes, e a cópia de lá tinha ficado só no
// `^Object` (M220).
own_keys_any :: proc(vm: ^Interp, v: Value, out: ^[dynamic]string, all: bool = false) {
    if p := proxy_state(v); p != nil { proxy_keys(vm, p, out, all); return }
    #partial switch x in v {
    case ^Object:
        own_string_keys(vm, x, out, all)
    case ^Function:
        // `prototype`/`name`/`length` são próprias mas NÃO-enumeráveis (spec) —
        // só as que o autor pôs devem aparecer. ⚠️ isso esconde um `f.length = 5`
        // explícito; é o preço de não termos atributos de propriedade em Function.
        for k in x.props {
            if a, explicit := x.attrs[k]; explicit && .Enumerable not_in a do continue
            if is_non_enumerable_key(k) do continue
            switch k {
            case "prototype", "name", "length", "caller", "arguments": continue
            }
            append(out, k)
        }
    case ^Array:
        for i in 0 ..< len(x.items) {
            if arr_is_hole(x, i) do continue // buraco não é chave própria
            s, _ := v_to_key_string(vm, f64(i))
            if !all && .Enumerable not_in array_attrs(x, s) do continue
            append(out, s)
        }
        for k in x.props {
            if is_non_enumerable_key(k) do continue
            if !all && .Enumerable not_in array_attrs(x, k) do continue
            append(out, k)
        }
    case string:
        // índices em CODE UNITS UTF-16, como o resto do motor (ver M167)
        for i in 0 ..< str_rlen(x) {
            s, _ := v_to_key_string(vm, f64(i))
            append(out, s)
        }
    }
}

// "0", "1", … registrados no vm (as chaves de índice não vêm de nenhum mapa).
@(private = "file")
v_to_key_string :: proc(vm: ^Interp, n: f64) -> (string, bool) {
    s := key_string(vm, n)
    return s, true
}

obj_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(arg(args, 0)) { throw_type_error(vm, "Cannot convert undefined or null to object"); return nil }
    out := new_array(vm)
    keys: [dynamic]string
    defer delete(keys)
    own_keys_any(vm, arg(args, 0), &keys)
    for k in keys do append(&out.items, k) // chave é dona do próprio map
    return out
}

@(private = "file")
obj_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(arg(args, 0)) { throw_type_error(vm, "Cannot convert undefined or null to object"); return nil }
    out := new_array(vm)
    src := arg(args, 0)
    keys: [dynamic]string
    defer delete(keys)
    own_keys_any(vm, src, &keys)
    // get_INDEX, não get_member: é o superconjunto — resolve chave de índice em
    // array/string (`"0"` → items[0]) e cai no get_member (getters, cadeia de
    // proto) para o resto. Com get_member, `Object.values([10,20])` dava [,] .
    for k in keys do append(&out.items, get_index(vm, src, k))
    return out
}

@(private = "file")
obj_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(arg(args, 0)) { throw_type_error(vm, "Cannot convert undefined or null to object"); return nil }
    out := new_array(vm)
    src := arg(args, 0)
    keys: [dynamic]string
    defer delete(keys)
    own_keys_any(vm, src, &keys)
    for k in keys {
        pair := new_array(vm)
        append(&pair.items, k)
        append(&pair.items, get_index(vm, src, k)) // idem obj_values
        append(&out.items, pair)
    }
    return out
}

// Object.assign(dest, ...srcs): copia props próprias ENUMERÁVEIS dos srcs para
// dest (via get/set_member, honrando getters/setters), devolve dest.
@(private = "file")
obj_assign :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    dest := arg(args, 0)
    if is_nullish(dest) { // ToObject(undefined/null) → TypeError (spec)
        throw_type_error(vm, "Cannot convert undefined or null to object")
        return nil
    }
    // ⚠️ O DESTINO não é só `^Object` (M220). Neste motor Function, Array e Regex são
    // variantes PRÓPRIAS da union — `dest, ok := arg.(^Object)` mandava embora, EM
    // SILÊNCIO e devolvendo o alvo intacto, o idioma mais comum de componente React:
    //     let W = Object.assign(PageLayout, {Header, Content, Pane, Sidebar, Footer})
    // O `W` voltava sem os subcomponentes e o consumidor morria em
    // `reading '__SLOT__' of undefined`, três módulos adiante. `set_member` já sabe
    // escrever em Function/Array/Regex; era só parar de estreitar aqui.
    // Primitivo (number/string/bool) segue devolvido intacto: a spec o EMBRULHA e as
    // escritas se perdem no embrulho — sem objeto-embrulho aqui, o efeito é o mesmo.
    #partial switch _ in dest {
    case ^Object, ^Function, ^Array: // os três que `set_index` sabe escrever
    case:
        return dest
    }
    for i in 1 ..< len(args) {
        // ToObject de cada FONTE (spec): string/array copiam índices enumeráveis;
        // null/undefined são pulados. `own_keys_any` cobre Object/Function/Array/
        // string — a fonte FUNÇÃO entrou junto (`Object.assign({}, Componente)` e o
        // spread `{...Componente}` copiavam NADA, mesma raiz do M180).
        keys: [dynamic]string
        defer delete(keys)
        own_keys_any(vm, args[i], &keys)
        for k in keys {
            // get_/set_INDEX, não _MEMBER: são o superconjunto (resolvem "0" → items[0]
            // num Array e caem no _member para o resto). Com _member, copiar array
            // gravaria "0" nas props do destino em vez do item.
            set_index(vm, dest, k, get_index(vm, args[i], k))
            if vm.throwing do return dest
        }
    }
    return dest
}

// Object.create(proto): novo objeto cuja cadeia começa em `proto` (null => sem proto).
@(private = "file")
obj_create :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    // `Object.create(null)` = dicionário PURO, sem cadeia — o idioma de mapa sem
    // herança. new_object agora liga todo objeto em Object.prototype, então aqui
    // é preciso DESLIGAR e só religar se veio um proto de verdade.
    o.proto = nil
    set_proto_value(o, arg(args, 0))
    // 2º argumento (descritores). Era IGNORADO em silêncio — o protótipo saía
    // certo e as props NÃO existiam, então o defeito não aparecia aqui: aparecia
    // longe, dentro de código transpilado.
    //
    // ⚠️ A cadeia medida no getbootstrap.com (clipboard.js em ES5): o `_inherits`
    // do Babel faz `Object.create(Super.prototype, {constructor:{value: Sub}})`.
    // Sem o descritor, `Sub.prototype.constructor` HERDA o do Super, então o
    // `_createSuper` calcula `NewTarget = Super` e o `Reflect.construct` cria a
    // instância com o protótipo do SUPER — sem os métodos da subclasse. Sintoma:
    // `TypeError: u.resolveOptions is not a function`, a 4 saltos daqui.
    apply_descriptors(vm, o, arg(args, 1))
    return o
}

// Aplica um objeto de descritores (`{k: {value|get|set, ...}}`) em `o`.
// Existe para `Object.create` e `Object.defineProperties` não divergirem — eram
// a mesma regra escrita (ou esquecida) em dois lugares.
@(private = "file")
apply_descriptors :: proc(vm: ^Interp, o: ^Object, descs_v: Value) {
    descs, ok := descs_v.(^Object)
    if !ok do return
    for k, d in descs.props {
        if is_symbol_key(k) do continue
        if desc, dok := d.(^Object); dok do apply_descriptor(vm, o, k, desc)
    }
}

// [[SetPrototypeOf]] a partir de um Value qualquer: ^Object vai para `proto`; array/
// função/regex/coleção (variantes próprias da union, que não cabem em `proto`) vão
// para `proto_x`; null desliga. Um dos dois campos sempre zera o outro — a cadeia é
// UMA só, e `proto_exotic_end` conta com isso.
// Era o furo do `Object.create(array)`: o protótipo não-^Object era descartado em
// SILÊNCIO e o objeto nascia sem herdar nada (nem os métodos, nem os índices, nem as
// props próprias do array). Ver [[real-site-fidelity]] M208.
// Visível no pacote: o eval de `{__proto__: v}` (interp.odin) chama daqui, para o
// literal e o acessor concordarem sobre o que é um protótipo válido.
set_proto_value :: proc(o: ^Object, p: Value) {
    // Um valor que não é objeto nem null (`setPrototypeOf(o, 5)`) é NO-OP — a spec
    // lança ali, e no-op é a leniência que já valia. Por isso a limpeza dos dois
    // campos vive DENTRO de cada case: zerar antes do switch transformaria a entrada
    // inválida em "objeto sem protótipo", que é pior do que ignorar.
    #partial switch v in p {
    case ^Object:                                  o.proto, o.proto_x = v, nil
    case ^Array, ^Function, ^Regex, ^Collection:   o.proto, o.proto_x = nil, p
    case JS_Null:                                  o.proto, o.proto_x = nil, nil
    }
}

@(private = "file")
obj_freeze :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // não-extensível + toda prop própria perde writable E configurable.
    #partial switch o in arg(args, 0) {
    case ^Object:
        o.non_extensible = true
        for k in o.props do set_prop_attrs(o, k, prop_attrs(o, k) - {.Writable, .Configurable})
    case ^Array:
        o.frozen = true // itens e length: checado em set_index/push (interp/builtins)
    }
    return arg(args, 0)
}

// Object.seal(o): não-extensível + toda prop perde configurable, mas segue GRAVÁVEL —
// é exatamente o que separa seal de freeze, e o que este motor não modelava.
@(private = "file")
obj_seal :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    #partial switch o in arg(args, 0) {
    case ^Object:
        o.non_extensible = true
        for k in o.props do set_prop_attrs(o, k, prop_attrs(o, k) - {.Configurable})
    case ^Array:
        o.sealed = true
    }
    return arg(args, 0)
}

// Object.isSealed(o): não-extensível e nenhuma prop configurável.
@(private = "file")
obj_is_sealed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    #partial switch o in arg(args, 0) {
    case ^Object:
        if !o.non_extensible do return false
        for k in o.props do if .Configurable in prop_attrs(o, k) do return false
        return true
    case ^Array:    return o.frozen || o.sealed
    case ^Function: return false
    }
    return true
}

// Object.isExtensible / isFrozen / isSealed — QUERIES de integridade. O nosso modelo
// só tem o flag `frozen` (bloqueia TODA escrita), então sealed≈frozen (aprox.). Sites
// chamam isExtensible defensivamente — gap-miner: "Object.isExtensible is not a function"
// (3 sites, coingecko). Primitivo → não-extensível/congelado (spec ES6+: retorna, sem throw).
@(private = "file")
obj_is_extensible :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    #partial switch o in arg(args, 0) {
    case ^Object:   return !o.non_extensible
    case ^Array:    return !o.frozen && !o.sealed
    case ^Function: return true
    }
    return false // primitivos: não-extensíveis
}

@(private = "file")
obj_is_frozen :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    #partial switch o in arg(args, 0) {
    case ^Object:
        if !o.non_extensible do return false
        // congelado = nenhuma prop própria gravável nem configurável
        for k in o.props {
            a := prop_attrs(o, k)
            if .Writable in a || .Configurable in a do return false
        }
        return true
    case ^Array:    return o.frozen
    case ^Function: return false
    }
    return true // primitivos são "frozen" (spec)
}

// Object.preventExtensions / seal — no-op que devolve o alvo. O nosso `frozen` bloqueia
// TODA escrita (inclusive de props EXISTENTES), forte demais p/ estes (seal ainda permite
// modificar props existentes; preventExtensions idem). Quem os chama tipicamente só quer
// que a chamada não estoure (feature-detect/defensivo). APROX.: não passam a impedir novas
// props — bloquear a escrita de props existentes quebraria mais que deixar somar uma prop.
@(private = "file")
obj_prevent_extensions :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // só barra props NOVAS; as existentes seguem graváveis e deletáveis
    #partial switch o in arg(args, 0) {
    case ^Object: o.non_extensible = true
    case ^Array:  o.sealed = true // array: barra crescer (push/índice novo)
    }
    return arg(args, 0)
}

// Object.getOwnPropertyDescriptors(o): mapa chave→descritor de TODAS as próprias (reusa
// obj_get_own_property_descriptor por chave). Usado por spread de descritores e polyfills
// (`Object.defineProperties(t, Object.getOwnPropertyDescriptors(s))`).
@(private = "file")
obj_get_own_property_descriptors :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_object(vm)
    target := arg(args, 0)
    seen: map[string]bool
    defer delete(seen)
    add_key :: proc(vm: ^Interp, target: Value, out: ^Object, seen: ^map[string]bool, key: string) {
        if is_non_enumerable_key(key) || seen[key] do return
        seen[key] = true
        d := obj_get_own_property_descriptor(vm, nil, []Value{target, key})
        if d != nil do oput(out, key, d)
    }
    if _, isarr := target.(^Array); isarr {
        keys: [dynamic]string
        defer delete(keys)
        own_keys_any(vm, target, &keys, true) // índices presentes + props
        for k in keys do add_key(vm, target, out, &seen, k)
        add_key(vm, target, out, &seen, "length")
        return out
    }
    o, ok := target.(^Object)
    if !ok do return out
    for k in o.props do add_key(vm, target, out, &seen, k)
    if o.getters != nil do for k in o.getters do add_key(vm, target, out, &seen, k)
    if o.setters != nil do for k in o.setters do add_key(vm, target, out, &seen, k)
    return out
}

// Object.getOwnPropertySymbols(o): os símbolos usados como chave PRÓPRIA de `o`.
// Devolvia array vazio porque a chave-string não permitia recuperar o ^Symbol; agora
// `symbol_key` mantém o mapa reverso (vm.symbol_keys). Ordem de inserção (korder),
// como as chaves-string.
@(private = "file")
obj_get_own_property_symbols :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    if p := proxy_state(arg(args, 0)); p != nil {
        keys: [dynamic]string
        defer delete(keys)
        proxy_keys(vm, p, &keys, true)
        for k in keys {
            if sym, ok := vm.symbol_keys[k]; ok do append(&out.items, sym)
        }
        return out
    }
    o, ok := arg(args, 0).(^Object)
    if !ok || vm.symbol_keys == nil do return out
    seen: map[string]bool
    defer delete(seen)
    emit :: proc(vm: ^Interp, out: ^Array, seen: ^map[string]bool, k: string) {
        if !is_symbol_key(k) || seen[k] do return
        sym, has := vm.symbol_keys[k]
        if !has do return // símbolo bem-conhecido instalado como string crua: não é um ^Symbol
        seen[k] = true
        append(&out.items, sym)
    }
    for k in o.korder do if okey_alive(o, k) do emit(vm, out, &seen, k)
    for k in o.props do emit(vm, out, &seen, k) // escritas nativas que não passaram por oput
    if o.getters != nil do for k in o.getters do emit(vm, out, &seen, k)
    if o.setters != nil do for k in o.setters do emit(vm, out, &seen, k)
    return out
}

// Os dois lados do acessor `__proto__`. `this` é o receptor, então basta
// encaminhar para os estáticos — nada de lógica duplicada aqui.
@(private = "file")
proto_accessor_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return obj_get_prototype_of(vm, nil, []Value{this})
}
@(private = "file")
proto_accessor_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    proto := arg(args, 0)
    if !is_primitive(proto) || proto == (JS_Null{}) do obj_set_prototype_of(vm, nil, []Value{this, proto})
    return nil // o setter não devolve valor (spec)
}

obj_get_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p := proxy_state(arg(args, 0)); p != nil do return proxy_get_prototype_of(vm, p)
    if o, ok := arg(args, 0).(^Object); ok {
        if o.proto != nil do return o.proto
        if o.proto_x != nil do return o.proto_x // protótipo exótico (Object.create(array))
    }
    // FUNÇÕES/CLASSES: o [[Prototype]] de uma classe derivada é a SUPERCLASSE, e o de
    // uma função comum é Function.prototype. Devolver null aqui quebrava o helper
    // `_createSuper` do Babel — `_getPrototypeOf(Derived)` virava null e o
    // `Super.apply(this, arguments)` seguinte lançava TypeError. O React captura essa
    // exceção no error boundary e DESMONTA a árvore: página em branco sem erro visível
    // (npmjs.com). Ver [[js-engine-roadmap]] M127.
    if f, ok := arg(args, 0).(^Function); ok {
        if f.super_ctor != nil do return f.super_ctor
        if vm.function_proto != nil do return vm.function_proto
    }
    // ARRAY: `Object.getPrototypeOf([])` devolvia null — o array é variante
    // PRÓPRIA da union, não um ^Object, então não tem campo `proto` para ler. O
    // protótipo dele é sempre `Array.prototype` (não há como trocá-lo aqui), e é
    // de lá que `[].__proto__` também responde.
    if a, ok := arg(args, 0).(^Array); ok {
        if a.args != nil && vm.object_proto != nil do return vm.object_proto // `arguments`
        if vm.array_ctor != nil {
            if p, pok := vm.array_ctor.props["prototype"].(^Object); pok do return p
        }
    }
    return JS_Null{}
}

// Aplica um descritor {get,set,value,enumerable,...} à chave `key` de `o`.
// - accessor (get/set): grava em o.getters/o.setters (get_member/set_member já os
//   consultam, subindo a cadeia de proto) e remove qualquer data-prop obsoleta.
// - data (value): grava em o.props (só se "value" estiver presente — assim
//   `defineProperty(o,k,{enumerable:false})` muda só a visibilidade sem zerar o valor).
// - writable/enumerable/configurable: PADRÃO false (semântica de defineProperty —
//   ao contrário de uma atribuição normal, que dá os três). Vão para `o.attrs`.
//   Um atributo OMITIDO numa redefinição preserva o que já valia, como na spec.
@(private = "file")
apply_descriptor :: proc(vm: ^Interp, o: ^Object, key: string, source_desc: ^Object) {
    desc := normalize_descriptor(vm, source_desc)
    if vm.throwing do return
    apply_normalized_descriptor(vm, o, key, desc)
}

normalize_descriptor :: proc(vm: ^Interp, desc: ^Object) -> ^Object {
    normalized := new_object(vm)
    fields := []string{"enumerable", "configurable", "value", "writable", "get", "set"}
    for field in fields {
        for cur := desc; cur != nil; cur = cur.proto {
            _, data := cur.props[field]
            _, getter := cur.getters[field]
            _, setter := cur.setters[field]
            if data || getter || setter { normalized.props[field] = get_member(vm, desc, field); break }
        }
        if vm.throwing do return normalized
    }
    g, hg := normalized.props["get"]; s, hs := normalized.props["set"]
    _, hv := normalized.props["value"]; _, hw := normalized.props["writable"]
    _, gok := g.(^Function); _, sok := s.(^Function)
    if ((hg || hs) && (hv || hw)) || (hg && g != nil && !gok) || (hs && s != nil && !sok) {
        throw_type_error(vm, "Invalid property descriptor")
    }
    return normalized
}

apply_normalized_descriptor :: proc(vm: ^Interp, o: ^Object, key: string, desc: ^Object) {
    g, hg := desc.props["get"]
    st, hs := desc.props["set"]
    v, hv := desc.props["value"]
    w, hw := desc.props["writable"]
    e, he := desc.props["enumerable"]
    c, hc := desc.props["configurable"]
    gf, gok := g.(^Function)
    sf, sok := st.(^Function)
    accessor := hg || hs
    if (accessor && (hv || hw)) || (hg && g != nil && !gok) || (hs && st != nil && !sok) {
        throw_type_error(vm, "Invalid property descriptor"); return
    }
    oldg, og := o.getters[key]
    olds, os := o.setters[key]
    oldv, ov := o.props[key]
    existed := ov || og || os
    oldacc := og || os
    a := prop_attrs(o, key) if existed else Prop_Attrs{}
    if !existed && o.non_extensible { throw_type_error(vm, "Object is not extensible"); return }
    if existed && .Configurable not_in a {
        invalid := (hc && truthy(c)) || (he && truthy(e) != (.Enumerable in a))
        if accessor || hv || hw do invalid = invalid || accessor != oldacc
        if oldacc {
            invalid = invalid || (hg && gf != oldg) || (hs && sf != olds)
        } else if .Writable not_in a {
            invalid = invalid || (hw && truthy(w)) || (hv && !truthy(obj_is(vm, nil, []Value{v, oldv})))
        }
        if invalid { throw_type_error(vm, "Cannot redefine non-configurable property"); return }
    }
    if accessor {
        // data → accessor mantém a POSIÇÃO na ordem de inserção: tira o valor sem
        // passar por oremove (que tiraria a chave do korder também)
        if !oldacc { delete_key(&o.props, key); a -= {.Writable} }
        if !existed do okey_accessor(o, key) // accessor novo: entra no fim da ordem
        if o.getters == nil do o.getters = make(map[string]^Function)
        if o.setters == nil do o.setters = make(map[string]^Function)
        if hg || !oldacc do o.getters[key] = gf
        if hs || !oldacc do o.setters[key] = sf
    } else if hv || hw || !existed {
        if oldacc { delete_key(&o.getters, key); delete_key(&o.setters, key); a -= {.Writable} }
        if hv { oput(o, key, v) } else if !ov { oput(o, key, nil) }
    }
    if he do a = truthy(e) ? a + {.Enumerable} : a - {.Enumerable}
    if hw do a = truthy(w) ? a + {.Writable} : a - {.Writable}
    if hc do a = truthy(c) ? a + {.Configurable} : a - {.Configurable}
    set_prop_attrs(o, key, a)
}

// Object.defineProperty(obj, key, descriptor) — devolve obj.
// package-visible: Reflect.defineProperty (proxy.odin) delega aqui.
obj_define_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if a, aok := arg(args, 0).(^Array); aok {
        key := key_string(vm, arg(args, 1))
        if vm.throwing do return nil
        desc, dok := arg(args, 2).(^Object)
        if !dok { throw_type_error(vm, "Property descriptor must be an object"); return nil }
        array_define_property(vm, a, key, desc)
        return a
    }
    if fn, fok := arg(args, 0).(^Function); fok {
        key := key_string(vm, arg(args, 1))
        desc, dok := arg(args, 2).(^Object)
        if !dok { throw_type_error(vm, "Property descriptor must be an object"); return nil }
        if fn.props == nil do fn.props = make(map[string]Value)
        view := Object{props = fn.props, getters = fn.getters, setters = fn.setters, attrs = fn.attrs}
        defer delete(view.korder)
        apply_descriptor(vm, &view, key, desc)
        fn.props = view.props; fn.getters = view.getters; fn.setters = view.setters; fn.attrs = view.attrs
        return fn
    }
    o, ok := arg(args, 0).(^Object)
    if !ok {
        throw_type_error(vm, "Object.defineProperty called on non-object")
        return nil
    }
    key := key_string(vm, arg(args, 1))
    if desc, dok := arg(args, 2).(^Object); dok { apply_descriptor(vm, o, key, desc) } else { throw_type_error(vm, "Property descriptor must be an object") }
    return o
}

// Object.defineProperties(obj, {k1: desc1, ...}) — devolve obj.
@(private = "file")
obj_define_properties :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if a, isarr := arg(args, 0).(^Array); isarr {
        keys: [dynamic]string
        descs: [dynamic]^Object
        defer delete(keys)
        defer delete(descs)
        own_keys_any(vm, arg(args, 1), &keys)
        for key in keys {
            value := get_index(vm, arg(args, 1), key)
            if vm.throwing do return nil
            desc, valid := value.(^Object)
            if !valid { throw_type_error(vm, "Property descriptor must be an object"); return nil }
            append(&descs, normalize_descriptor(vm, desc))
            if vm.throwing do return nil
        }
        for desc, i in descs {
            array_define_property(vm, a, keys[i], desc)
            if vm.throwing do return nil
        }
        return a
    }
    o, ok := arg(args, 0).(^Object)
    if !ok do return arg(args, 0)
    apply_descriptors(vm, o, arg(args, 1)) // MESMA regra do Object.create (ver lá)
    return o
}

// Object.getOwnPropertyDescriptor(obj, key) — descritor ou undefined (nil).
// package-visible: Reflect.getOwnPropertyDescriptor (proxy.odin) delega aqui.
obj_get_own_property_descriptor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p := proxy_state(arg(args, 0)); p != nil {
        if trap, ok := proxy_trap(vm, p, "getOwnPropertyDescriptor"); ok {
            return call_function(vm, trap, p.px_handler, []Value{p.px_target, arg(args, 1)})
        }
        if vm.throwing do return nil
        return obj_get_own_property_descriptor(vm, nil, []Value{p.px_target, arg(args, 1)})
    }
    if fn, fok := arg(args, 0).(^Function); fok {
        key := key_string(vm, arg(args, 1))
        _, data := fn.props[key]; _, getter := fn.getters[key]; _, setter := fn.setters[key]
        if data || getter || setter {
            view := Object{props = fn.props, getters = fn.getters, setters = fn.setters, attrs = fn.attrs}
            return obj_get_own_property_descriptor(vm, nil, []Value{&view, arg(args, 1)})
        }
        if key == "name" || key == "length" {
            d := new_object(vm)
            d.props["value"] = get_member(vm, fn, key)
            d.props["writable"] = false; d.props["enumerable"] = false; d.props["configurable"] = true
            return d
        }
        return nil
    }
    if arr, aok := arg(args, 0).(^Array); aok {
        // array: índices PRESENTES (buraco = sem descritor), `length` e props não-índice.
        // Explicit descriptors override defaults; frozen/sealed restrict them further.
        key := key_string(vm, arg(args, 1))
        attrs := array_attrs(arr, key)
        if m := arr.descriptors; m != nil {
            g, hg := m.getters[key]; s, hs := m.setters[key]
            if hg || hs {
                d := new_object(vm)
                d.props["get"] = g if g != nil else nil
                d.props["set"] = s if s != nil else nil
                d.props["enumerable"] = .Enumerable in attrs
                d.props["configurable"] = .Configurable in attrs
                return d
            }
        }
        mk :: proc(vm: ^Interp, v: Value, w, e, c: bool) -> ^Object {
            d := new_object(vm)
            oput(d, "value", v); oput(d, "writable", w); oput(d, "enumerable", e); oput(d, "configurable", c)
            return d
        }
        if arr.args != nil { // `arguments`: length e callee são data-props configuráveis
            if key == "length" do return mk(vm, f64(len(arr.items)), !arr.frozen, false, !arr.frozen)
            if key == "callee" && arr.args.callee != nil && !arr.args.callee.strict {
                return mk(vm, arr.args.callee, true, false, true)
            }
        }
        if key == "length" do return mk(vm, f64(len(arr.items)), .Writable in attrs, false, false)
        if idx, iok := array_index_name(key); iok {
            if !arr_has_index(arr, idx) do return nil
            return mk(vm, arr.items[idx], .Writable in attrs, .Enumerable in attrs, .Configurable in attrs)
        }
        if arr.props != nil {
            if v, has := arr.props[key]; has do return mk(vm, v, .Writable in attrs, .Enumerable in attrs, .Configurable in attrs)
        }
        return nil
    }
    o, ok := arg(args, 0).(^Object)
    if !ok do return nil
    key := key_string(vm, arg(args, 1))
    a := prop_attrs(o, key)
    enumerable := .Enumerable in a
    configurable := .Configurable in a
    if o.getters != nil {
        if g, gok := o.getters[key]; gok {
            d := new_object(vm)
            d.props["get"] = g if g != nil else nil
            d.props["set"] = nil
            if o.setters != nil { if s, sok := o.setters[key]; sok do d.props["set"] = s if s != nil else nil }
            d.props["enumerable"] = enumerable
            d.props["configurable"] = configurable
            return d
        }
    }
    if o.setters != nil {
        if s, sok := o.setters[key]; sok {
            d := new_object(vm)
            d.props["get"] = nil
            d.props["set"] = s if s != nil else nil
            d.props["enumerable"] = enumerable
            d.props["configurable"] = configurable
            return d
        }
    }
    if v, vok := o.props[key]; vok {
        d := new_object(vm)
        d.props["value"] = v
        d.props["writable"] = .Writable in a
        d.props["enumerable"] = enumerable
        d.props["configurable"] = configurable
        return d
    }
    return nil
}

// Object.getOwnPropertyNames(obj) — TODAS as chaves próprias string (inclusive as
// não-enumeráveis), excluindo símbolos.
@(private = "file")
obj_get_own_property_names :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    if p := proxy_state(arg(args, 0)); p != nil {
        keys: [dynamic]string
        defer delete(keys)
        proxy_keys(vm, p, &keys, true)
        for k in keys {
            if !is_non_enumerable_key(k) do append(&out.items, own_str(vm, k))
        }
        return out
    }
    seen: map[string]bool
    defer delete(seen)
    #partial switch o in arg(args, 0) {
    case ^Object:
        // ordem da spec (índices, inserção) — antes iterava o map do Odin, sem
        // ordem nenhuma, e esquecia chave que só tem setter
        keys: [dynamic]string
        defer delete(keys)
        own_string_keys(vm, o, &keys, true)
        for k in keys do if !seen[k] { seen[k] = true; append(&out.items, k) }
    case ^Function:
        // aqui as NÃO-enumeráveis contam (é o propósito desta função), então
        // `prototype`/`name`/`length` entram — ao contrário de Object.keys.
        for k in o.props do if !is_non_enumerable_key(k) && !seen[k] { seen[k] = true; append(&out.items, k) }
        for k in ([?]string{"length", "name"}) do if !seen[k] { seen[k] = true; append(&out.items, k) }
    case ^Array:
        keys: [dynamic]string
        defer delete(keys)
        own_keys_any(vm, o, &keys, true)
        for k in keys do if !seen[k] { seen[k] = true; append(&out.items, k) }
        if !seen["length"] { seen["length"] = true; append(&out.items, "length") }
    case string:
        keys: [dynamic]string
        defer delete(keys)
        own_keys_any(vm, o, &keys)
        for k in keys do append(&out.items, k)
        append(&out.items, "length")
    }
    return out
}

// obj.hasOwnProperty(name): true se `name` está nos props PRÓPRIOS (não na cadeia).
@(private = "file")
obj_has_own_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name := key_string(vm, arg(args, 0))
    #partial switch o in this {
    case ^Object:
        if _, has := o.props[name]; has do return true
        if o.getters != nil { if _, has := o.getters[name]; has do return true }
        if o.setters != nil { if _, has := o.setters[name]; has do return true }
    case ^Function:
        // funções têm props próprias (estáticas) + os intrínsecos name/length,
        // e prototype quando não-arrow/não-nativa/não-bound (ver get_member).
        if o.props != nil { if _, has := o.props[name]; has do return true }
        if o.getters != nil { if _, has := o.getters[name]; has do return true }
        if name == "length" || name == "name" do return true
        // bound fns (o.bind_target != nil) NÃO têm prototype própria — o core-js usa
        // exatamente `!boundFn.hasOwnProperty('prototype')` p/ detectar bind nativo.
        if name == "prototype" && !o.is_arrow && !o.non_constructor && o.native == nil && o.bind_target == nil do return true
    case ^Array:
        // índices dentro do range, `length`, e props não-índice (a mais importante:
        // `raw` do array de um template TAGUEADO). O lit-html valida o template com
        // `strings.hasOwnProperty('raw')` e lançava "invalid template strings array".
        if name == "length" do return true
        if o.props != nil { if _, has := o.props[name]; has do return true }
        if len(name) > 0 && len(name) <= 10 {
            all_dig := true
            for c in transmute([]u8)name { if c < '0' || c > '9' { all_dig = false; break } }
            if all_dig {
                n := int(as_number(name))
                return arr_has_index(o, n)
            }
        }
    }
    return false
}

// Object.hasOwn(alvo, chave): delega ao mesmo núcleo de hasOwnProperty.
@(private = "file")
obj_has_own_static :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) < 2 do return false
    return obj_has_own_property(vm, args[0], args[1:2])
}

// Object.groupBy(iterável, fn) → objeto {chave: [itens]} (ES2024).
@(private = "file")
obj_group_by :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_object(vm)
    arr, aok := arg(args, 0).(^Array)
    fn, fok := arg(args, 1).(^Function)
    if !aok || !fok do return out
    for it, i in arr.items {
        k := key_string(vm, call_function(vm, fn, nil, []Value{it, f64(i)}))
        if vm.throwing do return out
        bucket, bok := out.props[k].(^Array)
        if !bok {
            bucket = new_array(vm)
            oput(out, k, bucket)
        }
        append(&bucket.items, it)
    }
    return out
}

// Object.prototype.propertyIsEnumerable(k): aproximação — toda prop PRÓPRIA é
// enumerável no nosso modelo (não distinguimos enumerable:false a não ser em
// getters/setters de defineProperty; suficiente p/ o feature-detect do core-js).
@(private = "file")
obj_property_is_enumerable :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    d := obj_get_own_property_descriptor(vm, nil, []Value{this, arg(args, 0)})
    if desc, ok := d.(^Object); ok do return truthy(desc.props["enumerable"])
    return false
}

// Object.prototype.valueOf(): devolve o próprio objeto.
@(private = "file")
obj_value_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return this
}

// Object.prototype.isPrototypeOf(v): `this` está na cadeia de protótipos de v?
@(private = "file")
obj_is_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    v, vok := arg(args, 0).(^Object)
    if !vok do return false
    if target, ok := this.(^Object); ok {
        for cur := v.proto; cur != nil; cur = cur.proto do if cur == target do return true
        return false
    }
    // `this` não é ^Object (array/função/regex/coleção): só pode casar com o protótipo
    // EXÓTICO do fim da cadeia — `arr.isPrototypeOf(Object.create(arr))`. Identidade de
    // ponteiro, como o `===` do JS.
    if x := proto_exotic_end(v); x != nil do return x == this
    return false
}
