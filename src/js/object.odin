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
    vm.object_methods["hasOwnProperty"] = mk_native(vm, obj_has_own_property)
    // Restante do Object.prototype que libs acessam via `{}.metodo` ou uncurryThis
    // (core-js: `l={}.propertyIsEnumerable; l.call(...)` — sem isto, `reading 'call'`
    // de undefined matava o bundle → página em branco).
    vm.object_methods["propertyIsEnumerable"] = mk_native(vm, obj_property_is_enumerable)
    vm.object_methods["isPrototypeOf"]        = mk_native(vm, obj_is_prototype_of)
    vm.object_methods["valueOf"]              = mk_native(vm, obj_value_of)

    // `Object` é uma função (chamável: `new Object()`) que carrega os estáticos
    // nos seus props (get_member lê props de ^Function).
    ctor := mk_native(vm, obj_ctor)
    ctor.name = "Object"
    ctor.props = make(map[string]Value)
    ctor.props["keys"]            = mk_native(vm, obj_keys)
    ctor.props["values"]          = mk_native(vm, obj_values)
    ctor.props["entries"]         = mk_native(vm, obj_entries)
    ctor.props["assign"]          = mk_native(vm, obj_assign)
    ctor.props["create"]          = mk_native(vm, obj_create)
    ctor.props["freeze"]          = mk_native(vm, obj_freeze)
    ctor.props["getPrototypeOf"]  = mk_native(vm, obj_get_prototype_of)
    ctor.props["defineProperty"]  = mk_native(vm, obj_define_property)
    ctor.props["defineProperties"] = mk_native(vm, obj_define_properties)
    ctor.props["getOwnPropertyDescriptor"] = mk_native(vm, obj_get_own_property_descriptor)
    ctor.props["getOwnPropertyNames"]      = mk_native(vm, obj_get_own_property_names)
    ctor.props["fromEntries"]     = mk_native(vm, obj_from_entries)
    ctor.props["setPrototypeOf"]  = mk_native(vm, obj_set_prototype_of)
    ctor.props["is"]              = mk_native(vm, obj_is)
    // Família de integridade/extensibilidade. Desde o M164 são REAIS (antes seal e
    // preventExtensions eram no-op e isSealed era um apelido de isFrozen): o objeto
    // tem `non_extensible` e cada prop tem writable/enumerable/configurable.
    ctor.props["isExtensible"]      = mk_native(vm, obj_is_extensible)
    ctor.props["isFrozen"]          = mk_native(vm, obj_is_frozen)
    ctor.props["isSealed"]          = mk_native(vm, obj_is_sealed)
    ctor.props["preventExtensions"] = mk_native(vm, obj_prevent_extensions)
    ctor.props["seal"]              = mk_native(vm, obj_seal)
    ctor.props["getOwnPropertyDescriptors"] = mk_native(vm, obj_get_own_property_descriptors)
    ctor.props["getOwnPropertySymbols"]     = mk_native(vm, obj_get_own_property_symbols)
    // Object.hasOwn(o,k) (ES2022) — 3 sites do corpus. É hasOwnProperty com o
    // receptor como 1º argumento (a forma recomendada hoje).
    ctor.props["hasOwn"]  = mk_native(vm, obj_has_own_static)
    ctor.props["groupBy"] = mk_native(vm, obj_group_by) // ES2024
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
            for e in src.entries do oput(o, key_string(vm, e.key), e.val)
        }
    }
    return o
}

// Object.setPrototypeOf(obj, proto): religa a cadeia (base da herança ES5
// transpilada — Babel/TS usam em _inherits). proto null desliga.
@(private = "file")
obj_set_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // ALVO FUNÇÃO: `Object.setPrototypeOf(Filha, Pai)` é exatamente o que o
    // `_inherits` do Babel emite p/ classe derivada, e era NO-OP aqui — o
    // `_getPrototypeOf(Derived)` seguinte devolvia Function.prototype (um objeto
    // comum) e o `Reflect.construct(Super, args, NewTarget)` do `_createSuper`
    // morria com "target is not a constructor" → React desmontava a árvore →
    // npmjs.com em BRANCO. O elo mora em `super_ctor`, que é de onde o
    // obj_get_prototype_of já lê e por onde a herança ESTÁTICA já anda.
    if f, fok := arg(args, 0).(^Function); fok {
        #partial switch p in arg(args, 1) {
        case ^Function: f.super_ctor = p
        case JS_Null:   f.super_ctor = nil
        }
        return f
    }
    o, ok := arg(args, 0).(^Object)
    if !ok do return arg(args, 0)
    // Só null e um objeto de verdade mexem na cadeia — `undefined`/número é no-op
    // (a spec lança ali), e quem filtra é o set_proto_value.
    set_proto_value(o, arg(args, 1))
    return o
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
        return own_str(vm, "[object Object]")
    }
    return own_str(vm, "[object Undefined]") // nil = undefined
}

