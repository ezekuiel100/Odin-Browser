package js

import "core:strings"

// Map / Set / WeakMap / WeakSet.
//
// Implementação única (^Collection) com um `kind`. Os quatro compartilham o
// armazenamento; cada prototype tem seus próprios métodos e valida o receptor.
// WeakMap/WeakSet também validam as chaves e usam referências fracas. As chaves são
// comparadas por SameValueZero (identidade p/ objetos; valor p/ primitivos; e
// NaN igual a NaN), então objetos servem de chave, como no JS real.
//
// Ordered entries with a hash index; deleted slots keep iteration cursors stable.

Coll_Kind :: enum { Map, Set, Weak_Map, Weak_Set }

Coll_Method :: enum { Set, Get, Add, Has, Delete, Clear, For_Each, Keys, Values, Entries, Size }
COLL_METHOD_STRIDE :: 16

Coll_Iterator :: struct {
    collection: ^Collection,
    source: Value, // retain subclass receiver identity as well as its backing
    cursor: int,
    method: Coll_Method,
    kind: Coll_Kind, // retained after exhaustion for next()'s brand check
}

// Shared storage does not imply shared internal slots. The function's bound
// tag records its required collection kind independently of the receiver.
coll_method_dispatch :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    tag := int(vm.native_bound.(f64))
    kind := Coll_Kind(tag / COLL_METHOD_STRIDE)
    method := Coll_Method(tag % COLL_METHOD_STRIDE)
    c := coll_receiver(this)
    if c == nil || c.kind != kind {
        throw_type_error(vm, "Collection method called on incompatible receiver")
        return nil
    }
    switch method {
    case .Set:
        map_set(vm, c, args)
        if !vm.throwing do return this
    case .Get: return coll_get(vm, c, args)
    case .Add:
        set_add(vm, c, args)
        if !vm.throwing do return this
    case .Has: return coll_has(vm, c, args)
    case .Delete: return coll_delete(vm, c, args)
    case .Clear: return coll_clear(vm, c, args)
    case .For_Each: return coll_for_each(vm, this, args)
    case .Keys: return coll_keys(vm, this, args)
    case .Values: return coll_values(vm, this, args)
    case .Entries: return coll_entries(vm, this, args)
    case .Size: return f64(c.size)
    }
    return nil
}

@(private = "file")
coll_receiver :: proc(this: Value) -> ^Collection {
    if c, ok := this.(^Collection); ok do return c
    if o, ok := this.(^Object); ok && proxy_state(this) == nil {
        if c, has := o.prim.(^Collection); has do return c
    }
    return nil
}

Coll_Entry :: struct {
    dead: bool,
    next: int, // bucket chain, index + 1 (zero terminates)
    key: Value,
    val: Value, // Set/WeakSet: val == key (forEach passa (val, key) iguais)
}

Collection :: struct {
    index: map[u64]int,
    size: int,
    iterating: int,
    kind:    Coll_Kind,
    entries: [dynamic]Coll_Entry,
}

new_collection :: proc(vm: ^Interp, kind: Coll_Kind) -> ^Collection {
    c := new(Collection)
    c.kind = kind
    c.index = make(map[u64]int)
    append(&vm.all_collections, c)
    return c
}

// SameValueZero: primitivos por valor (NaN == NaN), referências por ponteiro.
same_value_zero :: proc(a, b: Value) -> bool {
    switch x in a {
    case f64:        y, ok := b.(f64);        return ok && (x == y || (x != x && y != y))
    case bool:       y, ok := b.(bool);       return ok && x == y
    case string:     y, ok := b.(string);     return ok && x == y
    case JS_Null:    _, ok := b.(JS_Null);    return ok
    case ^Function:  y, ok := b.(^Function);  return ok && x == y
    case ^Object:    y, ok := b.(^Object);    return ok && x == y
    case ^Array:     y, ok := b.(^Array);     return ok && x == y
    case ^Regex:     y, ok := b.(^Regex);     return ok && x == y
    case ^Collection:y, ok := b.(^Collection);return ok && x == y
    case ^Symbol:    y, ok := b.(^Symbol);    return ok && x == y
    case ^BigInt:    y, ok := b.(^BigInt);    return ok && bigint_equals(x, y) // por VALOR (5n é uma só chave)
    case:            return b == nil // undefined == undefined
    }
}

