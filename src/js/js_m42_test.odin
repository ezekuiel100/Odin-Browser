package js

// Bugs de motor achados diagnosticando SPAs React reais (ultra-photo.com):
// (1) método async em object literal quebrava o parsing (vazava o corpo da função);
// (2) faltava o construtor URL (libs de auth validam URL e lançavam);
// (3) reações de Promise síncronas ANINHADAS estouravam a stack em cadeias
//     recursivas/profundas — agora rodam de uma fila plana.
// Rodar: odin test src/js

import "core:testing"
import dom "../dom"

// URL é um global de browser (registrado com os bindings de DOM), então os testes
// de URL rodam via run_with_dom com um Document mínimo.
@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    return run_with_dom(src, root)
}

// ── (1) método async em object literal ──────────────────────────────────────

@(test)
test_async_object_method :: proc(t: ^testing.T) {
    // {async foo(){}} deve parsear como método (função), não quebrar as chaves
    testing.expect_value(t, run("var x={ async foo(e){ return 1 } }; typeof x.foo"), "function")
}

@(test)
test_async_object_method_no_leak :: proc(t: ^testing.T) {
    // ANTES: o corpo de f vazava (return 2 subia ao Program) e f() dava undefined.
    testing.expect_value(t, as_number(run("function f(){ var x={ async m(){ return 1 } }; return 2 } f()")), f64(2))
}

@(test)
test_async_and_normal_methods_mixed :: proc(t: ^testing.T) {
    // async + método normal + getter no mesmo objeto
    testing.expect_value(t, as_number(run(`
        var o = { n: 5, async load(){ return 1 }, get dobro(){ return this.n*2 } };
        (typeof o.load === 'function' ? 1 : 0) + o.dobro
    `)), f64(11))
}

// ── (2) construtor URL ───────────────────────────────────────────────────────

@(test)
test_url_protocol :: proc(t: ^testing.T) {
    testing.expect_value(t, run_dom("new URL('https://api.example.com/p?q=1#h').protocol"), "https:")
}

@(test)
test_url_components :: proc(t: ^testing.T) {
    testing.expect_value(t, run_dom(`
        var u = new URL('https://api.example.com:8080/caminho?q=1#top');
        u.hostname + '|' + u.port + '|' + u.pathname + '|' + u.search + '|' + u.hash + '|' + u.origin
    `), "api.example.com|8080|/caminho|?q=1|#top|https://api.example.com:8080")
}

@(test)
test_url_no_path :: proc(t: ^testing.T) {
    // sem caminho: pathname default "/" e protocol correto (o caso do better-auth)
    testing.expect_value(t, run_dom("var u=new URL('https://api.ultra-photo.com'); u.protocol+u.pathname"), "https:/")
}

@(test)
test_url_relative_base :: proc(t: ^testing.T) {
    testing.expect_value(t, run_dom("new URL('/x', 'https://h.com').href"), "https://h.com/x")
}

// ── (4) Object.prototype.toString ("[object Tipo]") ─────────────────────────

@(test)
test_object_proto_tostring :: proc(t: ^testing.T) {
    testing.expect_value(t, run("Object.prototype.toString.call(100)"), "[object Number]")
    testing.expect_value(t, run("Object.prototype.toString.call('x')"), "[object String]")
    testing.expect_value(t, run("Object.prototype.toString.call(true)"), "[object Boolean]")
    testing.expect_value(t, run("Object.prototype.toString.call([1,2])"), "[object Array]")
    testing.expect_value(t, run("Object.prototype.toString.call(null)"), "[object Null]")
    testing.expect_value(t, run("Object.prototype.toString.call(undefined)"), "[object Undefined]")
    testing.expect_value(t, run("Object.prototype.toString.call({})"), "[object Object]")
    testing.expect_value(t, run("Object.prototype.toString.call(function(){})"), "[object Function]")
}

@(test)
test_tostring_type_detection_no_loop :: proc(t: ^testing.T) {
    // o idioma de detecção de tipo (como o clamp do PostHog) NÃO deve loopar:
    // isNum(100) tem que dar true (senão a recursão do clamp era infinita).
    ok, _ := run(`
        function isNum(e){ return Object.prototype.toString.call(e) == '[object Number]' && e == e; }
        isNum(100) === true && isNum('x') === false && isNum(NaN) === false
    `).(bool)
    testing.expect(t, ok, "detecção de tipo via toString.call deve funcionar")
}

// ── (3) cadeia de Promise profunda não estoura a stack ──────────────────────

@(test)
test_promise_deep_chain_flat :: proc(t: ^testing.T) {
    // ANTES (reações síncronas aninhadas): estourava a guarda de recursão em ~10000.
    // Agora roda de uma fila plana — uma cadeia de 20000 completa sem RangeError.
    testing.expect_value(t, as_number(run(`
        var n = 0;
        function loop(){ n++; if (n >= 20000) return n; return Promise.resolve().then(loop); }
        loop();
        n
    `)), f64(20000))
}

@(test)
test_promise_then_still_works :: proc(t: ^testing.T) {
    // o achatamento não quebrou o encadeamento normal
    testing.expect_value(t, as_number(run(`
        var v = 0;
        Promise.resolve(10).then(function(x){ return x + 5; }).then(function(y){ v = y; });
        v
    `)), f64(15))
}
