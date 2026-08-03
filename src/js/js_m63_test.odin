package js

// M63 (grupo 5 das sondas): accessor com chave computada em object literal
// (`{ get [k](){} }` QUEBRAVA o parse e engolia o resto do script), leitura de
// super.prop (getter herdado com this correto), e bônus: chaves computadas em
// classe (método, campo, accessor, static). Rodar: odin test src/js

import "core:testing"

// ── { get [k](){} } em object literal ─────────────────────────────────────────

@(test)
test_object_computed_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var k = 'x';
        var o = { get [k](){ return 7; } };
        o.x
    `)), f64(7))
}

@(test)
test_object_computed_setter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var k = 'x';
        var o = { set [k](v){ this._v = v * 2; } };
        o.x = 21;
        o._v
    `)), f64(42))
}

@(test)
test_object_computed_getter_does_not_swallow :: proc(t: ^testing.T) {
    // o caso da sonda: código DEPOIS do literal continua vivo
    testing.expect_value(t, run(`
        var k = 'a';
        var o = { get [k](){ return 1; }, b: 2 };
        var depois = 'vivo';
        o.a + ':' + o.b + ':' + depois
    `).(string), "1:2:vivo")
}

@(test)
test_object_computed_pair :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var k = 'temp';
        var o = {
            _c: 10,
            get [k](){ return this._c; },
            set [k](v){ this._c = v; }
        };
        o.temp = o.temp + 5;
        o.temp
    `)), f64(15))
}

// ── super.prop (leitura) ──────────────────────────────────────────────────────

@(test)
test_super_getter_read :: proc(t: ^testing.T) {
    // o caso exato da sonda: super.g (getter) + super.m() juntos
    testing.expect_value(t, run(`
        class A { m(){ return 'a'; } get g(){ return 1; } }
        class B extends A { m(){ return super.g + super.m(); } }
        new B().m()
    `).(string), "1a")
}

@(test)
test_super_getter_uses_current_this :: proc(t: ^testing.T) {
    // o getter herdado roda com this = a INSTÂNCIA (não o proto)
    testing.expect_value(t, as_number(run(`
        class A { get dobro(){ return this.n * 2; } }
        class B extends A { n = 21; ler(){ return super.dobro; } }
        new B().ler()
    `)), f64(42))
}

@(test)
test_super_method_as_value :: proc(t: ^testing.T) {
    // ler super.m sem chamar: devolve a função
    testing.expect_value(t, run(`
        class A { m(){ return 'x'; } }
        class B extends A { tipo(){ return typeof super.m; } }
        new B().tipo()
    `).(string), "function")
}

@(test)
test_super_prop_two_levels :: proc(t: ^testing.T) {
    // sobe a cadeia: getter definido na AVÓ
    testing.expect_value(t, run(`
        class A { get raiz(){ return 'A'; } }
        class B extends A { }
        class C extends B { ler(){ return super.raiz; } }
        new C().ler()
    `).(string), "A")
}

// ── chaves computadas em classe (bônus) ───────────────────────────────────────

@(test)
test_class_computed_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var k = 'soma';
        class C { [k](a, b){ return a + b; } }
        new C().soma(2, 3)
    `)), f64(5))
}

@(test)
test_class_computed_field :: proc(t: ^testing.T) {
    // o caso da sonda classcomputed: class C { [k] = 5 }
    testing.expect_value(t, as_number(run(`
        var k = 'x';
        class C { [k] = 5; }
        new C().x
    `)), f64(5))
}

@(test)
test_class_computed_static_and_accessor :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var m = 'marca', g = 'dobro';
        class C {
            static [m] = 'C!';
            n = 4;
            get [g](){ return this.n * 2; }
        }
        C.marca + ':' + new C().dobro
    `).(string), "C!:8")
}

@(test)
test_class_fixed_members_regression :: proc(t: ^testing.T) {
    // regressão: membros de nome fixo seguem intactos
    testing.expect_value(t, run(`
        class C { x = 1; m(){ return 'm'; } get gg(){ return 'g'; } static s(){ return 's'; } }
        var c = new C();
        c.x + c.m() + c.gg + C.s()
    `).(string), "1mgs")
}