// Índice da entrada com esta chave, ou -1.
coll_find :: proc(c: ^Collection, key: Value) -> int {
    for link := c.index[coll_hash(key)]; link != 0; link = c.entries[link-1].next {
        if same_value_zero(c.entries[link-1].key, key) do return link-1
    }
    return -1
}

// Equal SameValueZero keys must hash alike, including NaNs, signed zero and BigInts.
@(private = "file")
coll_hash :: proc(key: Value) -> u64 {
    h: u64 = 14695981039346656037
    switch x in key {
    case f64:
        if x == 0 do return 0
        if x != x do return 0x7ff8000000000000
        return transmute(u64)x
    case string:
        for b in transmute([]u8)x do h = (h ~ u64(b)) * 1099511628211
    case ^BigInt:
        h = u64(x.val.sign)
        for i in 0..<x.val.used do h = (h ~ u64(x.val.digit[i])) * 1099511628211
    case bool: return 1 if x else 2
    case JS_Null: return 3
    case ^Function: return u64(uintptr(x))
    case ^Object: return u64(uintptr(x))
    case ^Array: return u64(uintptr(x))
    case ^Regex: return u64(uintptr(x))
    case ^Collection: return u64(uintptr(x))
    case ^Symbol: return u64(uintptr(x))
    case: return 4
    }
    return h
}

@(private = "file")
coll_is_set :: proc(c: ^Collection) -> bool {
    return c.kind == .Set || c.kind == .Weak_Set
}

// ── métodos ───────────────────────────────────────────────────────────────────

@(private = "file")
map_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection)
    if !ok { throw_type_error(vm, "Method Map.prototype.set called on incompatible receiver"); return nil }
    k := arg(args, 0); v := arg(args, 1)
    if c.kind == .Weak_Map && !coll_can_hold_weak(vm, k) {
        throw_type_error(vm, "Invalid value used as weak map key"); return nil
    }
    coll_put(c, k, v)
    return this // Map.set devolve o próprio (encadeável)
}

// Group directly into the ordered Map backing; keys retain their JS identity.
@(private = "file")
map_group_by :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    src := arg(args, 0)
    if is_nullish(src) { throw_type_error(vm, "Map.groupBy requires an iterable"); return nil }
    callback, callable := arg(args, 1).(^Function)
    if !callable { throw_type_error(vm, "Map.groupBy callback is not callable"); return nil }
    method := get_member(vm, src, vm.sym_iterator_key)
    if vm.throwing do return nil
    fn, ok := method.(^Function)
    if !ok { throw_type_error(vm, "Map.groupBy requires an iterable"); return nil }
    iter := call_function(vm, fn, src, nil)
    if vm.throwing do return nil
    if is_primitive(iter) { throw_type_error(vm, "Invalid iterator"); return nil }
    next_value := get_member(vm, iter, "next")
    if vm.throwing do return nil
    next, next_ok := next_value.(^Function)
    if !next_ok { throw_type_error(vm, "Iterator next is not callable"); return nil }
    out := new_collection(vm, .Map)
    for i := 0; ; i += 1 {
        if step_guard(vm) do return nil
        if f64(i) >= 9007199254740991 {
            iterator_close(vm, iter)
            throw_type_error(vm, "Map.groupBy input is too large")
            return nil
        }
        result := call_function(vm, next, iter, nil)
        if vm.throwing do return nil
        if is_primitive(result) { throw_type_error(vm, "Invalid iterator result"); return nil }
        done := get_member(vm, result, "done")
        if vm.throwing do return nil
        if truthy(done) do return out
        value := get_member(vm, result, "value")
        if vm.throwing do return nil
        key := call_function(vm, callback, nil, []Value{value, f64(i)})
        if vm.throwing {
            exc := vm.thrown
            vm.throwing = false; vm.thrown = nil
            iterator_close(vm, iter)
            vm.throwing = true; vm.thrown = exc
            return nil
        }
        bucket: ^Array
        if index := coll_find(out, key); index >= 0 {
            bucket = out.entries[index].val.(^Array)
        } else {
            bucket = new_array(vm)
            coll_put(out, key, bucket)
        }
        append(&bucket.items, value)
    }
}

