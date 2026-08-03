package js

import "core:testing"

// ── M74: [Symbol.iterator] EXPLÍCITO nos iteráveis nativos ────────────────────
// core-js e libs não usam só for-of; fazem `getIterator(x)` = `x[Symbol.iterator]()`
// e depois lêem `it.next`. Sem o método nos nativos (array/string/Map/Set/iterador),
// getIterator devolvia undefined → `reading 'next' of null` → bundle da SPA morria.

// Array: arr[Symbol.iterator]() é um iterador que anda os elementos.
@(test)
test_array_symbol_iterator :: proc(t: ^testing.T) {
    src := `
        var it = [10,20,30][Symbol.iterator]();
        var a = it.next(); var b = it.next(); var c = it.next(); var d = it.next();
        a.value +':'+ b.value +':'+ c.value +':'+ d.done
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "10:20:30:true", "arr[Symbol.iterator]() deve iterar 10,20,30 e terminar done=true")
}

// Array.prototype[Symbol.iterator] existe e é === a Array.prototype.values (uncurryThis).
@(test)
test_array_proto_symbol_iterator_is_values :: proc(t: ^testing.T) {
    ok := truthy(run("Array.prototype[Symbol.iterator] === Array.prototype.values"))
    testing.expect(t, ok, "Array.prototype[Symbol.iterator] deve ser o mesmo native de values")
}

// String: itera por code point.
@(test)
test_string_symbol_iterator :: proc(t: ^testing.T) {
    src := `
        var it = "café"[Symbol.iterator]();
        it.next().value + it.next().value + it.next().value + it.next().value + ':' + it.next().done
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "café:true", "string[Symbol.iterator]() deve dar um item por code point")
}

// O padrão exato do core-js getIterator: pega o método, chama, lê `.next` e dirige.
@(test)
test_corejs_getiterator_pattern :: proc(t: ^testing.T) {
    src := `
        function getIterator(x){
            var m = x[Symbol.iterator];
            var it = m.call(x);          // uncurryThis-ish: chama o método com this=x
            return it;
        }
        var it = getIterator([1,2,3]);
        var next = it.next;              // core-js guarda .next separado
        var s = 0, r;
        while (!(r = next.call(it)).done) s += r.value;
        s
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// Map[Symbol.iterator]() → pares [k,v] (default = entries).
@(test)
test_map_symbol_iterator_entries :: proc(t: ^testing.T) {
    src := `
        var m = new Map(); m.set('a',1); m.set('b',2);
        var it = m[Symbol.iterator]();
        var e = it.next().value;         // ['a',1]
        e[0] + ':' + e[1]
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "a:1", "Map[Symbol.iterator]() deve render pares [chave,valor]")
}

// Set[Symbol.iterator]() → valores (default = values).
@(test)
test_set_symbol_iterator_values :: proc(t: ^testing.T) {
    src := `
        var s = new Set(); s.add(7); s.add(8);
        var it = s[Symbol.iterator]();
        it.next().value + ':' + it.next().value
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "7:8", "Set[Symbol.iterator]() deve render os valores")
}

// O objeto-iterador é iterável de si mesmo: getIterator(arr.values()) === o mesmo.
@(test)
test_iterator_is_self_iterable :: proc(t: ^testing.T) {
    src := `
        var it = [1,2][Symbol.iterator]();
        it[Symbol.iterator]() === it
    `
    testing.expect(t, truthy(run(src)), "iterador deve devolver a si mesmo em [Symbol.iterator]()")
}

// Array.from de um iterador cru (via arr.values()) — core-js/Array.from usam getIterator.
@(test)
test_array_from_iterator :: proc(t: ^testing.T) {
    src := `
        var arr = Array.from([5,6,7].values());
        arr.length + ':' + arr[0] + arr[2]
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "3:57", "Array.from de um iterador deve materializar [5,6,7]")
}

// getPrototypeOf(iterador).next existe — a checagem de %IteratorPrototype% do core-js
// (u=getPrototypeOf(coll.values()); u.next) dava "reading 'next' of null" sem proto.
@(test)
test_iterator_prototype_has_next :: proc(t: ^testing.T) {
    src := `
        var it = [1,2].values();
        var p = Object.getPrototypeOf(it);
        (p !== null) + ':' + (typeof p.next)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:function", "getPrototypeOf(iterador) deve ter next (não-null)")
}

// Map.prototype/Set.prototype existem e carregam os métodos (probe do core-js).
@(test)
test_collection_ctor_has_prototype :: proc(t: ^testing.T) {
    src := `
        (typeof Map.prototype.forEach) + ':' + (typeof Set.prototype.has) + ':' + (Map.prototype.constructor === Map)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "function:function:true", "Map/Set.prototype devem ter métodos + constructor")
}

// Object.defineProperty num CONSTRUTOR (função) grava, e getOwnPropertyDescriptor relê.
// core-js define símbolos bem-conhecidos em Symbol (^Function) e relê o descritor —
// sem isto, "reading 'enumerable' of undefined".
@(test)
test_define_property_on_function :: proc(t: ^testing.T) {
    src := `
        function C(){}
        Object.defineProperty(C, 'tag', { value: 42 });
        var d = Object.getOwnPropertyDescriptor(C, 'tag');
        C.tag + ':' + d.value + ':' + d.enumerable
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "42:42:true", "defineProperty/getOwnPropertyDescriptor devem operar em funções")
}

// getOwnPropertyDescriptor de chave AUSENTE numa função → undefined (não crash).
@(test)
test_get_descriptor_missing_on_function :: proc(t: ^testing.T) {
    src := `
        function C(){}
        Object.getOwnPropertyDescriptor(C, 'nope') === undefined
    `
    testing.expect(t, truthy(run(src)), "descritor de chave ausente em função deve ser undefined")
}

// accessor (get) via defineProperty numa função.
@(test)
test_define_accessor_on_function :: proc(t: ^testing.T) {
    src := `
        function C(){}
        Object.defineProperty(C, 'v', { get: function(){ return 7; } });
        var d = Object.getOwnPropertyDescriptor(C, 'v');
        C.v + ':' + (typeof d.get)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "7:function", "get accessor via defineProperty deve funcionar em função")
}
