package js



// Map / Set / WeakMap / WeakSet.
//
// Implementação única (^Collection) com um `kind`. A "fraqueza" de WeakMap/
// WeakSet só afeta a coleta de lixo — não a semântica observável de get/set/has/
// delete — então os quatro compartilham o mesmo backing e métodos. As chaves são
// comparadas por SameValueZero (identidade p/ objetos; valor p/ primitivos; e
// NaN igual a NaN), então objetos servem de chave, como no JS real.
//
// O backing é uma lista em ordem de inserção com varredura linear (O(n) por
// operação). Simples e correto; dá p/ trocar por hash depois se pesar.

Coll_Kind :: enum { Map, Set, Weak_Map, Weak_Set }

Coll_Entry :: struct {
    key: Value,
    val: Value, // Set/WeakSet: val == key (forEach passa (val, key) iguais)
}

Collection :: struct {
    kind:    Coll_Kind,
    entries: [dynamic]Coll_Entry,
}

new_collection :: proc(vm: ^Interp, kind: Coll_Kind) -> ^Collection {
    c := new(Collection)
    c.kind = kind
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
@(private = "file")
coll_find :: proc(c: ^Collection, key: Value) -> int {
    for e, i in c.entries do if same_value_zero(e.key, key) do return i
    return -1
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
    if i := coll_find(c, k); i >= 0 {
        c.entries[i].val = v
    } else {
        append(&c.entries, Coll_Entry{key = k, val = v})
    }
    return this // Map.set devolve o próprio (encadeável)
}

@(private = "file")
set_add :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection)
    if !ok { throw_type_error(vm, "Method Set.prototype.add called on incompatible receiver"); return nil }
    k := arg(args, 0)
    if coll_find(c, k) < 0 do append(&c.entries, Coll_Entry{key = k, val = k})
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

@(private = "file")
coll_delete :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c, ok := this.(^Collection); if !ok do return false
    if i := coll_find(c, arg(args, 0)); i >= 0 {
        ordered_remove(&c.entries, i) // preserva a ordem de inserção
        return true
    }
    return false
}

@(private = "file")
coll_clear :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if c, ok := this.(^Collection); ok do clear(&c.entries)
    return nil
}

// forEach(cb[, thisArg]): Map chama cb(val, key, coll); Set chama cb(val, val, coll).
@(private = "file")
coll_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // brand-check e callback-check da spec: forEach em receiver sem [[MapData]]/
    // [[SetData]] ou com callback não-chamável lança TypeError (antes: no-op silencioso).
    c, ok := this.(^Collection)
    if !ok { throw_type_error(vm, "Method Map.prototype.forEach called on incompatible receiver"); return nil }
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "callback is not a function"); return nil }
    this_arg := arg(args, 1)
    // índice: entradas adicionadas durante a iteração também são visitadas (spec)
    for i := 0; i < len(c.entries); i += 1 {
        e := c.entries[i]
        call_function(vm, cb, this_arg, []Value{e.val, e.key, this})
        if vm.throwing do break
    }
    return nil
}

@(private = "file")
coll_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    if c, ok := this.(^Collection); ok do for e in c.entries do append(&out.items, e.key)
    return make_array_iterator(vm, out) // Map/Set.keys() → ITERADOR (não array), como no JS
}

@(private = "file")
coll_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    if c, ok := this.(^Collection); ok do for e in c.entries do append(&out.items, e.val)
    return make_array_iterator(vm, out)
}

// [Symbol.iterator] de uma coleção: Set/WeakSet iteram valores; Map/WeakMap, pares.
@(private = "file")
coll_iterator :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if c, ok := this.(^Collection); ok && coll_is_set(c) do return coll_values(vm, this, args)
    return coll_entries(vm, this, args)
}

@(private = "file")
coll_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    if c, ok := this.(^Collection); ok {
        for e in c.entries {
            pair := new_array(vm)
            append(&pair.items, e.key)
            append(&pair.items, e.val)
            append(&out.items, pair)
        }
    }
    return make_array_iterator(vm, out)
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

@(private = "file")
coll_put :: proc(c: ^Collection, k, v: Value) {
    if i := coll_find(c, k); i >= 0 { c.entries[i].val = v } else { append(&c.entries, Coll_Entry{key = k, val = v}) }
}