@(private = "file")
set_add :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection)
    if !ok { throw_type_error(vm, "Method Set.prototype.add called on incompatible receiver"); return nil }
    k := arg(args, 0)
    if c.kind == .Weak_Set && !coll_can_hold_weak(vm, k) {
        throw_type_error(vm, "Invalid value used in weak set"); return nil
    }
    coll_put(c, k, k)
    return this // Set.add devolve o próprio
}

@(private = "file")
coll_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection)
    if !ok { throw_type_error(vm, "Method Map.prototype.get called on incompatible receiver"); return nil }
    if i := coll_find(c, arg(args, 0)); i >= 0 do return c.entries[i].val
    return nil // undefined
}

@(private = "file")
coll_has :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection); if !ok do return false
    return coll_find(c, arg(args, 0)) >= 0
}

coll_delete :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection); if !ok do return false
    if i := coll_find(c, arg(args, 0)); i >= 0 {
        hash := coll_hash(c.entries[i].key)
        link := c.index[hash]
        prev := 0
        for link != i+1 { prev = link; link = c.entries[link-1].next }
        if prev == 0 {
            if c.entries[i].next == 0 { delete_key(&c.index, hash) } else { c.index[hash] = c.entries[i].next }
        } else { c.entries[prev-1].next = c.entries[i].next }
        c.entries[i] = Coll_Entry{dead = true}
        c.size -= 1
        return true
    }
    return false
}

@(private = "file")
coll_clear :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if c, ok := this.(^Collection); ok {
        clear(&c.index)
        c.size = 0
        if c.iterating == 0 { clear(&c.entries) } else {
            for &e in c.entries do e = Coll_Entry{dead = true}
        }
    }
    return nil
}

// forEach(cb[, thisArg]): Map chama cb(val, key, coll); Set chama cb(val, val, coll).
@(private = "file")
coll_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // brand-check e callback-check da spec: forEach em receiver sem [[MapData]]/
    // [[SetData]] ou com callback não-chamável lança TypeError (antes: no-op silencioso).
    c := coll_receiver(this)
    if c == nil { throw_type_error(vm, "Collection forEach called on incompatible receiver"); return nil }
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "callback is not a function"); return nil }
    this_arg := arg(args, 1)
    c.iterating += 1
    defer c.iterating -= 1
    // índice: entradas adicionadas durante a iteração também são visitadas (spec)
    for i := 0; i < len(c.entries); i += 1 {
        e := c.entries[i]
        if e.dead do continue
        call_function(vm, cb, this_arg, []Value{e.val, e.key, this})
        if vm.throwing do break
    }
    return nil
}

@(private = "file")
coll_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return make_collection_iterator(vm, coll_receiver(this), this, .Keys)
}

@(private = "file")
coll_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return make_collection_iterator(vm, coll_receiver(this), this, .Values)
}

@(private = "file")
coll_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return make_collection_iterator(vm, coll_receiver(this), this, .Entries)
}

@(private = "file")
make_collection_iterator :: proc(vm: ^Interp, c: ^Collection, source: Value, method: Coll_Method) -> Value {
    o := new_object(vm)
    o.proto = vm.collection_iter_protos[c.kind]
    o.coll_iter = new(Coll_Iterator)
    o.coll_iter^ = Coll_Iterator{collection = c, source = source, method = method, kind = c.kind}
    // Slots must stay stable until next() reports done or GC discards the
    // iterator. This also makes clear() preserve cursors into the old slots.
    c.iterating += 1
    return o
}

