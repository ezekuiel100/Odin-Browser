package js

import "core:testing"

// M97 — "Method Map.prototype.set called on incompatible receiver" (globo/
// aliexpress/theverge). CADEIA de dois bugs que se combinam sob o core-js:
//   (B) `new Map(iterávelGenérico)` não consumia o iterável (só ^Array/^Collection).
//       → checkCorrectnessOfIteration do core-js falha (next() nunca chamado)
//       → core-js EMBRULHA o construtor Map num construtor JS que faz
//         `return new NativeMap()` (um ^Collection).
//   (C) `new` DESCARTAVA um retorno ^Collection (construct_object só honrava
//       ^Object/^Array) → `new Map()` devolvia o ^Object vazio (proto=Map.prototype)
//       → `.set()` batia num receiver que não é ^Collection → o TypeError.
// Corrigir QUALQUER um quebra a cadeia; corrigimos os dois (ambos são bugs de
// conformância reais).

// ── Bug C: new honra retorno de tipo-objeto ─────────────────────────────────

@(test)
m97_new_honors_collection_return :: proc(t: ^testing.T) {
    // construtor que devolve um ^Collection nativo (o padrão do wrapper core-js)
    v := run(`
        function Wrap(){ var m = new Map(); m.set('k', 1); return m; }
        Wrap.prototype = Map.prototype;
        var x = new Wrap();
        x.set('j', 2);              // se new devolvesse o ^Object vazio, ISTO estoura
        x.get('k') + ':' + x.get('j') + ':' + x.size
    `)
    testing.expectf(t, v == "1:2:2", "new deve honrar retorno ^Collection: got %v", v)
}

@(test)
m97_new_still_honors_plain_object_return :: proc(t: ^testing.T) {
    v := run(`function F(){ this.a=1; return {x:42}; } new F().x`)
    testing.expectf(t, as_number(v) == 42, "retorno ^Object: got %v", v)
}

@(test)
m97_new_ignores_primitive_return :: proc(t: ^testing.T) {
    v := run(`function F(){ this.a=7; return 99; } new F().a`)
    testing.expectf(t, as_number(v) == 7, "retorno primitivo é ignorado: got %v", v)
}

// ── Bug B: construtores de coleção consomem iterável genérico ────────────────

@(test)
m97_map_from_generic_iterable :: proc(t: ^testing.T) {
    v := run(`
        var it = {};
        it[Symbol.iterator] = function(){
            var i = 0, data = [['a',1],['b',2]];
            return { next: function(){
                return i < data.length ? {value:data[i++], done:false} : {done:true};
            }};
        };
        var m = new Map(it);
        m.size + ':' + m.get('a') + ':' + m.get('b')
    `)
    testing.expectf(t, v == "2:1:2", "new Map(iterável genérico): got %v", v)
}

@(test)
m97_map_iterable_next_is_called :: proc(t: ^testing.T) {
    // é EXATAMENTE o que o checkCorrectnessOfIteration do core-js verifica
    v := run(`
        var called = false;
        var it = {};
        it[Symbol.iterator] = function(){ return { next: function(){ called = true; return {done:true}; } }; };
        new Map(it);
        called
    `)
    testing.expectf(t, truthy(v), "next() do iterável deve ser chamado: got %v", v)
}

@(test)
m97_set_from_generic_iterable :: proc(t: ^testing.T) {
    v := run(`
        function* gen(){ yield 10; yield 20; yield 20; yield 30; }
        var s = new Set(gen());
        s.size + ':' + s.has(10) + ':' + s.has(20) + ':' + s.has(30)
    `)
    testing.expectf(t, v == "3:true:true:true", "new Set(generator): got %v", v)
}

@(test)
m97_map_from_entries_iterator :: proc(t: ^testing.T) {
    // new Map(outroMap.entries()) — iterador de pares
    v := run(`
        var src = new Map(); src.set('x', 1); src.set('y', 2);
        var m = new Map(src.entries());
        m.size + ':' + m.get('x') + ':' + m.get('y')
    `)
    testing.expectf(t, v == "2:1:2", "new Map(entries()): got %v", v)
}

@(test)
m97_map_null_undefined_empty :: proc(t: ^testing.T) {
    v := run(`(new Map().size) + ':' + (new Map(null).size) + ':' + (new Map(undefined).size)`)
    testing.expectf(t, v == "0:0:0", "new Map(null/undefined): got %v", v)
}

// ── Cenário de produção: wrapper core-js + uncurryThis (fim a fim) ───────────

@(test)
m97_corejs_wrapper_with_uncurry_this :: proc(t: ^testing.T) {
    // Reproduz fielmente o que quebrava: core-js embrulha Map (porque ACCEPT_ITERABLES
    // era false), o wrapper devolve um ^Collection nativo, e depois chama
    // Map.prototype.set via uncurryThis. NATIVE_BIND é false no motor → caminho fallback.
    v := run(`
        var NativeMap = Map;
        // uncurryThis fallback do core-js
        var call = Function.prototype.call;
        function uncurryThis(fn){ return function(){ return call.apply(fn, arguments); }; }
        var mapSet = uncurryThis(NativeMap.prototype.set);
        // wrapper do core-js: constrói coleção nativa, itera, RETORNA a coleção
        function WrappedMap(iterable){
            var that = new NativeMap();
            if (iterable != undefined) {
                var arr = [];
                var it = iterable[Symbol.iterator]();
                for (var step = it.next(); !step.done; step = it.next()) arr.push(step.value);
                for (var i=0;i<arr.length;i++) mapSet(that, arr[i][0], arr[i][1]);
            }
            return that;
        }
        WrappedMap.prototype = NativeMap.prototype;
        NativeMap.prototype.constructor = WrappedMap;

        function* pairs(){ yield ['a',1]; yield ['b',2]; }
        var m = new WrappedMap(pairs());
        mapSet(m, 'c', 3);          // uncurryThis'd set no receiver devolvido pelo new
        m.get('a') + ':' + m.get('b') + ':' + m.get('c') + ':' + m.size
    `)
    testing.expectf(t, v == "1:2:3:3", "wrapper core-js + uncurryThis fim-a-fim: got %v", v)
}
