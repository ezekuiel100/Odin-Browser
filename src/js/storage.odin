package js

import "core:strings"

// ── Web Storage API: localStorage / sessionStorage ───────────────────────────
// Armazém chave→valor de STRINGS, EM MEMÓRIA (não persiste em disco; cada vm
// começa vazio, e localStorage/sessionStorage compartilham o mesmo tempo de vida
// do vm — sem a distinção real de sessão/persistência). Mantém ORDEM DE INSERÇÃO
// para key(i)/length/Object.keys/for-in.
//
// Exposto como um Object EXÓTICO (como os wrappers de DOM/Proxy): os hooks
// get/set interceptam acesso por propriedade — `localStorage.foo` lê o item,
// `localStorage.foo = x` grava — além de expor getItem/setItem/removeItem/clear/
// key (não-enumeráveis) e `length`. Chaves e valores são coeridos a string (ToString).

Storage :: struct {
    keys: [dynamic]string, // donas (clonadas)
    vals: [dynamic]string, // donas (clonadas); paralelo a keys por índice
}

@(private = "file")
storage_index :: proc(st: ^Storage, key: string) -> int {
    for k, i in st.keys do if k == key do return i
    return -1
}

// setItem: sobrescreve o valor (libera o antigo) ou insere um par novo (clona ambos).
@(private = "file")
storage_put :: proc(st: ^Storage, key, val: string) {
    if i := storage_index(st, key); i >= 0 {
        delete(st.vals[i])
        st.vals[i] = strings.clone(val)
        return
    }
    append(&st.keys, strings.clone(key))
    append(&st.vals, strings.clone(val))
}

@(private = "file")
storage_del :: proc(st: ^Storage, key: string) {
    if i := storage_index(st, key); i >= 0 {
        delete(st.keys[i]); delete(st.vals[i])
        ordered_remove(&st.keys, i)
        ordered_remove(&st.vals, i)
    }
}

@(private = "file")
storage_clear_all :: proc(st: ^Storage) {
    for k in st.keys do delete(k)
    for v in st.vals do delete(v)
    clear(&st.keys); clear(&st.vals)
}

// Liberação no vm_destroy.
storage_free :: proc(st: ^Storage) {
    storage_clear_all(st)
    delete(st.keys); delete(st.vals)
}

// remoção por `delete localStorage.foo` (chamado do case .Delete no interp).
storage_remove_key :: proc(o: ^Object, key: string) {
    if o.host != nil do storage_del(cast(^Storage) o.host, key)
}

@(private = "file")
storage_of :: proc(this: Value) -> ^Storage {
    if o, ok := this.(^Object); ok && o.host != nil do return cast(^Storage) o.host
    return nil
}

// ToString(v) num buffer temporário; devolve a view (o chamador clona se precisar).
@(private = "file")
to_str_view :: proc(v: Value, sb: ^strings.Builder) -> string {
    to_text(sb, v)
    return strings.to_string(sb^)
}

// ── métodos ──────────────────────────────────────────────────────────────────

@(private = "file")
native_storage_get_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := storage_of(this); if st == nil do return JS_Null{}
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    key := to_str_view(arg(args, 0), &sb)
    if i := storage_index(st, key); i >= 0 do return own_str(vm, st.vals[i])
    return JS_Null{} // ausente → null (não undefined)
}

@(private = "file")
native_storage_set_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := storage_of(this); if st == nil do return nil
    kb: strings.Builder; strings.builder_init(&kb); defer strings.builder_destroy(&kb)
    vb: strings.Builder; strings.builder_init(&vb); defer strings.builder_destroy(&vb)
    key := to_str_view(arg(args, 0), &kb)
    val := to_str_view(arg(args, 1), &vb)
    storage_put(st, key, val)
    return nil
}

@(private = "file")
native_storage_remove_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := storage_of(this); if st == nil do return nil
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    storage_del(st, to_str_view(arg(args, 0), &sb))
    return nil
}

@(private = "file")
native_storage_clear :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if st := storage_of(this); st != nil do storage_clear_all(st)
    return nil
}

@(private = "file")
native_storage_key :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := storage_of(this); if st == nil do return JS_Null{}
    idx := as_int(arg(args, 0))
    if idx >= 0 && idx < len(st.keys) do return own_str(vm, st.keys[idx])
    return JS_Null{} // fora do intervalo → null
}

// ── hooks get/set (package-visible: own_enum_keys e o case .Delete os detectam) ──

storage_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    st := cast(^Storage) o.host
    switch name {
    case "getItem", "setItem", "removeItem", "clear", "key":
        if v, ok := o.props[name]; ok do return v, true
        return nil, true
    case "length":
        return f64(len(st.keys)), true
    }
    if i := storage_index(st, name); i >= 0 do return own_str(vm, st.vals[i]), true
    return nil, false // nem chave nem método → fluxo normal (hasOwnProperty via proto etc.)
}

storage_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> (handled: bool) {
    st := cast(^Storage) o.host
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    storage_put(st, name, to_str_view(val, &sb))
    return true
}

// Cria o Object exótico ligado a `st`. Os métodos ficam em props MAS ocultos
// (não-enumeráveis) p/ que Object.keys/for-in devolvam só as chaves armazenadas
// (own_enum_keys trata o storage à parte de qualquer forma).
make_storage :: proc(vm: ^Interp, st: ^Storage) -> ^Object {
    o := new_object(vm)
    o.host = rawptr(st)
    o.get = storage_get
    o.set = storage_set
    put :: proc(vm: ^Interp, o: ^Object, name: string, fn: Native_Fn) {
        o.props[name] = mk_native(vm, fn)
        mark_non_enumerable(o, name)
    }
    put(vm, o, "getItem",    native_storage_get_item)
    put(vm, o, "setItem",    native_storage_set_item)
    put(vm, o, "removeItem", native_storage_remove_item)
    put(vm, o, "clear",      native_storage_clear)
    put(vm, o, "key",        native_storage_key)
    return o
}
