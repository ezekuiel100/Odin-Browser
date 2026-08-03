package js

// Private fields/methods de classe (#x). Implementação pragmática: o lexer emite
// `#x` como um Ident cujo texto inclui o '#', virando uma chave de propriedade
// "#x" que NUNCA enumera (for-in, Object.keys, JSON.stringify) — "privada".
// Rodar: odin test src/js

import "core:testing"

// ── campos privados ──────────────────────────────────────────────────────────

@(test)
test_private_field_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { #x = 42; getX(){ return this.#x; } }
        new C().getX()
    `)), f64(42))
}

@(test)
test_private_field_mutation :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Counter { #n = 0; inc(){ this.#n++; return this.#n; } }
        var c = new Counter(); c.inc(); c.inc()
    `)), f64(2))
}

@(test)
test_private_field_from_constructor :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Point { #x; #y; constructor(x, y){ this.#x = x; this.#y = y; } sum(){ return this.#x + this.#y; } }
        new Point(3, 4).sum()
    `)), f64(7))
}

@(test)
test_private_independent_instances :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Box { #items = []; add(x){ this.#items.push(x); } count(){ return this.#items.length; } }
        var a = new Box(), b = new Box();
        a.add(1); a.add(2); b.add(9);
        a.count() * 10 + b.count()
    `)), f64(21))
}

@(test)
test_private_and_public_same_name :: proc(t: ^testing.T) {
    // #x e x são chaves DISTINTAS ("#x" vs "x")
    testing.expect_value(t, as_number(run(`
        class C { #x = 1; x = 2; both(){ return this.#x * 10 + this.x; } }
        new C().both()
    `)), f64(12))
}

// ── não-enumerabilidade (privacidade) ────────────────────────────────────────

@(test)
test_private_not_in_object_keys :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class C { #secret = 1; pub = 2; }
        Object.keys(new C()).join(',')
    `), "pub")
}

@(test)
test_private_not_in_for_in :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class C { #secret = 1; pub = 2; }
        var out = ''; for (var k in new C()) out += k + ';'; out
    `), "pub;")
}

@(test)
test_private_not_in_json :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class C { #secret = 99; pub = 2; }
        JSON.stringify(new C())
    `), `{"pub":2}`)
}

// ── métodos privados ─────────────────────────────────────────────────────────

@(test)
test_private_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { #double(x){ return x * 2; } run(v){ return this.#double(v) + 1; } }
        new C().run(10)
    `)), f64(21))
}

@(test)
test_private_method_calls_private_field :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C {
            #base = 100;
            #calc(x){ return this.#base + x; }
            run(){ return this.#calc(5); }
        }
        new C().run()
    `)), f64(105))
}

// ── getter/setter privado ────────────────────────────────────────────────────

@(test)
test_private_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { #v = 7; get #hidden(){ return this.#v * 2; } reveal(){ return this.#hidden; } }
        new C().reveal()
    `)), f64(14))
}

@(test)
test_public_accessor_over_private_field :: proc(t: ^testing.T) {
    // getter/setter públicos encapsulando um campo privado (padrão clássico)
    testing.expect_value(t, as_number(run(`
        class Temp {
            #c = 0;
            get celsius(){ return this.#c; }
            set celsius(v){ this.#c = v; }
        }
        var t = new Temp();
        t.celsius = 25;
        t.celsius
    `)), f64(25))
}

// ── static privado ───────────────────────────────────────────────────────────

@(test)
test_private_static_field :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { static #count = 10; static grab(){ return C.#count; } }
        C.grab()
    `)), f64(10))
}

@(test)
test_private_static_mutation :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Ids { static #next = 0; static gen(){ return ++Ids.#next; } }
        Ids.gen(); Ids.gen(); Ids.gen()
    `)), f64(3))
}
