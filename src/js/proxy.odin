package js

import "core:fmt"
import "core:strconv"
import "core:strings"

// Proxy e Reflect (M67). Base da reatividade do Vue 3 (`reactive()` = Proxy com
// traps get/set/has/deleteProperty/ownKeys que chamam Reflect.* no alvo).
//
// Function proxies share Object state with their revoker.

@(private = "file")
proxy_default_get :: proc(vm: ^Interp, target: Value, name: string) -> Value {
    return get_index(vm, target, name)
}

@(private = "file")
proxy_default_set :: proc(vm: ^Interp, target: Value, name: string, val: Value) {
    set_index(vm, target, name, val)
}

// ── traps ────────────────────────────────────────────────────────────────────

// Hook de leitura (Prop_Get): sempre "handled" — um proxy nunca cai no fallback.
proxy_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if !proxy_live(vm, o) do return nil, true

    if fn, ok := proxy_trap(vm, o, "get"); ok {
        // trap.get(target, key, receiver) — receiver é o próprio proxy
        return call_function(vm, fn, o.px_handler, []Value{o.px_target, proxy_key_value(vm, name), o.px_self}), true
    }
    if vm.throwing do return nil, true
    return get_with_receiver(vm, o.px_target, name, o.px_self), true
}

// Hook de escrita (Prop_Set): sempre "handled".
proxy_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    if !proxy_live(vm, o) do return true

    if fn, ok := proxy_trap(vm, o, "set"); ok {
        // trap.set(target, key, value, receiver)
        call_function(vm, fn, o.px_handler, []Value{o.px_target, proxy_key_value(vm, name), val, o.px_self})
        return true
    }
    if vm.throwing do return true
    proxy_default_set(vm, o.px_target, name, val)
    return true
}

// `key in proxy` → trap `has` (ou Reflect.has default no alvo).
proxy_has :: proc(vm: ^Interp, o: ^Object, key: string) -> bool {
    if !proxy_live(vm, o) do return false

    if fn, ok := proxy_trap(vm, o, "has"); ok {
        return truthy(call_function(vm, fn, o.px_handler, []Value{o.px_target, proxy_key_value(vm, key)}))
    }
    if vm.throwing do return false
    return js_in(vm, key, o.px_target)
}

// `delete proxy[key]` → trap `deleteProperty` (ou remoção default no alvo).
proxy_delete :: proc(vm: ^Interp, o: ^Object, key: string) {
    if !proxy_live(vm, o) do return

    if fn, ok := proxy_trap(vm, o, "deleteProperty"); ok {
        result := call_function(vm, fn, o.px_handler, []Value{o.px_target, proxy_key_value(vm, key)})
        if vm.throwing || !truthy(result) do return
        desc := obj_get_own_property_descriptor(vm, nil, []Value{o.px_target, proxy_key_value(vm, key)})
        if vm.throwing || desc == nil do return
        configurable := truthy(get_member(vm, desc, "configurable"))
        if vm.throwing do return
        extensible := proxy_target_extensible(vm, o.px_target)
        if vm.throwing do return
        if !configurable || !extensible do throw_type_error(vm, "deleteProperty trap cannot hide a protected target property")
        return
    }
    if vm.throwing do return
    delete_property_value(vm, o.px_target, key, false)
}

// ── construtor Proxy + objeto Reflect ────────────────────────────────────────

install_proxy :: proc(vm: ^Interp) {
    ctor := mk_native(vm, proxy_ctor)
    ctor.props = make(map[string]Value)
    ctor.props["revocable"] = mk_native(vm, proxy_revocable)
    env_define(vm.global, "Proxy", ctor)

    reflect := new_object(vm)
    reflect.props = make(map[string]Value)
    reflect.props["get"]            = mk_native(vm, reflect_get)
    reflect.props["set"]            = mk_native(vm, reflect_set)
    reflect.props["has"]            = mk_native(vm, reflect_has)
    reflect.props["deleteProperty"] = mk_native(vm, reflect_delete_property)
    reflect.props["ownKeys"]        = mk_native(vm, reflect_own_keys)
    reflect.props["getPrototypeOf"] = mk_native(vm, reflect_get_prototype_of)
    reflect.props["defineProperty"] = mk_native(vm, reflect_define_property)
    reflect.props["getOwnPropertyDescriptor"] = mk_native(vm, reflect_get_own_property_descriptor)
    reflect.props["apply"]          = mk_native(vm, reflect_apply)
    reflect.props["construct"]      = mk_native(vm, reflect_construct)
    env_define(vm.global, "Reflect", reflect)
}

