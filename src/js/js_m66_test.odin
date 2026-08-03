package js

// M66 (2026-07-10): cadeia de bugs que deixava SPAs reais (tradebig/ultra-photo)
// em BRANCO — cada um matava o commit do React com um TypeError na 1ª renderização.
// Descobertos com --diagnose no binário real + breadcrumbs temporários que nomeavam
// o identificador undefined e imprimiam o trecho da fonte minificada ao redor.

import "core:strings"
import "core:testing"
import dom "../dom"

// DOM mínimo (Document>html>head+body) p/ os testes que dependem de navigator/document.
@(private = "file")
build_page_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    mk :: proc(tag: string) -> ^dom.Node {
        n := dom.make_node(.Element)
        n.tag = strings.clone(tag)
        n.attrs = make(map[string]string)
        return n
    }
    html := mk("html"); head := mk("head"); body := mk("body")
    dom.append_child(html, head)
    dom.append_child(html, body)
    dom.append_child(root, html)
    return root
}

// ── back-reference constructor (Classe.prototype.constructor === Classe) ──────
// Sem isto, `instancia.constructor` era undefined e código transpilado fazia
// `obj.constructor.prototype` → "reading 'prototype' of undefined" → tela branca.

@(test)
test_class_instance_constructor :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class Foo {}
        var f = new Foo();
        f.constructor === Foo
    `).(bool), true)
}

@(test)
test_class_instance_constructor_prototype :: proc(t: ^testing.T) {
    // o padrão exato que quebrava (React inputValueTracking / Babel _inherits)
    testing.expect_value(t, run(`
        class Foo { bar(){ return 1; } }
        var f = new Foo();
        f.constructor.prototype === Foo.prototype
    `).(bool), true)
}

@(test)
test_derived_constructor :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class A {}
        class B extends A {}
        var b = new B();
        (b.constructor === B) && (A.prototype.constructor === A)
    `).(bool), true)
}

@(test)
test_constructor_not_enumerable :: proc(t: ^testing.T) {
    // constructor NÃO deve aparecer em for-in / Object.keys (spec: não-enumerável)
    testing.expect_value(t, run(`
        class Foo { m(){} }
        var f = new Foo();
        var ks = [];
        for (var k in f) ks.push(k);
        ks.indexOf('constructor')
    `).(f64), f64(-1))
}

@(test)
test_function_prototype_constructor :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function F(){}
        F.prototype.constructor === F
    `).(bool), true)
}

// ── callback recebe o ARRAY como 3º argumento (spec) ─────────────────────────
// Lucide mergeClasses: u.filter((i,s,c)=> ... c.indexOf(i)===s) — `c` é o array.
// Sem o 3º arg, `c` era undefined → "reading 'indexOf' of undefined".

@(test)
test_filter_receives_array_arg :: proc(t: ^testing.T) {
    // reproduz mergeClasses do Lucide
    testing.expect_value(t, run(`
        var merge = (...u) => u.filter((i,s,c)=> !!i && i.trim() !== "" && c.indexOf(i) === s).join(" ").trim();
        merge("a", "b", "a", "", "c")
    `).(string), "a b c")
}

@(test)
test_map_receives_array_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        [10,20,30].map((x,i,arr) => arr.length).join(",")
    `).(string), "3,3,3")
}

@(test)
test_foreach_receives_array_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var seen = 0;
        [1,2,3].forEach((x,i,arr) => { seen += arr.length; });
        seen
    `).(f64), f64(9))
}

@(test)
test_some_every_find_receive_array_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var ok = [1,2].some((x,i,arr) => arr.length === 2)
              && [1,2].every((x,i,arr) => arr.length === 2)
              && [1,2].find((x,i,arr) => arr.length === 2 && x === 1) === 1
              && [5,6].findIndex((x,i,arr) => arr.length === 2 && x === 6) === 1;
        ok
    `).(bool), true)
}

@(test)
test_reduce_receives_array_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        [1,2,3].reduce((acc,x,i,arr) => acc + arr.length, 0)
    `).(f64), f64(9))
}

// ── reduceRight ──────────────────────────────────────────────────────────────

@(test)
test_reduce_right :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        ["a","b","c"].reduceRight((acc,x) => acc + x, "")
    `).(string), "cba")
}

@(test)
test_reduce_right_no_initial :: proc(t: ^testing.T) {
    // sem valor inicial: começa do último elemento
    testing.expect_value(t, run(`
        [1,2,3,4].reduceRight((acc,x) => acc - x)
    `).(f64), f64(-2)) // ((4-3)-2)-1 = -2
}

@(test)
test_reduce_right_array_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        [1,2,3].reduceRight((acc,x,i,arr) => acc + arr.length, 0)
    `).(f64), f64(9))
}

// ── navigator / document: strings sempre presentes p/ .indexOf ───────────────

@(test)
test_navigator_strings_present :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        (typeof navigator.appVersion === 'string')
        && (typeof navigator.vendor === 'string')
        && (navigator.languages.length >= 1)
        && (navigator.appVersion.indexOf('zzz') === -1)
    `, root).(bool), true)
}

@(test)
test_document_strings_present :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        (typeof document.cookie === 'string')
        && (typeof document.referrer === 'string')
        && (document.readyState === 'complete')
        && (document.cookie.indexOf('x') === -1)
    `, root).(bool), true)
}
