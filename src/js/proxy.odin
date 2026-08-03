package js

import "core:fmt"
import "core:strconv"
import "core:strings"

// Proxy e Reflect (M67). Base da reatividade do Vue 3 (`reactive()` = Proxy com
// traps get/set/has/deleteProperty/ownKeys que chamam Reflect.* no alvo).
//
// REPRESENTAÇÃO: um proxy É um ^Object comum com px_handler != nil e os hooks
// get/set apontando p/ proxy_get/proxy_set. Assim get_member/set_member/get_index/
// set_index já roteiam pelo proxy sem o núcleo saber (mesma mecânica dos wrappers
// de DOM). `in`, `delete` e ownKeys (for-in/Object.keys) NÃO passam pelos hooks —
// são interceptados manualmente em js_in, .Delete e own_enum_keys.
//
// APROXIMAÇÕES conscientes: sem revoke; apply/construct traps não implementados
// (Vue reactive não os usa); ownKeys usa o conjunto de chaves do alvo (o efeito
// de rastreio de dependência do trap é pulado — irrelevante p/ a 1ª renderização).

// ── leitura/escrita default (sem trap): honra índices de array ───────────────
// get_member ignora índices numéricos em ^Array (isso é papel de get_index), então
// o default de um proxy precisa usar get_index/set_index, não get_member direto.
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
    trap := get_member(vm, o.px_handler, "get")
    if fn, ok := trap.(^Function); ok {
        // trap.get(target, key, receiver) — receiver é o próprio proxy
        return call_function(vm, fn, o.px_handler, []Value{o.px_target, own_str(vm, name), o}), true
    }
    return proxy_default_get(vm, o.px_target, name), true
}

// Hook de escrita (Prop_Set): sempre "handled".
proxy_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    trap := get_member(vm, o.px_handler, "set")
    if fn, ok := trap.(^Function); ok {
        // trap.set(target, key, value, receiver)
        call_function(vm, fn, o.px_handler, []Value{o.px_target, own_str(vm, name), val, o})
        return true
    }
    proxy_default_set(vm, o.px_target, name, val)
    return true
}

// `key in proxy` → trap `has` (ou Reflect.has default no alvo).
proxy_has :: proc(vm: ^Interp, o: ^Object, key: string) -> bool {
    trap := get_member(vm, o.px_handler, "has")
    if fn, ok := trap.(^Function); ok {
        return truthy(call_function(vm, fn, o.px_handler, []Value{o.px_target, own_str(vm, key)}))
    }
    return js_in(vm, key, o.px_target)
}

// `delete proxy[key]` → trap `deleteProperty` (ou remoção default no alvo).
proxy_delete :: proc(vm: ^Interp, o: ^Object, key: string) {
    trap := get_member(vm, o.px_handler, "deleteProperty")
    if fn, ok := trap.(^Function); ok {
        call_function(vm, fn, o.px_handler, []Value{o.px_target, own_str(vm, key)})
        return
    }
    reflect_delete_target(o.px_target, key)
}

// ── construtor Proxy + objeto Reflect ────────────────────────────────────────

install_proxy :: proc(vm: ^Interp) {
    env_define(vm.global, "Proxy", mk_native(vm, proxy_ctor))

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
    h, _ := handler.(^Object)
    p := new_object(vm)
    p.px_target = target
    p.px_handler = h
    p.get = proxy_get
    p.set = proxy_set
    return p
}

// alvo/handler de um Proxy devem ser "objetos" (^Object/^Array/^Function).
@(private = "file")
is_object_like :: proc(v: Value) -> bool {
    #partial switch _ in v {
    case ^Object, ^Array, ^Function: return true
    }
    return false
}

// ── Reflect.* ─────────────────────────────────────────────────────────────────

@(private = "file")
reflect_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return get_index(vm, arg(args, 0), key_string(vm, arg(args, 1)))
}

@(private = "file")
reflect_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    name := key_string(vm, arg(args, 1))
    val := arg(args, 2)
    // Proxy: Reflect.set devolve ToBoolean(resultado do trap set) — antes ignorava
    // o retorno do trap e devolvia sempre true.
    if o, ok := target.(^Object); ok && o.px_handler != nil {
        if fn, fok := get_member(vm, o.px_handler, "set").(^Function); fok {
            r := call_function(vm, fn, o.px_handler, []Value{o.px_target, own_str(vm, name), val, o})
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
    reflect_delete_target(arg(args, 0), key_string(vm, arg(args, 1)))
    return true
}

// remoção default de uma chave do alvo (Reflect.deleteProperty / trap ausente).
@(private = "file")
reflect_delete_target :: proc(target: Value, key: string) {
    #partial switch t in target {
    case ^Object:
        if .Configurable in prop_attrs(t, key) do oremove(t, key)
    case ^Array:
        if idx, ok := strconv.parse_int(key); ok && idx >= 0 && idx < len(t.items) {
            t.items[idx] = nil
        }
    }
}

@(private = "file")
reflect_own_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    #partial switch t in arg(args, 0) {
    case ^Object:
        keys: [dynamic]string
        defer delete(keys)
        own_enum_keys(t, &keys)
        for k in keys do append(&out.items, own_str(vm, k))
    case ^Array:
        for i in 0 ..< len(t.items) do append(&out.items, own_str(vm, fmt.tprintf("%d", i)))
        append(&out.items, own_str(vm, "length"))
    }
    return out
}

@(private = "file")
reflect_get_prototype_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // Mesma semântica do Object.getPrototypeOf (inclusive p/ FUNÇÃO/classe, cujo
    // [[Prototype]] é a superclasse) — divergir dele fazia `Reflect.getPrototypeOf(
    // Classe)` devolver null onde o Object.* acertava.
    return obj_get_prototype_of(vm, this, args)
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
    if trap, tok := get_member(vm, p.px_handler, "construct").(^Function); tok {
        list := new_array(vm)
        for a in args do append(&list.items, a)
        nt: Value = new_target
        if nt == nil do nt = p // newTarget default = o próprio proxy
        return call_function(vm, trap, p.px_handler, []Value{p.px_target, list, nt})
    }
    // sem trap: constrói o ALVO (comportamento default da spec)
    if tfn, fok := p.px_target.(^Function); fok {
        return construct_object(vm, tfn, args, new_target)
    }
    throw_type_error(vm, "Proxy target is not a constructor")
    return nil
}

// É construtor? Função de usuário/classe sim; nativa que constrói também; Proxy
// cujo alvo é construtor idem. Métodos de Function.prototype (call/apply/bind) e
// afins NÃO são — mas não distinguimos isso hoje, então só rejeitamos o que
// claramente não é função.
@(private = "file")
is_constructor_like :: proc(vm: ^Interp, v: Value) -> bool {
    #partial switch t in v {
    case ^Function: return true
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