@(private = "file")
proxy_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    handler := arg(args, 1)
    if !is_object_like(target) || !is_object_like(handler) {
        throw_type_error(vm, "Cannot create proxy with a non-object as target or handler")
        return nil
    }
    p := new_object(vm)
    p.px_target = target
    p.px_handler = handler
    p.get = proxy_get
    p.set = proxy_set
    p.px_self = p
    if _, callable := target.(^Function); callable {
        f := new_function(vm)
        f.proxy = p
        p.px_self = f
        return f
    }
    return p
}

// alvo/handler de um Proxy devem ser "objetos" (^Object/^Array/^Function).
@(private = "file")
is_object_like :: proc(v: Value) -> bool {
    #partial switch _ in v {
    case ^Object, ^Array, ^Function, ^Regex, ^Collection: return true
    }
    return false
}

// ── Reflect.* ─────────────────────────────────────────────────────────────────

@(private = "file")
reflect_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    receiver := target
    if len(args) >= 3 do receiver = args[2]
    return get_with_receiver(vm, target, key_string(vm, arg(args, 1)), receiver)
}

@(private = "file")
reflect_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    name := key_string(vm, arg(args, 1))
    val := arg(args, 2)
    // Proxy: Reflect.set devolve ToBoolean(resultado do trap set) — antes ignorava
    // o retorno do trap e devolvia sempre true.
    if o := proxy_state(target); o != nil {
        if !proxy_live(vm, o) do return nil
        if fn, fok := get_member(vm, o.px_handler, "set").(^Function); fok {
            r := call_function(vm, fn, o.px_handler, []Value{o.px_target, proxy_key_value(vm, name), val, o.px_self})
            if vm.throwing do return nil
            return truthy(r)
        }
        proxy_default_set(vm, o.px_target, name, val)
        return true
    }
    set_index(vm, target, name, val)
    return true
}

@(private = "file")
reflect_has :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return js_in(vm, key_string(vm, arg(args, 1)), arg(args, 0))
}

@(private = "file")
reflect_delete_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p := proxy_state(arg(args, 0)); p != nil {
        proxy_delete(vm, p, key_string(vm, arg(args, 1)))
        return !vm.throwing
    }
    return delete_property_value(vm, arg(args, 0), key_string(vm, arg(args, 1)), false)
}

@(private = "file")
reflect_own_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    keys: [dynamic]string
    defer delete(keys)
    if p := proxy_state(arg(args, 0)); p != nil {
        proxy_keys(vm, p, &keys, true)
    } else {
        reflect_target_keys(vm, arg(args, 0), &keys)
    }
    for k in keys {
        if sym, ok := vm.symbol_keys[k]; ok { append(&out.items, sym) }
        else { append(&out.items, own_str(vm, k)) }
    }
    return out
}

@(private = "file")
reflect_get_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_primitive(arg(args, 0)) {
        throw_type_error(vm, "Reflect.getPrototypeOf requires an object")
        return nil
    }
    // Mesma semântica do Object.getPrototypeOf (inclusive p/ FUNÇÃO/classe, cujo
    // [[Prototype]] é a superclasse) — divergir dele fazia `Reflect.getPrototypeOf(
    // Classe)` devolver null onde o Object.* acertava.
    return obj_get_prototype_of(vm, this, args)
}