// Object() / new Object(x): sem arg ou nulo => objeto vazio; com objeto/array
// existente => devolve o próprio (identidade, como no JS).
@(private = "file")
obj_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := arg(args, 0)
    #partial switch _ in a {
    case ^Object, ^Array, ^Function:
        return a
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
own_keys_any :: proc(vm: ^Interp, v: Value, out: ^[dynamic]string) {
    #partial switch x in v {
    case ^Object:
        own_enum_keys(x, out)
    case ^Function:
        // `prototype`/`name`/`length` são próprias mas NÃO-enumeráveis (spec) —
        // só as que o autor pôs devem aparecer. ⚠️ isso esconde um `f.length = 5`
        // explícito; é o preço de não termos atributos de propriedade em Function.
        for k in x.props {
            if is_non_enumerable_key(k) do continue
            switch k {
            case "prototype", "name", "length", "caller", "arguments": continue
            }
            append(out, k)
        }
    case ^Array:
        for i in 0 ..< len(x.items) {
            s, _ := v_to_key_string(vm, f64(i))
            append(out, s)
        }
        for k in x.props do if !is_non_enumerable_key(k) do append(out, k)
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
    o, ok := target.(^Object)
    if !ok do return out
    seen: map[string]bool
    defer delete(seen)
    add_key :: proc(vm: ^Interp, target: Value, out: ^Object, seen: ^map[string]bool, key: string) {
        if is_non_enumerable_key(key) || seen[key] do return
        seen[key] = true
        d := obj_get_own_property_descriptor(vm, nil, []Value{target, key})
        if d != nil do oput(out, key, d)
    }
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
    for k in o.korder do if _, alive := o.props[k]; alive do emit(vm, out, &seen, k)
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
    obj_set_prototype_of(vm, nil, []Value{this, arg(args, 0)})
    return nil // o setter não devolve valor (spec)
}

obj_get_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
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
    if _, ok := arg(args, 0).(^Array); ok {
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
apply_descriptor :: proc(vm: ^Interp, o: ^Object, key: string, desc: ^Object) {
    // Prop já existente e NÃO-configurável: a spec manda TypeError. Ignoramos em
    // silêncio (mesma política sloppy da escrita), o que preserva o invariante sem
    // derrubar código que redefine defensivamente.
    _, existed := o.props[key]
    if existed && .Configurable not_in prop_attrs(o, key) do return
    has_get, has_set := false, false
    if g, ok := desc.props["get"]; ok {
        if fn, fok := g.(^Function); fok {
            if o.getters == nil do o.getters = make(map[string]^Function)
            o.getters[key] = fn
            has_get = true
        }
    }
    if s, ok := desc.props["set"]; ok {
        if fn, fok := s.(^Function); fok {
            if o.setters == nil do o.setters = make(map[string]^Function)
            o.setters[key] = fn
            has_set = true
        }
    }
    if has_get || has_set {
        oremove(o, key) // accessor vence: sem data-prop residual
    } else if v, has_value := desc.props["value"]; has_value {
        oput(o, key, v)
    }

    // Numa prop NOVA os três atributos omitidos valem false (spec); numa
    // redefinição, o que não veio no descritor fica como estava.
    a := prop_attrs(o, key) if existed else Prop_Attrs{}
    if e, ok := desc.props["enumerable"];   ok do a = truthy(e) ? a + {.Enumerable}   : a - {.Enumerable}
    if w, ok := desc.props["writable"];     ok do a = truthy(w) ? a + {.Writable}     : a - {.Writable}
    if c, ok := desc.props["configurable"]; ok do a = truthy(c) ? a + {.Configurable} : a - {.Configurable}
    set_prop_attrs(o, key, a)
}

// Object.defineProperty(obj, key, descriptor) — devolve obj.
// package-visible: Reflect.defineProperty (proxy.odin) delega aqui.
obj_define_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // Alvo FUNÇÃO/construtor: libs fazem `Object.defineProperty(MyClass, k, ...)` e
    // o core-js define símbolos bem-conhecidos em `Symbol` (que é ^Function) e relê
    // o descritor. Sem isto o define no-opava → getOwnPropertyDescriptor devolvia
    // undefined → "reading 'enumerable' of undefined". Função não tem `hidden`
    // (enumerabilidade não é modelada nela) — grava value/get/set e pronto.
    if fn, fok := arg(args, 0).(^Function); fok {
        key := key_string(vm, arg(args, 1))
        if desc, dok := arg(args, 2).(^Object); dok {
            got := false
            if g, ok := desc.props["get"].(^Function); ok { if fn.getters == nil do fn.getters = make(map[string]^Function); fn.getters[key] = g; got = true }
            if s, ok := desc.props["set"].(^Function); ok { if fn.setters == nil do fn.setters = make(map[string]^Function); fn.setters[key] = s; got = true }
            if v, has := desc.props["value"]; has && !got { if fn.props == nil do fn.props = make(map[string]Value); fn.props[key] = v }
        }
        return fn
    }
    o, ok := arg(args, 0).(^Object)
    if !ok {
        // arrays são objetos → passam adiante (define limitado, mas sem throw);
        // primitivos (undefined/null/número/string/bool) → TypeError (spec).
        if _, aok := arg(args, 0).(^Array); aok do return arg(args, 0)
        throw_type_error(vm, "Object.defineProperty called on non-object")
        return nil
    }
    key := key_string(vm, arg(args, 1))
    if desc, dok := arg(args, 2).(^Object); dok do apply_descriptor(vm, o, key, desc)
    return o
}