@(private = "file")
coll_iterator_release :: proc(it: ^Coll_Iterator) {
    if it.collection != nil {
        it.collection.iterating -= 1
        it.collection = nil
        it.source = nil
    }
}

// Object sweeping/destruction runs before collection storage is freed.
coll_iterator_destroy :: proc(o: ^Object) {
    if o.coll_iter == nil do return
    coll_iterator_release(o.coll_iter)
    free(o.coll_iter)
    o.coll_iter = nil
}

@(private = "file")
coll_iterator_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object)
    kind := Coll_Kind(int(vm.native_bound.(f64)))
    if !ok || o.coll_iter == nil || o.coll_iter.kind != kind || proxy_state(this) != nil {
        throw_type_error(vm, "Collection iterator next called on incompatible receiver")
        return nil
    }
    it := o.coll_iter
    result := new_object(vm)
    result.props["done"] = true
    result.props["value"] = nil
    if c := it.collection; c != nil {
        for it.cursor < len(c.entries) {
            e := c.entries[it.cursor]
            it.cursor += 1
            if e.dead do continue
            value := e.val
            if it.method == .Keys do value = e.key
            if it.method == .Entries {
                pair := new_array(vm)
                append(&pair.items, e.key, e.val)
                value = pair
            }
            result.props["done"] = false
            result.props["value"] = value
            return result
        }
        coll_iterator_release(it)
    }
    return result
}

// Called after the shared %IteratorPrototype% is installed.
install_collection_iterators :: proc(vm: ^Interp) {
    for kind in ([]Coll_Kind{.Map, .Set}) {
        proto := new_object(vm)
        proto.proto = vm.iter_proto
        next := mk_builtin_method(vm, coll_iterator_next, "next", 0)
        next.bound = f64(kind)
        proto.props["next"] = next
        mark_non_enumerable(proto, "next")
        proto.props[vm.sym_tostring_tag_key] = "Map Iterator" if kind == .Map else "Set Iterator"
        mark_non_enumerable(proto, vm.sym_tostring_tag_key)
        proto.attrs[vm.sym_tostring_tag_key] = {.Configurable}
        vm.collection_iter_protos[kind] = proto
    }
}

// Iterador simples: objeto com `next()` que percorre um array + cursor, devolvendo
// {value, done}. React itera Map/Set com `for(b=m.entries(); !(y=b.next()).done; )`
// — sem um next() que TERMINA em done=true, o laço nunca para (era o hang do tradebig).
// O iterador também é iterável de si mesmo (para for-of/spread reconhecerem via next()).
make_array_iterator :: proc(vm: ^Interp, arr: ^Array) -> Value {
    it := new_object(vm)
    it.props["_arr"] = arr
    it.props["_i"] = f64(0)
    // next + [Symbol.iterator] são HERDADOS, e por DOIS degraus: o `next` mora no
    // %ArrayIteratorPrototype% e o [Symbol.iterator] no %IteratorPrototype% acima
    // dele (ver o comentário do install em builtins.odin — colapsar os dois fazia
    // polyfill de iterator-helpers escrever em Object.prototype, M219).
    if vm.array_iter_proto != nil {
        it.proto = vm.array_iter_proto
    } else { // fallback pré-init (protos ainda não montados): own props
        it.props["next"] = vm.iter_next_fn
        if vm.sym_iterator_key != "" && vm.gen_iter_fn != nil do it.props[vm.sym_iterator_key] = vm.gen_iter_fn
    }
    return it
}

@(private = "file")
iter_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_object(vm)
    o, ok := this.(^Object)
    if !ok { res.props["value"] = nil; res.props["done"] = true; return res }
    if _, live := o.props["_kind"]; live do return arr_iter_next(vm, o)
    arr, aok := o.props["_arr"].(^Array)
    i := int(as_number(o.props["_i"]))
    if !aok || i >= len(arr.items) {
        res.props["value"] = nil
        res.props["done"] = true
        return res
    }
    res.props["value"] = arr.items[i]
    res.props["done"] = false
    o.props["_i"] = f64(i + 1)
    return res
}