proxy_get_prototype_of :: proc(vm: ^Interp, p: ^Object) -> Value {
    trap, found := proxy_trap(vm, p, "getPrototypeOf")
    if vm.throwing do return nil
    if !found do return obj_get_prototype_of(vm, nil, []Value{p.px_target})
    proto := call_function(vm, trap, p.px_handler, []Value{p.px_target})
    if vm.throwing do return nil
    if proto != (JS_Null{}) && is_primitive(proto) {
        throw_type_error(vm, "getPrototypeOf trap must return an object or null")
        return nil
    }
    target := p.px_target
    for inner := proxy_state(target); inner != nil; inner = proxy_state(target) {
        if !proxy_live(vm, inner) do return nil
        target = inner.px_target
    }
    extensible := true
    #partial switch t in target {
    case ^Object: extensible = !t.non_extensible
    case ^Array: extensible = !t.sealed && !t.frozen
    }
    if !extensible {
        actual := obj_get_prototype_of(vm, nil, []Value{p.px_target})
        if vm.throwing do return nil
        if proto != actual {
            throw_type_error(vm, "getPrototypeOf trap disagrees with a non-extensible target")
            return nil
        }
    }
    return proto
}

// Reflect.defineProperty/getOwnPropertyDescriptor: delegam à API de Object
// (mesma semântica), devolvendo true no define.
@(private = "file")
reflect_define_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj_define_property(vm, nil, args)
    return true
}

@(private = "file")
reflect_get_own_property_descriptor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return obj_get_own_property_descriptor(vm, nil, args)
}

@(private = "file")
reflect_apply :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    fn, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "Reflect.apply target is not a function"); return nil }
    this_arg := arg(args, 1)
    call_args: [dynamic]Value
    defer delete(call_args)
    if arr, aok := arg(args, 2).(^Array); aok do for it in arr.items do append(&call_args, it)
    return call_function(vm, fn, this_arg, call_args[:])
}

// `new proxy(...)` e Reflect.construct(proxy, …) — trap `construct` (M136).
// Era o que restava do cluster do gap-report DEPOIS do newTarget: instrumentar a
// mensagem mostrou que o alvo não era undefined, era um ^Object sem props próprias —
// a assinatura de um Proxy. Envolver um construtor em Proxy é o idioma de container
// de injeção de dependência e de instrumentação de classe.
proxy_construct :: proc(vm: ^Interp, p: ^Object, args: []Value, new_target: ^Function = nil) -> Value {
    if !proxy_live(vm, p) do return nil
    if !is_constructor_like(vm, p.px_target) { throw_type_error(vm, "Proxy target is not a constructor"); return nil }
    if trap, tok := proxy_trap(vm, p, "construct"); tok {
        list := new_array(vm)
        for a in args do append(&list.items, a)
        nt: Value = new_target
        if new_target == nil do nt = p.px_self // newTarget default = o prÃ³prio proxy
        result := call_function(vm, trap, p.px_handler, []Value{p.px_target, list, nt})
        if !vm.throwing && !is_object_like(result) do throw_type_error(vm, "Proxy construct trap must return an object")
        return result
    }
    // sem trap: constrói o ALVO (comportamento default da spec)
    if vm.throwing do return nil
    if tfn, fok := p.px_target.(^Function); fok {
        nt := new_target
        if nt == nil do nt, _ = p.px_self.(^Function)
        return construct_object(vm, tfn, args, nt)
    }
    throw_type_error(vm, "Proxy target is not a constructor")
    return nil
}

// É construtor? Função de usuário/classe sim; nativa que constrói também; Proxy
// cujo alvo é construtor idem. Métodos de Function.prototype (call/apply/bind) e
// afins NÃO são — mas não distinguimos isso hoje, então só rejeitamos o que
// claramente não é função.
is_constructor_like :: proc(vm: ^Interp, v: Value) -> bool {
    #partial switch t in v {
    case ^Function:
        if t.proxy != nil do return is_constructor_like(vm, t.proxy.px_target)
        return !t.non_constructor && !t.is_arrow && !t.is_async && !t.is_generator
    case ^Object:   return t.px_handler != nil && is_constructor_like(vm, t.px_target)
    }
    return false
}

