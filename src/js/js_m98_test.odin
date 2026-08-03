package js

import "core:testing"

// M98 — NATIVE_BIND: bound functions (`.bind()`) NÃO devem ter `.prototype` própria.
// É a CAUSA RAIZ do M97: o core-js detecta bind nativo com
//   `typeof t == 'function' && !t.hasOwnProperty('prototype')`
// e, quando dava false, EMBRULHAVA Map/Set/WeakMap/WeakSet num construtor JS (+ usava
// caminhos uncurryThis alternativos), disparando "Map.prototype.set called on
// incompatible receiver". Bound fns são "exotic bound function objects" na spec:
// não recebem a prop `prototype`. Fix em get_member (^Function) e obj_has_own_property:
// a criação sob demanda de `.prototype` agora exige `o.bind_target == nil`.

@(test)
m98_bound_fn_typeof_function :: proc(t: ^testing.T) {
    v := run(`typeof (function(){}).bind()`)
    testing.expectf(t, v == "function", "typeof bound fn: got %v", v)
}

@(test)
m98_bound_fn_has_no_own_prototype :: proc(t: ^testing.T) {
    v := run(`(function(){}).bind().hasOwnProperty('prototype')`)
    testing.expectf(t, !truthy(v), "bound fn não tem prototype própria: got %v", v)
}

@(test)
m98_bound_fn_prototype_is_undefined :: proc(t: ^testing.T) {
    v := run(`typeof (function(){}).bind().prototype`)
    testing.expectf(t, v == "undefined", "bound fn .prototype é undefined: got %v", v)
}

@(test)
m98_native_bind_detection_true :: proc(t: ^testing.T) {
    // a feature-detect EXATA do core-js (function-bind-native.js)
    v := run(`
        var test = (function(){}).bind();
        (typeof test == 'function') && !test.hasOwnProperty('prototype')
    `)
    testing.expectf(t, truthy(v), "NATIVE_BIND deve ser true: got %v", v)
}

// Funções NORMAIS continuam com `.prototype` (construtores dependem disso).
@(test)
m98_plain_fn_still_has_prototype :: proc(t: ^testing.T) {
    v := run(`
        function F(){}
        F.hasOwnProperty('prototype') + ':' + (typeof F.prototype)
    `)
    testing.expectf(t, v == "true:object", "fn normal mantém prototype: got %v", v)
}

// Construtor via função normal continua funcionando (regressão-guarda).
@(test)
m98_plain_fn_constructor_still_works :: proc(t: ^testing.T) {
    v := run(`
        function Animal(n){ this.n = n; }
        Animal.prototype.fala = function(){ return this.n + '!'; };
        new Animal('rex').fala()
    `)
    testing.expectf(t, v == "rex!", "construtor com prototype: got %v", v)
}

// Bound fn ainda CHAMÁVEL com this/args fixados (o bind em si não regrediu).
@(test)
m98_bound_fn_still_callable :: proc(t: ^testing.T) {
    v := run(`
        function add(a,b){ return this.base + a + b; }
        var f = add.bind({base:100}, 20);
        f(3)
    `)
    testing.expectf(t, as_number(v) == 123, "bound fn chamável: got %v", v)
}

// core-js functionBindContext via uncurryThis(Function.prototype.bind) — o caminho
// NATIVE_BIND (agora ativo) — precisa entregar this correto no Map.prototype.set.
@(test)
m98_corejs_native_bind_uncurry_mapset :: proc(t: ^testing.T) {
    v := run(`
        var call = Function.prototype.call;
        var uncurryThis = Function.prototype.bind.bind(call, call);
        var bindNative = uncurryThis(Function.prototype.bind);   // ramo NATIVE_BIND
        var m = new Map();
        var boundSet = bindNative(Map.prototype.set, m);
        boundSet('a', 1); boundSet('b', 2);
        m.get('a') + ':' + m.get('b') + ':' + m.size
    `)
    testing.expectf(t, v == "1:2:2", "uncurryThis(bind) + Map.set: got %v", v)
}