// True se `v` é um objeto-iterador (tem um método `next` chamável). Usado por
// for-of/spread p/ dirigir o protocolo de iteração.
is_iterator_obj :: proc(v: Value) -> bool {
    return iterator_next_fn(v) != nil
}

// Resolve o método `next` de um iterador subindo a cadeia de protótipo —
// iteradores de classe (`class It { next(){...} }`) têm o next no prototype,
// não nas props próprias.
iterator_next_fn :: proc(v: Value) -> ^Function {
    return iterator_method_fn(v, "next")
}

// Como iterator_next_fn, mas p/ um método qualquer ("throw"/"return") — usado pela
// delegação de yield* p/ encaminhar throw()/return() ao iterador delegado.
iterator_method_fn :: proc(v: Value, name: string) -> ^Function {
    o, ok := v.(^Object)
    if !ok do return nil
    for cur := o; cur != nil; cur = cur.proto {
        if fn, has := cur.props[name].(^Function); has do return fn
    }
    return nil
}

// ── construtores ──────────────────────────────────────────────────────────────

coll_put :: proc(c: ^Collection, k, v: Value) {
    if i := coll_find(c, k); i >= 0 { c.entries[i].val = v; return }
    // Amortized compaction; callbacks must retain their entry positions.
    if c.iterating == 0 && len(c.entries) > 64 && len(c.entries) > 2*c.size {
        clear(&c.index)
        n := 0
        for e in c.entries {
            if e.dead do continue
            hash := coll_hash(e.key)
            entry := e
            entry.next = c.index[hash]
            c.entries[n] = entry
            c.index[hash] = n+1
            n += 1
        }
        resize(&c.entries, n)
    }
    key := k
    if n, ok := key.(f64); ok && n == 0 do key = f64(0)
    val := v
    if coll_is_set(c) do val = key
    hash := coll_hash(key)
    append(&c.entries, Coll_Entry{key = key, val = val, next = c.index[hash]})
    c.index[hash] = len(c.entries)
    c.size += 1
}

// Weak keys include objects and symbols that are not in the global registry.
@(private = "file")
coll_can_hold_weak :: proc(vm: ^Interp, key: Value) -> bool {
    if !is_primitive(key) do return true
    if sym, ok := key.(^Symbol); ok {
        for _, registered in vm.symbol_registry do if registered == sym do return false
        return true
    }
    return false
}

// Process one entry before requesting the next one. Index reads must run getters
// in order, and the constructor must call the adder captured from its prototype.
@(private = "file")
coll_add_item :: proc(vm: ^Interp, target: Value, adder: ^Function, is_set: bool, item: Value) {
    if is_set {
        call_function(vm, adder, target, []Value{item})
        return
    }
    if is_primitive(item) { throw_type_error(vm, "Map iterator value is not an object"); return }
    key := get_index(vm, item, f64(0))
    if vm.throwing do return
    val := get_index(vm, item, f64(1))
    if vm.throwing do return
    call_function(vm, adder, target, []Value{key, val})
}

// All inputs use the iterator protocol, including arrays and collections. Do
// not drain ahead: entry getters and adders can mutate or close the source.
@(private = "file")
coll_init_from :: proc(vm: ^Interp, c: ^Collection, target: Value, adder: ^Function, src: Value) {
    method := get_member(vm, src, vm.sym_iterator_key)
    if vm.throwing do return
    iterator_fn, callable := method.(^Function)
    if !callable { throw_type_error(vm, "Collection input is not iterable"); return }
    iter := call_function(vm, iterator_fn, src, nil)
    if vm.throwing do return
    if is_primitive(iter) { throw_type_error(vm, "Invalid collection iterator"); return }
    next_value := get_member(vm, iter, "next")
    if vm.throwing do return
    next, next_ok := next_value.(^Function)
    if !next_ok { throw_type_error(vm, "Iterator next is not callable"); return }
    for {
        if step_guard(vm) do return
        result := call_function(vm, next, iter, nil)
        if vm.throwing do return
        if is_primitive(result) { throw_type_error(vm, "Invalid iterator result"); return }
        done := get_member(vm, result, "done")
        if vm.throwing do return
        if truthy(done) do return
        item := get_member(vm, result, "value")
        if vm.throwing do return
        coll_add_item(vm, target, adder, coll_is_set(c), item)
        if vm.throwing {
            // IteratorClose with a throw completion preserves the original
            // exception, even when reading/calling return throws another one.
            exception := vm.thrown
            vm.throwing = false; vm.thrown = nil
            iterator_close(vm, iter)
            vm.throwing = true; vm.thrown = exception
            return
        }
    }
}