// Nome do que veio no lugar de um construtor. `typeof` não serve: diria "object"
// tanto p/ `{}` quanto p/ um Proxy, e a distinção é justamente o que orienta o peel.
@(private = "file")
describe_ctor_target :: proc(v: Value) -> string {
    switch t in v {
    case ^Object:
        if t.px_handler != nil do return "um Proxy"
        return "um objeto comum"
    case ^Array:      return "um array"
    case ^Collection: return "um Map/Set"
    case ^Regex:      return "uma regex"
    case ^Symbol:     return "um symbol"
    case ^BigInt:     return "um bigint"
    case ^Function:   return "uma função"
    case JS_Null:     return "null"
    case f64, bool, string: return "um primitivo"
    case:             return "undefined"
    }
}

@(private = "file")
reflect_construct :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // A spec EXIGE (1) um argumentsList que seja objeto e (2) que o newTarget seja
    // construtor — nos dois casos, TypeError. Aceitar tudo em silêncio não era só
    // frouxidão: o core-js DETECTA isso (`fails(function(){ Reflect.construct(fn) })`)
    // e, achando o nativo quebrado, instala o polyfill dele por cima — que então
    // rejeitava construtores nossos com "… is not a constructor" e derrubava o
    // npmjs.com para BLANK. Ser correto aqui faz o polyfill nem se instalar.
    if !is_object_like(arg(args, 1)) {
        throw_type_error(vm, "Reflect.construct: argumentsList deve ser um objeto")
        return nil
    }
    if len(args) >= 3 && !is_constructor_like(vm, arg(args, 2)) {
        throw_type_error(vm, fmt.tprintf("Reflect.construct: newTarget não é construtor (recebeu %s)",
            describe_ctor_target(arg(args, 2))))
        return nil
    }
    call_args: [dynamic]Value
    defer delete(call_args)
    if arr, aok := arg(args, 1).(^Array); aok do for it in arr.items do append(&call_args, it)

    if p, pok := arg(args, 0).(^Object); pok && p.px_handler != nil {
        ntf, _ := arg(args, 2).(^Function)
        return proxy_construct(vm, p, call_args[:], ntf)
    }

    fn, ok := arg(args, 0).(^Function)
    if !ok {
        // Diz O QUE veio: a mensagem genérica não distinguia "undefined" de
        // "objeto/proxy" — e era justamente essa diferença que apontava a raiz.
        throw_type_error(vm, fmt.tprintf("Reflect.construct target is not a constructor (recebeu %s)",
            describe_ctor_target(arg(args, 0))))
        return nil
    }
    // 3º argumento = newTarget: define o prototype da instância e o `new.target` de
    // dentro. É o miolo do `_createSuper` que o Babel emite p/ classe derivada — sem
    // ele, `Reflect.construct(Pai, args, Filha) instanceof Filha` dava false e a
    // subclasse transpilada saía com o prototype errado.
    nt, _ := arg(args, 2).(^Function)
    when #config(MEMBERPROBE, false) {
        fmt.eprintfln("[rcprobe] alvo='%s' nativa=%v nargs=%d newTarget='%s' nt_nativa=%v | pilha: %v",
            fn.name, fn.native != nil, len(call_args), nt != nil ? nt.name : "<nenhum>",
            nt != nil ? nt.native != nil : false, vm.probe_stack)
    }
    return construct_object(vm, fn, call_args[:], nt)
}

proxy_state :: proc(v: Value) -> ^Object {
    if o, ok := v.(^Object); ok && o.px_handler != nil do return o
    if f, ok := v.(^Function); ok do return f.proxy
    return nil
}

proxy_live :: proc(vm: ^Interp, p: ^Object) -> bool {
    if p.px_revoked { throw_type_error(vm, "Cannot perform operation on a revoked proxy"); return false }
    return true
}

// Integrity state of the native target behind forwarding proxies.
proxy_target_extensible :: proc(vm: ^Interp, target: Value) -> bool {
    target := target
    for p := proxy_state(target); p != nil; p = proxy_state(target) {
        if !proxy_live(vm, p) do return false
        target = p.px_target
    }
    #partial switch o in target {
    case ^Object: return !o.non_extensible
    case ^Array: return !o.sealed && !o.frozen
    }
    return true
}

