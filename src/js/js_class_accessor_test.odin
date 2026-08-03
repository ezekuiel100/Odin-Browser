package js

// Getters/setters DENTRO de classe: `get x(){}` / `set x(v){}`, instância e static,
// com herança e sobrescrita. Getters/setters de instância vivem nos maps do
// prototype; os static, nos maps da própria construtora (^Function).
// Rodar: odin test src/js

import "core:testing"

// ── getters/setters de instância ─────────────────────────────────────────────

@(test)
test_class_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { get x(){ return 42; } } new C().x")), f64(42))
}

@(test)
test_class_setter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { set x(val){ this._v = val * 2; } }
        var c = new C(); c.x = 5; c._v
    `)), f64(10))
}

@(test)
test_class_getter_uses_field :: proc(t: ^testing.T) {
    // getter lê um campo de instância via this
    testing.expect_value(t, as_number(run(`
        class C { base = 10; get doubled(){ return this.base * 2; } }
        new C().doubled
    `)), f64(20))
}

@(test)
test_class_get_set_pair :: proc(t: ^testing.T) {
    // par get/set de mesmo nome (padrão "propriedade computada")
    testing.expect_value(t, as_number(run(`
        class Temp {
            constructor(c){ this._c = c; }
            get f(){ return this._c * 9/5 + 32; }
            set f(v){ this._c = (v - 32) * 5/9; }
        }
        var t = new Temp(0);
        var a = t.f;    // 32
        t.f = 212;      // _c vira 100
        a * 1000 + t._c
    `)), f64(32100))
}

@(test)
test_class_setter_and_getter_same_name :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Box {
            constructor(){ this._items = []; }
            get value(){ return this._items.length; }
            set value(n){ for (var i=0;i<n;i++) this._items.push(i); }
        }
        var b = new Box();
        b.value = 3;   // empurra 0,1,2
        b.value        // 3
    `)), f64(3))
}

// ── convivência com métodos e campos ─────────────────────────────────────────

@(test)
test_class_getter_with_methods_fields :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C {
            n = 3;
            get squared(){ return this.n * this.n; }
            add(x){ return this.n + x; }
        }
        var c = new C();
        c.squared * 100 + c.add(7)   // 900 + 10
    `)), f64(910))
}

@(test)
test_class_method_named_get :: proc(t: ^testing.T) {
    // `get(){}` é um método normal chamado "get" (não é um getter)
    testing.expect_value(t, as_number(run("class C { get(){ return 5; } } new C().get()")), f64(5))
}

// ── herança ──────────────────────────────────────────────────────────────────

@(test)
test_class_inherited_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class A { get x(){ return 7; } }
        class B extends A {}
        new B().x
    `)), f64(7))
}

@(test)
test_class_getter_override :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class A { get x(){ return 1; } }
        class B extends A { get x(){ return 2; } }
        new A().x * 10 + new B().x
    `)), f64(12))
}

// ── getters/setters static ───────────────────────────────────────────────────

@(test)
test_class_static_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { static get version(){ return 3; } } C.version")), f64(3))
}

@(test)
test_class_static_setter :: proc(t: ^testing.T) {
    // o setter static grava numa prop static da própria classe
    testing.expect_value(t, as_number(run(`
        class C { static set v(x){ C._stored = x * 10; } }
        C.v = 9; C._stored
    `)), f64(90))
}

@(test)
test_class_static_getter_computes :: proc(t: ^testing.T) {
    // getter static referenciando um campo static
    testing.expect_value(t, as_number(run(`
        class C { static count = 5; static get doubled(){ return C.count * 2; } }
        C.doubled
    `)), f64(10))
}