@(private = "file")
coll_construct :: proc(vm: ^Interp, this: Value, args: []Value, kind: Coll_Kind) -> Value {
    if !vm.native_new { throw_type_error(vm, "Collection constructor requires 'new'"); return nil }
    c := new_collection(vm, kind)
    target: Value = c
    proto, _ := vm.native_bound.(^Object)
    // super() initializes the subclass receiver before looking up its adder.
    if o, ok := this.(^Object); ok {
        o.prim = c
        target = o
        proto = o
    }
    src := arg(args, 0)
    if is_nullish(src) do return c
    name := "add" if coll_is_set(c) else "set"
    adder_value: Value
    for cur := proto; cur != nil; cur = cur.proto {
        if getter, has := cur.getters[name]; has {
            if getter != nil do adder_value = call_function(vm, getter, target, nil)
            break
        }
        if value, has := cur.props[name]; has { adder_value = value; break }
    }
    if vm.throwing do return nil
    adder, ok := adder_value.(^Function)
    if !ok { throw_type_error(vm, "Collection adder is not callable"); return nil }
    coll_init_from(vm, c, target, adder, src)
    if vm.throwing do return nil
    return c
}

@(private = "file")
map_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return coll_construct(vm, this, args, .Map)
}
@(private = "file")
set_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return coll_construct(vm, this, args, .Set)
}
@(private = "file")
weakmap_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return coll_construct(vm, this, args, .Weak_Map)
}
@(private = "file")
weakset_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return coll_construct(vm, this, args, .Weak_Set)
}