// Adiciona UM item já materializado: Set guarda o valor solto; Map espera um par
// [chave, valor] (lido por índice 0/1 — cobre par ^Array e array-likes).
@(private = "file")
coll_add_item :: proc(vm: ^Interp, c: ^Collection, is_set: bool, it: Value) {
    if is_set { coll_put(c, it, it); return }
    if pair, ok := it.(^Array); ok {
        k := pair.items[0] if len(pair.items) >= 1 else nil
        v := pair.items[1] if len(pair.items) >= 2 else nil
        coll_put(c, k, v)
    } else if is_ref_type(it) { // par não-array (typed array / array-like): it[0]/it[1]
        coll_put(c, get_index(vm, it, f64(0)), get_index(vm, it, f64(1)))
    }
}

// Inicializa a partir de um iterável: Map espera pares [k,v]; Set, valores soltos.
// ^Array/^Collection têm caminho direto (rápido); QUALQUER outro iterável (outro
// iterador, generator, objeto com Symbol.iterator) passa pelo protocolo de
// iteração. Sem isso, `new Map(iterávelGenérico)` não consumia nada — e o core-js,
// ao detectar isso (checkCorrectnessOfIteration falha pois next() nunca é chamado),
// EMBRULHAVA o construtor Map, disparando o bug do receiver incompatível.
@(private = "file")
coll_init_from :: proc(vm: ^Interp, c: ^Collection, src: Value) {
    is_set := coll_is_set(c)
    #partial switch s in src {
    case ^Array:
        for it in s.items do coll_add_item(vm, c, is_set, it)
    case ^Collection:
        for e in s.entries do coll_put(c, e.key, is_set ? e.key : e.val)
    case:
        if is_nullish(src) do return // new Map()/new Map(null/undefined): vazio
        items: [dynamic]Value
        defer delete(items)
        if iterate_protocol(vm, src, &items) {
            for it in items do coll_add_item(vm, c, is_set, it)
        }
    }
}

@(private = "file")
map_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c := new_collection(vm, .Map)
    coll_init_from(vm, c, arg(args, 0))
    return c
}
@(private = "file")
set_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c := new_collection(vm, .Set)
    coll_init_from(vm, c, arg(args, 0))
    return c
}
@(private = "file")
weakmap_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c := new_collection(vm, .Weak_Map)
    coll_init_from(vm, c, arg(args, 0))
    return c
}
@(private = "file")
weakset_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    c := new_collection(vm, .Weak_Set)
    coll_init_from(vm, c, arg(args, 0))
    return c
}

// get_member de ^Collection consulta este mapa (após tratar "size").
install_collections :: proc(vm: ^Interp) {
    vm.iter_next_fn = mk_native(vm, iter_next)
    vm.iter_next_fn.name = "next"
    vm.collection_methods = make(map[string]^Function)
    m := &vm.collection_methods
    m["set"]     = mk_native(vm, map_set)
    m["get"]     = mk_native(vm, coll_get)
    m["add"]     = mk_native(vm, set_add)
    m["has"]     = mk_native(vm, coll_has)
    m["delete"]  = mk_native(vm, coll_delete)
    m["clear"]   = mk_native(vm, coll_clear)
    m["forEach"] = mk_native(vm, coll_for_each)
    m["keys"]    = mk_native(vm, coll_keys)
    m["values"]  = mk_native(vm, coll_values)
    m["entries"] = mk_native(vm, coll_entries)
    // [Symbol.iterator]: Map/WeakMap → entries; Set/WeakSet → values (default do JS).
    // Exposto p/ `coll[Symbol.iterator]()` explícito (getIterator do core-js), não só for-of.
    if vm.sym_iterator_key != "" do m[vm.sym_iterator_key] = mk_native(vm, coll_iterator)

    // o nome é usado pelo `instanceof` p/ casar a coleção com seu construtor.
    // Cada ctor ganha um `.prototype` REAL populado com os métodos de coleção:
    // construtores nativos (o.native != nil) NÃO recebem o auto-proto de get_member,
    // então `Map.prototype` era undefined e o core-js estourava em
    // `Map.prototype.forEach` ("reading 'forEach' of undefined"). O dispatch normal
    // (`map.forEach()`) continua indo direto no collection_methods (get_member de
    // ^Collection); este proto é p/ o probe/uncurryThis do core-js e `instanceof`.
    reg :: proc(vm: ^Interp, name: string, fn: Native_Fn) {
        f := mk_native(vm, fn)
        f.name = name
        proto := new_object(vm)
        proto.proto = vm.object_proto
        for k, mf in vm.collection_methods do proto.props[k] = mf
        proto.props["constructor"] = f
        if f.props == nil do f.props = make(map[string]Value)
        f.props["prototype"] = proto
        env_define(vm.global, name, f)
    }
    reg(vm, "Map",     map_ctor)
    reg(vm, "Set",     set_ctor)
    reg(vm, "WeakMap", weakmap_ctor)
    reg(vm, "WeakSet", weakset_ctor)

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
