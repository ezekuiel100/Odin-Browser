package js

// M53: dois bugs do interp achados na auditoria de 2026-07-08.
// (1) Getter herdado vencia data property própria — get_member varria a cadeia
//     inteira atrás de getters antes de olhar as props; agora varre nível a nível
//     (o mais próximo vence). Espelho no set_member: data prop num nível mais
//     próximo sombreia setter herdado.
// (2) Iterador com `next` no protótipo (class It { next(){...} }) não era
//     reconhecido — is_iterator_obj/call-sites só olhavam props próprias; agora
//     iterator_next_fn sobe a cadeia.
// Rodar: odin test src/js

import "core:testing"

// ── (1) accessor herdado vs data property própria ─────────────────────────────

@(test)
test_own_field_shadows_inherited_getter :: proc(t: ^testing.T) {
    // o caso exato da auditoria: class B extends A { x=5 } deve ler 5, não o getter de A
    testing.expect_value(t, as_number(run(`
        class A { get x(){ return 1; } }
        class B extends A { x = 5; }
        new B().x
    `)), f64(5))
}

@(test)
test_own_prop_shadows_inherited_getter :: proc(t: ^testing.T) {
    // prop own criada no construtor também sombreia o getter herdado
    testing.expect_value(t, as_number(run(`
        class A { get x(){ return 1; } }
        class B extends A { constructor(){ super(); this.y = 7; } }
        var b = new B();
        b.x + b.y
    `)), f64(8)) // x ainda vem do getter (1), y é own (7)
}

@(test)
test_inherited_getter_still_works :: proc(t: ^testing.T) {
    // sem prop own, o getter herdado continua funcionando (não regrediu)
    testing.expect_value(t, as_number(run(`
        class A { get x(){ return 42; } }
        class B extends A { }
        new B().x
    `)), f64(42))
}

@(test)
test_getter_shadows_prototype_prop :: proc(t: ^testing.T) {
    // getter num nível MAIS PRÓXIMO vence prop de nível mais distante
    testing.expect_value(t, as_number(run(`
        class A { }
        class B extends A { get x(){ return 9; } }
        A.prototype.x = 1;
        new B().x
    `)), f64(9))
}

@(test)
test_own_field_bypasses_inherited_setter_on_init :: proc(t: ^testing.T) {
    // class field usa DefineOwnProperty: NÃO invoca o setter herdado
    testing.expect_value(t, as_number(run(`
        class A { set x(v){ this.trap = v; } }
        class B extends A { x = 5; }
        var b = new B();
        (b.trap === undefined ? 100 : 0) + b.x
    `)), f64(105))
}

@(test)
test_own_prop_shadows_inherited_setter_on_write :: proc(t: ^testing.T) {
    // depois que existe data prop own, escrever nela NÃO chama o setter herdado
    testing.expect_value(t, as_number(run(`
        class A { set x(v){ this.calls = (this.calls || 0) + 1; } }
        class B extends A { x = 1; }
        var b = new B();
        b.x = 2;
        b.x + (b.calls === undefined ? 10 : 0)
    `)), f64(12))
}

@(test)
test_inherited_setter_still_works :: proc(t: ^testing.T) {
    // sem prop own, o setter herdado continua interceptando (não regrediu)
    testing.expect_value(t, as_number(run(`
        class A { set x(v){ this._v = v * 2; } }
        class B extends A { }
        var b = new B(); b.x = 5; b._v
    `)), f64(10))
}

// ── (2) iterador com next no protótipo ────────────────────────────────────────

@(test)
test_forof_iterator_next_on_prototype :: proc(t: ^testing.T) {
    // class com next() no prototype + Symbol.iterator devolvendo this
    testing.expect_value(t, as_number(run(`
        class Counter {
            i = 0;
            next(){ this.i++; return { value: this.i, done: this.i > 3 }; }
            [Symbol.iterator](){ return this; }
        }
        var sum = 0;
        for (var v of new Counter()) sum += v;
        sum
    `)), f64(6)) // 1+2+3
}

@(test)
test_spread_iterator_next_on_prototype :: proc(t: ^testing.T) {
    // spread materializa via iterate_protocol — mesmo caminho, next no proto
    testing.expect_value(t, as_number(run(`
        class Two {
            n = 0;
            next(){ this.n++; return { value: this.n * 10, done: this.n > 2 }; }
            [Symbol.iterator](){ return this; }
        }
        var arr = [...new Two()];
        arr[0] + arr[1]
    `)), f64(30)) // 10+20
}

@(test)
test_yield_star_iterator_next_on_prototype :: proc(t: ^testing.T) {
    // yield* delegando a um iterador de classe
    testing.expect_value(t, as_number(run(`
        class One {
            done = false;
            next(){ if (this.done) return { value: undefined, done: true };
                    this.done = true; return { value: 7, done: false }; }
            [Symbol.iterator](){ return this; }
        }
        function* g(){ yield* new One(); yield 3; }
        var s = 0;
        for (var v of g()) s += v;
        s
    `)), f64(10)) // 7+3
}

@(test)
test_forof_plain_object_next_on_proto_chain :: proc(t: ^testing.T) {
    // iterador "cru" (sem Symbol.iterator) com next herdado via Object.create
    testing.expect_value(t, as_number(run(`
        var base = { next: function(){ this.i = (this.i || 0) + 1;
                                       return { value: this.i, done: this.i > 2 }; } };
        var it = Object.create(base);
        var s = 0;
        for (var v of it) s += v;
        s
    `)), f64(3)) // 1+2
}

@(test)
test_forof_own_next_still_works :: proc(t: ^testing.T) {
    // regressão: iterador com next em props próprias (caminho antigo)
    testing.expect_value(t, as_number(run(`
        var it = { i: 0, next: function(){ this.i++;
                                           return { value: this.i, done: this.i > 2 }; } };
        var s = 0;
        for (var v of it) s += v;
        s
    `)), f64(3))
}