// Each prototype owns functions with its own brand. The flat method registry
// roots the functions and identifies native methods of builtin subclasses.
install_collections :: proc(vm: ^Interp) {
    vm.iter_next_fn = mk_native(vm, iter_next)
    vm.iter_next_fn.name = "next"
    vm.collection_methods = make(map[string]^Function)
    install_set_operations(vm)
    reg :: proc(vm: ^Interp, name: string, fn: Native_Fn, kind: Coll_Kind) {
        f := mk_native(vm, fn)
        f.name = name
        proto := new_object(vm)
        proto.proto = vm.object_proto
        method :: proc(vm: ^Interp, proto: ^Object, owner: string, kind: Coll_Kind, op: Coll_Method, name: string, arity: int) {
            f := mk_builtin_method(vm, coll_method_dispatch, name, arity)
            f.bound = f64(int(kind)*COLL_METHOD_STRIDE + int(op))
            key := own_str(vm, strings.concatenate({owner, ".", name}, context.temp_allocator)).(string)
            vm.collection_methods[key] = f
            if op == .Size {
                if proto.getters == nil do proto.getters = make(map[string]^Function)
                proto.getters["size"] = f
            } else {
                proto.props[name] = f
            }
            mark_non_enumerable(proto, "size" if op == .Size else name)
        }
        method(vm, proto, name, kind, .Has, "has", 1)
        method(vm, proto, name, kind, .Delete, "delete", 1)
        if kind == .Map || kind == .Weak_Map {
            method(vm, proto, name, kind, .Set, "set", 2)
            method(vm, proto, name, kind, .Get, "get", 1)
        } else {
            method(vm, proto, name, kind, .Add, "add", 1)
        }
        if kind == .Map || kind == .Set {
            method(vm, proto, name, kind, .Clear, "clear", 0)
            method(vm, proto, name, kind, .For_Each, "forEach", 1)
            method(vm, proto, name, kind, .Values, "values", 0)
            method(vm, proto, name, kind, .Entries, "entries", 0)
            method(vm, proto, name, kind, .Size, "get size", 0)
            if kind == .Map {
                method(vm, proto, name, kind, .Keys, "keys", 0)
                proto.props[vm.sym_iterator_key] = proto.props["entries"]
            } else {
                proto.props["keys"] = proto.props["values"]
                mark_non_enumerable(proto, "keys")
                proto.props[vm.sym_iterator_key] = proto.props["values"]
                for k, f in vm.collection_methods do if set_operation_name(k) do proto.props[k] = f
            }
        }
        proto.props["constructor"] = f
        if f.props == nil do f.props = make(map[string]Value)
        f.props["prototype"] = proto
        f.bound = proto
        vm.collection_protos[kind] = proto
        if name == "Map" do f.props["groupBy"] = mk_builtin_method(vm, map_group_by, "groupBy", 2)
        env_define(vm.global, name, f)
    }
    reg(vm, "Map",     map_ctor, .Map)
    reg(vm, "Set",     set_ctor, .Set)
    reg(vm, "WeakMap", weakmap_ctor, .Weak_Map)
    reg(vm, "WeakSet", weakset_ctor, .Weak_Set)

    // WeakRef / FinalizationRegistry — apareceram NOMEADOS no gap-report depois
    // do M150 (coingecko). Aqui a degradação é CONFORME, não um remendo: a spec
    // não garante que um alvo seja coletado nem que um callback de finalização
    // rode. Nós nunca coletamos, então `deref()` sempre devolve o alvo e o
    // registry nunca chama de volta — comportamento que um browser real também
    // pode ter. Código que usa isto como cache-de-oportunidade continua correto.
    env_define(vm.global, "WeakRef", mk_weak_ctor(vm, "WeakRef", weakref_ctor))
    env_define(vm.global, "FinalizationRegistry", mk_weak_ctor(vm, "FinalizationRegistry", finreg_ctor))
}

@(private = "file")
mk_weak_ctor :: proc(vm: ^Interp, name: string, fn: Native_Fn) -> ^Function {
    f := mk_native(vm, fn)
    f.name = name
    f.props = make(map[string]Value)
    proto := new_object(vm)
    proto.proto = vm.object_proto
    proto.props["constructor"] = f
    mark_non_enumerable(proto, "constructor")
    f.props["prototype"] = proto
    f.bound = proto
    return f
}

@(private = "file")
weakref_deref :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if o, ok := this.(^Object); ok do return o.props["#target"]
    if o, ok := vm.native_bound.(^Object); ok do return o.props["#target"]
    return nil
}

@(private = "file")
weakref_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := new_object(vm)
    o.props["#target"] = arg(a, 0) // referência FORTE: nunca coletamos
    o.props["deref"] = mk_native(vm, weakref_deref)
    mark_non_enumerable(o, "deref")
    if p, ok := vm.native_bound.(^Object); ok do o.proto = p
    return o
}

@(private = "file")
finreg_noop :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return nil }

@(private = "file")
finreg_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := new_object(vm)
    noop := mk_native(vm, finreg_noop)
    o.props["register"]   = noop
    o.props["unregister"] = noop
    o.props["cleanupSome"] = noop
    for k in ([?]string{"register", "unregister", "cleanupSome"}) do mark_non_enumerable(o, k)
    if p, ok := vm.native_bound.(^Object); ok do o.proto = p
    return o
}

// Drop weak entries before sweeping their keys. Rebuild chains without moving slots.
gc_prune_weak :: proc(c: ^Collection, g: ^GC_State) {
    clear(&c.index)
    for &e, i in c.entries {
        if e.dead do continue
        if !gc_live(g, e.key) {
            e = Coll_Entry{dead = true}
            c.size -= 1
            continue
        }
        hash := coll_hash(e.key)
        e.next = c.index[hash]
        c.index[hash] = i+1
    }
}
