package js

// M60 (grupo 2 das sondas): acesso a null/undefined lança TypeError; chamar
// não-função e `new` de não-construtor lançam TypeError nomeado; erros do
// motor e dos construtores têm prototype real (instanceof), toString e stack.
// Rodar: odin test src/js

import "core:testing"

// ── null.x / undefined.x ──────────────────────────────────────────────────────

@(test)
test_null_read_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { null.x; } catch(e){ r = e.name; }
        r
    `).(string), "TypeError")
}

@(test)
test_undefined_read_throws_with_message :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { undefined.foo; } catch(e){ r = e.message; }
        r
    `).(string), "Cannot read properties of undefined (reading 'foo')")
}

@(test)
test_null_write_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { null.x = 1; } catch(e){ r = e.name; }
        r
    `).(string), "TypeError")
}

@(test)
test_undefined_index_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o;
        var r = '';
        try { o['k']; } catch(e){ r = e.name; }
        r
    `).(string), "TypeError")
}

@(test)
test_optional_chaining_still_short_circuits :: proc(t: ^testing.T) {
    // regressão: ?. continua devolvendo undefined sem lançar
    testing.expect_value(t, run(`
        var o = null;
        typeof o?.x + ':' + typeof o?.[0] + ':' + typeof o?.f?.()
    `).(string), "undefined:undefined:undefined")
}

@(test)
test_chained_access_guarded_ok :: proc(t: ^testing.T) {
    // regressão: padrões defensivos com && seguem funcionando
    testing.expect_value(t, run(`
        var o = { a: { b: 2 } };
        (o && o.a && o.a.b) + (o.missing && o.missing.x ? 1 : 0)
    `).(f64), f64(2))
}

// ── chamar não-função / new não-construtor ────────────────────────────────────

@(test)
test_call_undefined_method_throws :: proc(t: ^testing.T) {
    // mensagem no formato do V8: a cadeia inteira do acesso, não só a prop final
    testing.expect_value(t, run(`
        var o = {};
        var r = '';
        try { o.metodoQueNaoExiste(); } catch(e){ r = e.name + '|' + e.message; }
        r
    `).(string), "TypeError|o.metodoQueNaoExiste is not a function")
}

@(test)
test_call_undefined_index_throws :: proc(t: ^testing.T) {
    // callee via .Index — antes caía no genérico "expressão is not a function";
    // agora reconstrói o acesso (chave literal string vira ponto)
    testing.expect_value(t, run(`
        var o = {};
        var r = '';
        try { o['semMetodo'](); } catch(e){ r = e.message; }
        r
    `).(string), "o.semMetodo is not a function")
    // chave não-literal → forma [...]
    testing.expect_value(t, run(`
        var o = {}; var k = 'x';
        var r = '';
        try { o[k](); } catch(e){ r = e.message; }
        r
    `).(string), "o[...] is not a function")
}

@(test)
test_call_non_function_value_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var x = 42;
        var r = '';
        try { x(); } catch(e){ r = e.message; }
        r
    `).(string), "x is not a function")
}

@(test)
test_optional_call_nullish_ok :: proc(t: ^testing.T) {
    // a?.() com a nullish NÃO lança
    testing.expect_value(t, run(`
        var f = null;
        typeof f?.()
    `).(string), "undefined")
}

@(test)
test_new_non_constructor_throws :: proc(t: ^testing.T) {
    // ⚠️ Este teste usava `new ConstrutorInexistente()` e esperava "is not a
    // constructor". Isso CODIFICAVA o bug corrigido no M150: com identificador
    // ausente devolvendo undefined, o `new` era quem reclamava. A spec avalia o
    // callee ANTES, então nome livre inexistente é ReferenceError (o Chrome diz
    // "ConstrutorInexistente is not defined"). Os dois casos agora, separados:
    testing.expect_value(t, run(`
        var r = '', naoConstrutor = 42;
        try { new naoConstrutor(); } catch(e){ r = e.message; }
        r
    `).(string), "naoConstrutor is not a constructor")

    testing.expect_value(t, run(`
        var r = '';
        try { new ConstrutorInexistente(); } catch(e){ r = e.name + ': ' + e.message; }
        r
    `).(string), "ReferenceError: ConstrutorInexistente is not defined")
}

// ── erros com prototype real ──────────────────────────────────────────────────

@(test)
test_engine_error_instanceof :: proc(t: ^testing.T) {
    // erro LANÇADO PELO MOTOR é instanceof TypeError E Error
    testing.expect_value(t, run(`
        var a = false, b = false;
        try { null.x; } catch(e){ a = e instanceof TypeError; b = e instanceof Error; }
        a && b
    `).(bool), true)
}

@(test)
test_user_error_instanceof :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var e = new RangeError('r');
        var t2 = new TypeError('t');
        (e instanceof RangeError) && (e instanceof Error) &&
        !(e instanceof TypeError) && (t2 instanceof TypeError) &&
        (new Error('x') instanceof Error)
    `).(bool), true)
}

@(test)
test_error_to_string_and_stack :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var e = new TypeError('deu ruim');
        e.toString() + '|' + (typeof e.stack === 'string')
    `).(string), "TypeError: deu ruim|true")
}

@(test)
test_error_message_empty :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Error().toString()`).(string), "Error")
}

@(test)
test_reference_error_exists :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var e = new ReferenceError('x não definido');
        (e instanceof ReferenceError) && (e instanceof Error) && e.name === 'ReferenceError'
    `).(bool), true)
}

@(test)
test_thrown_error_watchdogs_still_typed :: proc(t: ^testing.T) {
    // os RangeError do motor (recursão/tempo) também têm instanceof agora
    testing.expect_value(t, run(`
        function rec(){ return rec(); }
        var ok = false;
        try { rec(); } catch(e){ ok = e instanceof RangeError && e instanceof Error; }
        ok
    `).(bool), true)
}

@(test)
test_destructuring_undefined_throws :: proc(t: ^testing.T) {
    // var {a} = undefined → TypeError (spec)
    testing.expect_value(t, run(`
        var r = '';
        try { var o2 = undefined; var x = o2.a; } catch(e){ r = e.name; }
        r
    `).(string), "TypeError")
}