// Object.defineProperties(obj, {k1: desc1, ...}) — devolve obj.
@(private = "file")
obj_define_properties :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok do return arg(args, 0)
    apply_descriptors(vm, o, arg(args, 1)) // MESMA regra do Object.create (ver lá)
    return o
}

// Object.getOwnPropertyDescriptor(obj, key) — descritor ou undefined (nil).
// package-visible: Reflect.getOwnPropertyDescriptor (proxy.odin) delega aqui.
obj_get_own_property_descriptor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // Alvo FUNÇÃO/construtor (Symbol, MyClass, ...): lê value/get/set das props/
    // getters/setters estáticos. enumerable/configurable = true (aproximação:
    // função não modela enumerabilidade). Espelha o defineProperty acima.
    if fn, fok := arg(args, 0).(^Function); fok {
        key := key_string(vm, arg(args, 1))
        if fn.getters != nil { if g, ok := fn.getters[key]; ok {
            d := new_object(vm); d.props["get"] = g; d.props["set"] = nil
            if fn.setters != nil { if s, sok := fn.setters[key]; sok do d.props["set"] = s }
            d.props["enumerable"] = true; d.props["configurable"] = true; return d
        }}
        if fn.setters != nil { if s, ok := fn.setters[key]; ok {
            d := new_object(vm); d.props["get"] = nil; d.props["set"] = s
            d.props["enumerable"] = true; d.props["configurable"] = true; return d
        }}
        if fn.props != nil { if v, ok := fn.props[key]; ok {
            d := new_object(vm); d.props["value"] = v; d.props["writable"] = true
            d.props["enumerable"] = true; d.props["configurable"] = true; return d
        }}
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
            d.props["get"] = g
            d.props["set"] = nil
            if o.setters != nil { if s, sok := o.setters[key]; sok do d.props["set"] = s }
            d.props["enumerable"] = enumerable
            d.props["configurable"] = configurable
            return d
        }
    }
    if o.setters != nil {
        if s, sok := o.setters[key]; sok {
            d := new_object(vm)
            d.props["get"] = nil
            d.props["set"] = s
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
    seen: map[string]bool
    defer delete(seen)
    #partial switch o in arg(args, 0) {
    case ^Object:
        for k in o.props do if !is_non_enumerable_key(k) && !seen[k] { seen[k] = true; append(&out.items, k) }
        if o.getters != nil do for k in o.getters do if !is_non_enumerable_key(k) && !seen[k] { seen[k] = true; append(&out.items, k) }
    case ^Function:
        // aqui as NÃO-enumeráveis contam (é o propósito desta função), então
        // `prototype`/`name`/`length` entram — ao contrário de Object.keys.
        for k in o.props do if !is_non_enumerable_key(k) && !seen[k] { seen[k] = true; append(&out.items, k) }
        for k in ([?]string{"length", "name"}) do if !seen[k] { seen[k] = true; append(&out.items, k) }
    case ^Array:
        keys: [dynamic]string
        defer delete(keys)
        own_keys_any(vm, o, &keys)
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
        if name == "prototype" && !o.is_arrow && o.native == nil && o.bind_target == nil do return true
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
                return n >= 0 && n < len(o.items)
            }
        }
    case ^Collection:
        if name == "size" do return true
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
    o, ok := this.(^Object)
    if !ok do return false
    name := key_string(vm, arg(args, 0))
    if _, has := o.props[name]; !has do return false
    return .Enumerable in prop_attrs(o, name) // era `true` p/ toda prop própria
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