proxy_trap :: proc(vm: ^Interp, p: ^Object, name: string) -> (^Function, bool) {
    if !proxy_live(vm, p) do return nil, false
    trap := get_member(vm, p.px_handler, name)
    if vm.throwing || is_nullish(trap) do return nil, false
    if fn, ok := trap.(^Function); ok do return fn, true
    throw_type_error(vm, "Proxy trap must be callable")
    return nil, false
}

proxy_revocable :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := proxy_ctor(vm, nil, args)
    if vm.throwing do return nil
    revoke := mk_native(vm, proxy_revoke)
    revoke.bound = proxy_state(p)
    out := new_object(vm)
    oput(out, "proxy", p)
    oput(out, "revoke", revoke)
    return out
}

proxy_revoke :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p, ok := vm.native_bound.(^Object); ok do p.px_revoked = true
    return nil
}

proxy_apply :: proc(vm: ^Interp, p: ^Object, this: Value, args: []Value) -> Value {
    if trap, ok := proxy_trap(vm, p, "apply"); ok {
        list := new_array(vm)
        for a in args do append(&list.items, a)
        return call_function(vm, trap, p.px_handler, []Value{p.px_target, this, list})
    }
    if vm.throwing do return nil
    fn, _ := p.px_target.(^Function)
    return call_function(vm, fn, this, args)
}

// Ordinary [[Get]] retains Receiver throughout the prototype chain.
get_with_receiver :: proc(vm: ^Interp, target: Value, name: string, receiver: Value) -> Value {
    if p := proxy_state(target); p != nil {
        if trap, ok := proxy_trap(vm, p, "get"); ok {
            return call_function(vm, trap, p.px_handler, []Value{p.px_target, proxy_key_value(vm, name), receiver})
        }
        if vm.throwing do return nil
        return get_with_receiver(vm, p.px_target, name, receiver)
    }
    if own := native_own_properties(vm, target); own != nil {
        if v, exists := prim_proto_lookup(vm, own, receiver, name); exists do return v
    }
    if proto := native_property_proto(vm, target); proto != nil {
        if v, exists := prim_proto_lookup(vm, proto, receiver, name); exists do return v
    }
    if o, ok := target.(^Object); ok {
        for cur := o; cur != nil; cur = cur.proto {
            if cur != o && cur.px_handler != nil do return get_with_receiver(vm, cur, name, receiver)
            if g, exists := cur.getters[name]; exists {
                if g == nil do return nil
                return call_function(vm, g, receiver, nil)
            }
            if v, exists := cur.props[name]; exists do return v
            if _, exists := cur.setters[name]; exists do return nil
            // Array subclasses keep their own indexed storage in the wrapper.
            // Check it before inherited accessors, using the original Receiver.
            if cur == o {
                if a, wrapped := o.prim.(^Array); wrapped {
                    if name == "length" do return f64(len(a.items))
                    if index, indexed := array_index_name(name); indexed {
                        if v, exists := array_get_own_index(vm, a, index, name, receiver); exists do return v
                    }
                }
            }
        }
    }
    if f, ok := target.(^Function); ok {
        for cur := f; cur != nil; cur = cur.super_ctor {
            if g, exists := cur.getters[name]; exists {
                if g == nil do return nil
                return call_function(vm, g, receiver, nil)
            }
            if v, exists := cur.props[name]; exists do return v
        }
    }
    if a, ok := target.(^Array); ok {
        if index, indexed := array_index_name(name); indexed {
            if v, exists := array_get_own_index(vm, a, index, name, receiver); exists do return v
            proto := obj_get_prototype_of(vm, nil, []Value{a})
            if is_nullish(proto) do return nil
            return get_with_receiver(vm, proto, name, receiver)
        }
        if a.descriptors != nil {
            if g, exists := a.descriptors.getters[name]; exists {
                if g == nil do return nil
                return call_function(vm, g, receiver, nil)
            }
        }
    }
    return get_index(vm, target, name)
}

