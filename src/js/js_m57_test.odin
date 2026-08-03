package js

// M57: lookahead (?=)/(?!), backreferences \1/\k<nome>, grupos nomeados
// (?<nome>...) com exec().groups, lookbehind vira SyntaxError, e IteratorClose:
// break em for-of chama iterator.return() (finally de generator roda).
// Rodar: odin test src/js

import "core:testing"

// ── lookahead ─────────────────────────────────────────────────────────────────

@(test)
test_lookahead_positive :: proc(t: ^testing.T) {
    // dígito seguido de 'px' (sem consumir o px)
    testing.expect_value(t, run(`'4px 7em'.match(/\d(?=px)/)[0]`).(string), "4")
}

@(test)
test_lookahead_negative :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'4px 7em'.match(/\d(?!px)/)[0]`).(string), "7")
}

@(test)
test_lookahead_password_idiom :: proc(t: ^testing.T) {
    // o idioma clássico de validação: tem minúscula E dígito
    testing.expect_value(t, run(`
        var re = /^(?=.*[a-z])(?=.*\d).+$/;
        (re.test('abc1') ? 'S' : 'N') + (re.test('abcd') ? 'S' : 'N') + (re.test('1234') ? 'S' : 'N')
    `).(string), "SNN")
}

@(test)
test_lookahead_zero_width :: proc(t: ^testing.T) {
    // não consome: o casamento inteiro é só o \w+
    testing.expect_value(t, run(`'foo:'.match(/\w+(?=:)/)[0]`).(string), "foo")
}

@(test)
test_lookahead_with_quantifier :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/a(?=b)b/.test('ab') && !/a(?=c)b/.test('ab')`).(bool), true)
}

// ── backreferences ────────────────────────────────────────────────────────────

@(test)
test_backref_basic :: proc(t: ^testing.T) {
    // par de aspas casadas
    testing.expect_value(t, run(`'diga "oi" agora'.match(/(["'])(.*?)\1/)[2]`).(string), "oi")
}

@(test)
test_backref_repeated_word :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/(\w+) \1/.test('ola ola') && !/(\w+) \1/.test('ola mundo')`).(bool), true)
}

@(test)
test_backref_uncaptured_is_empty :: proc(t: ^testing.T) {
    // grupo não capturado: \1 casa vazio (spec)
    testing.expect_value(t, run(`/(?:(a))?b\1/.test('b')`).(bool), true)
}

@(test)
test_backref_icase :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/(ab)\1/i.test('abAB')`).(bool), true)
}

// ── grupos nomeados ───────────────────────────────────────────────────────────

@(test)
test_named_group_exec_groups :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var m = /(?<ano>\d{4})-(?<mes>\d{2})/.exec('data: 2026-07-10');
        m.groups.ano + '/' + m.groups.mes
    `).(string), "2026/07")
}

@(test)
test_named_group_still_indexed :: proc(t: ^testing.T) {
    // grupo nomeado também aparece pelo índice
    testing.expect_value(t, run(`/(?<x>a)(b)/.exec('ab')[1] + /(?<x>a)(b)/.exec('ab')[2]`).(string), "ab")
}

@(test)
test_named_backref :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/(?<q>["'])x\k<q>/.test("'x'") && !/(?<q>["'])x\k<q>/.test("'x\"")`).(bool), true)
}

@(test)
test_no_named_groups_no_groups_prop :: proc(t: ^testing.T) {
    // sem grupos nomeados, .groups é undefined (spec)
    testing.expect_value(t, run(`typeof /(\d)/.exec('5').groups`).(string), "undefined")
}

@(test)
test_lookbehind_now_supported :: proc(t: ^testing.T) {
    // lookbehind AGORA é suportado (M86) — compila e casa (era SyntaxError antes).
    testing.expect_value(t, run(`
        var re = new RegExp('(?<=a)b');
        re.test('ab') + ':' + re.test('xb')
    `).(string), "true:false")
}

// ── IteratorClose: break chama iterator.return() ──────────────────────────────

@(test)
test_forof_break_runs_generator_finally :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [];
        function* g(){ try { yield 1; yield 2; yield 3; } finally { log.push('finally'); } }
        for (var v of g()) { log.push(v); if (v === 2) break; }
        log.join(',')
    `).(string), "1,2,finally")
}

@(test)
test_forof_return_runs_generator_finally :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [];
        function* g(){ try { yield 1; } finally { log.push('fim'); } }
        function f(){ for (var v of g()) return 'r' + v; }
        f() + ':' + log.join(',')
    `).(string), "r1:fim")
}

@(test)
test_forof_break_calls_custom_return :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var fechado = false;
        var it = {
            i: 0,
            next: function(){ this.i++; return { value: this.i, done: false }; },
            'return': function(){ fechado = true; return { done: true }; },
            [Symbol.iterator]: function(){ return this; }
        };
        for (var v of it) if (v === 3) break;
        fechado
    `).(bool), true)
}

@(test)
test_forof_completion_does_not_call_return :: proc(t: ^testing.T) {
    // término NATURAL (done) não chama return() (spec)
    testing.expect_value(t, run(`
        var chamado = false;
        function* g(){ yield 1; yield 2; }
        var it = g();
        var orig = it['return'];
        it['return'] = function(){ chamado = true; return orig.call(this); };
        var s = 0;
        for (var v of it) s += v;
        s + ':' + chamado
    `).(string), "3:false")
}
