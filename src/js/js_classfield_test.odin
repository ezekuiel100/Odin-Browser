package js

// Class fields (campos de instância e estáticos) — sintaxe `x = init` no corpo da
// classe, incluindo static, herança e a ordem "campos antes do construtor".
// Rodar: odin test src/js

import "core:testing"

// ── campos de instância ──────────────────────────────────────────────────────

@(test)
test_field_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { x = 5 } new C().x")), f64(5))
}

@(test)
test_field_no_init_is_undefined :: proc(t: ^testing.T) {
    // campo sem inicializador existe como propriedade própria, valor undefined
    testing.expect_value(t, run("class C { x } var o=new C(); typeof o.x"), "undefined")
    ok, _ := run("class C { x } new C().hasOwnProperty('x')").(bool)
    testing.expect(t, ok, "campo sem init ainda é propriedade própria")
}

@(test)
test_field_semicolons :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { a = 1; b = 2; } var o=new C(); o.a + o.b")), f64(3))
}

@(test)
test_field_expression_init :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { x = 2 * 10 + 1 } new C().x")), f64(21))
}

@(test)
test_field_order_and_this :: proc(t: ^testing.T) {
    // campos inicializam em ORDEM DE FONTE; um campo pode ler `this.<campo anterior>`
    testing.expect_value(t, as_number(run("class C { a = 1; b = this.a + 1 } new C().b")), f64(2))
}

@(test)
test_field_before_constructor_body :: proc(t: ^testing.T) {
    // campos de instância entram ANTES do corpo do construtor (classe base)
    testing.expect_value(t, as_number(run(`
        class C { x = 10; constructor(){ this.y = this.x + 5 } }
        new C().y
    `)), f64(15))
}

@(test)
test_field_and_constructor_arg :: proc(t: ^testing.T) {
    // o construtor pode sobrescrever um campo com base num argumento
    testing.expect_value(t, as_number(run(`
        class Pt { x = 0; constructor(v){ this.x = v } }
        new Pt(42).x
    `)), f64(42))
}

@(test)
test_field_closure_over_outer :: proc(t: ^testing.T) {
    // inicializador vê o escopo léxico da classe
    testing.expect_value(t, as_number(run("var k = 7; class C { x = k + 1 } new C().x")), f64(8))
}

@(test)
test_field_method_uses_field :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class Counter { n = 0; inc(){ this.n++; return this.n } }
        var c = new Counter(); c.inc(); c.inc(); c.inc()
    `)), f64(3))
}

@(test)
test_two_instances_independent_fields :: proc(t: ^testing.T) {
    // cada instância tem seu próprio campo (não compartilhado no prototype)
    testing.expect_value(t, as_number(run(`
        class Box { items = [] }
        var a = new Box(); var b = new Box();
        a.items.push(1); a.items.push(2);
        b.items.push(9);
        a.items.length * 10 + b.items.length
    `)), f64(21))
}

// ── campos estáticos ─────────────────────────────────────────────────────────

@(test)
test_static_field_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { static count = 42 } C.count")), f64(42))
}

@(test)
test_static_field_not_on_instance :: proc(t: ^testing.T) {
    testing.expect_value(t, run("class C { static count = 1 } typeof (new C().count)"), "undefined")
}

@(test)
test_static_field_refs_class_name :: proc(t: ^testing.T) {
    // um campo static pode referenciar a própria classe pelo nome (já visível)
    testing.expect_value(t, as_number(run("class C { static a = 10; static b = C.a + 5 } C.b")), f64(15))
}

@(test)
test_static_field_via_this :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("class C { static a = 3; static b = this.a * 2 } C.b")), f64(6))
}

@(test)
test_static_field_and_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class M { static base = 100; static bump(x){ return M.base + x } }
        M.bump(1)
    `)), f64(101))
}

// ── herança ──────────────────────────────────────────────────────────────────

@(test)
test_inherited_and_own_fields :: proc(t: ^testing.T) {
    // campos herdados (base) E próprios (derivada) estão presentes na instância
    testing.expect_value(t, as_number(run(`
        class A { a = 1 }
        class B extends A { b = 2 }
        var o = new B(); o.a + o.b
    `)), f64(3))
}

@(test)
test_derived_field_over_super_ctor :: proc(t: ^testing.T) {
    // classe derivada com construtor explícito + super() + campos dos dois níveis
    testing.expect_value(t, as_number(run(`
        class A { base = 10; constructor(){ this.x = 1 } }
        class B extends A { extra = 5; constructor(){ super(); this.y = 2 } }
        var o = new B(); o.base + o.extra + o.x + o.y
    `)), f64(18))
}

// ── membro nomeado "static" e método async ainda funcionam ───────────────────

@(test)
test_class_method_still_parses :: proc(t: ^testing.T) {
    // regressão: método normal continua funcionando junto de campos
    testing.expect_value(t, as_number(run(`
        class C { v = 4; dobro(){ return this.v * 2 } }
        new C().dobro()
    `)), f64(8))
}

@(test)
test_async_method_with_fields :: proc(t: ^testing.T) {
    // método async + campo no mesmo corpo (não confunde o parser)
    testing.expect_value(t, run(`
        class C { v = 1; async load(){ return this.v } }
        typeof new C().load
    `), "function")
}