proxy_keys :: proc(vm: ^Interp, p: ^Object, out: ^[dynamic]string, all: bool) {
    keys: [dynamic]string
    defer delete(keys)
    if trap, ok := proxy_trap(vm, p, "ownKeys"); ok {
        list := call_function(vm, trap, p.px_handler, []Value{p.px_target})
        if vm.throwing do return
        if !is_object_like(list) { throw_type_error(vm, "ownKeys must return an object"); return }
        n := int(as_number(get_member(vm, list, "length")))
        seen: map[string]bool
        defer delete(seen)
        for i in 0 ..< n {
            v := get_index(vm, list, f64(i))
            k: string
            #partial switch v in v {
            case string: k = v
            case ^Symbol: k = symbol_key(vm, v)
            case: throw_type_error(vm, "ownKeys entries must be strings or symbols"); return
            }
            if seen[k] { throw_type_error(vm, "ownKeys returned duplicate keys"); return }
            seen[k] = true
            append(&keys, k)
        }
        target_keys: [dynamic]string
        defer delete(target_keys)
        reflect_target_keys(vm, p.px_target, &target_keys)
        if vm.throwing do return
        extensible := true
        #partial switch target in p.px_target {
        case ^Object: extensible = !target.non_extensible
        case ^Array: extensible = !target.sealed && !target.frozen
        }
        for k in target_keys {
            d := obj_get_own_property_descriptor(vm, nil, []Value{p.px_target, proxy_key_value(vm, k)})
            if vm.throwing do return
            required := !extensible || (d != nil && !truthy(get_member(vm, d, "configurable")))
            if required && !seen[k] { throw_type_error(vm, "ownKeys omitted a required target key"); return }
        }
        if !extensible && len(keys) != len(target_keys) {
            throw_type_error(vm, "ownKeys added keys to a non-extensible target"); return
        }
    } else {
        if vm.throwing do return
        reflect_target_keys(vm, p.px_target, &keys)
    }
    for k in keys {
        if all { append(out, k); continue }
        if is_non_enumerable_key(k) do continue
        d := obj_get_own_property_descriptor(vm, nil, []Value{p.px_self, proxy_key_value(vm, k)})
        if vm.throwing do return
        if d != nil && truthy(get_member(vm, d, "enumerable")) do append(out, k)
    }
}


// Internal own-key list includes non-enumerable strings and symbol keys.
reflect_target_keys :: proc(vm: ^Interp, target: Value, out: ^[dynamic]string) {
    if p := proxy_state(target); p != nil { proxy_keys(vm, p, out, true); return }
    own_keys_any(vm, target, out, true)
    #partial switch t in target {
    case ^Regex, ^Collection:
        if own := native_own_properties(vm, t); own != nil {
            keys: [dynamic]string
            defer delete(keys)
            reflect_target_keys(vm, own, &keys)
            for k in keys do if is_symbol_key(k) { append(out, k) }
        }
    case ^Object:
        seen: map[string]bool
        defer delete(seen)
        for k in t.korder do if is_symbol_key(k) && okey_alive(t, k) { append(out, k); seen[k] = true }
        for k in t.props do if is_symbol_key(k) && !seen[k] { append(out, k); seen[k] = true }
        for k in t.getters do if is_symbol_key(k) && !seen[k] { append(out, k); seen[k] = true }
        for k in t.setters do if is_symbol_key(k) && !seen[k] { append(out, k); seen[k] = true }
    case ^Array:
        append(out, "length")
        for k in t.props do if is_symbol_key(k) do append(out, k)
    case ^Function:
        append(out, "length", "name")
        if !t.is_arrow && !t.non_constructor {
            get_member(vm, t, "prototype")
            append(out, "prototype")
        }
        for k in t.props {
            if k == "length" || k == "name" || k == "prototype" do continue
            present := false
            for old in out^ do if old == k { present = true; break }
            if !present do append(out, k)
        }
    }
}

proxy_key_value :: proc(vm: ^Interp, key: string) -> Value {
    if sym, ok := vm.symbol_keys[key]; ok do return sym
    return own_str(vm, key)
}
