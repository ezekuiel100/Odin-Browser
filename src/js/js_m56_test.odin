package js

// M56: grupo regex da auditoria — atalhos NEGADOS dentro de classe ([\s\S]),
// escapes \uNNNN/\xNN em regex, exec/match com .index/.input (via props
// opcionais em ^Array, que também deram strings.raw ao tagged template).
// Rodar: odin test src/js

import "core:testing"

// ── [\s\S] e atalhos negados em classe ────────────────────────────────────────

@(test)
test_class_s_S_matches_anything :: proc(t: ^testing.T) {
    // o idioma clássico de "qualquer char inclusive \n" (minifiers usam muito)
    testing.expect_value(t, run(`/a[\s\S]b/.test('a\nb') && /a[\s\S]b/.test('axb')`).(bool), true)
}

@(test)
test_class_s_S_multiline_capture :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'x<1\n2>y'.match(/<([\s\S]*)>/)[1]`).(string), "1\n2")
}

@(test)
test_class_S_alone :: proc(t: ^testing.T) {
    // [\S] = não-whitespace
    testing.expect_value(t, run(`/[\S]/.test('a') && !/[\S]/.test(' ')`).(bool), true)
}

@(test)
test_class_D_alone :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/[\D]/.test('x') && !/[\D]/.test('7')`).(bool), true)
}

@(test)
test_class_negated_outer_with_shorthand :: proc(t: ^testing.T) {
    // [^\S] = "não não-espaço" = espaço
    testing.expect_value(t, run(`/[^\S]/.test(' ') && !/[^\S]/.test('a')`).(bool), true)
}

@(test)
test_class_positive_shorthand_still_works :: proc(t: ^testing.T) {
    // regressão: [\d-a] e afins seguem funcionando
    testing.expect_value(t, run(`/[\da]/.test('5') && /[\da]/.test('a') && !/[\da]/.test('b')`).(bool), true)
}

// ── \uNNNN / \xNN em regex ────────────────────────────────────────────────────

@(test)
test_regex_unicode_escape :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/\u0041/.test('A') && !/\u0041/.test('B')`).(bool), true)
}

@(test)
test_regex_hex_escape :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/\x41\x42/.test('AB')`).(bool), true)
}

@(test)
test_regex_unicode_escape_in_class :: proc(t: ^testing.T) {
    // range por escape dentro de classe: [A-C] = A-C
    testing.expect_value(t, run(`/[\u0041-\u0043]/.test('B') && !/[\u0041-\u0043]/.test('D')`).(bool), true)
}

@(test)
test_regex_incomplete_u_is_literal :: proc(t: ^testing.T) {
    // \u sem 4 hex: leniente, vira 'u' literal (como escapes desconhecidos)
    testing.expect_value(t, run(`/\uzz/.test('uzz')`).(bool), true)
}

// ── exec/match com .index/.input ──────────────────────────────────────────────

@(test)
test_exec_index_and_input :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var m = /world/.exec('hello world');
        m.index + ':' + m.input + ':' + m[0]
    `).(string), "6:hello world:world")
}

@(test)
test_exec_global_loop_with_index :: proc(t: ^testing.T) {
    // o padrão clássico: while((m = re.exec(s))) usando m.index
    testing.expect_value(t, run(`
        var re = /a/g, s = 'a-a--a', idxs = [], m;
        while ((m = re.exec(s)) !== null) idxs.push(m.index);
        idxs.join(',')
    `).(string), "0,2,5")
}

@(test)
test_match_no_g_has_index :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'xxabc'.match(/abc/).index`)), f64(2))
}

@(test)
test_array_custom_prop :: proc(t: ^testing.T) {
    // props não-índice em array (agora suportadas) não mexem nos items
    testing.expect_value(t, run(`
        var a = [1,2];
        a.marca = 'ok';
        a.marca + ':' + a.length + ':' + JSON.stringify(a)
    `).(string), "ok:2:[1,2]")
}

@(test)
test_tagged_strings_raw :: proc(t: ^testing.T) {
    // strings.raw existe no tagged template (aproximação cooked==raw)
    testing.expect_value(t, run(`
        function tag(s, v){ return s.raw[0] + v + s.raw[1]; }
        tag` + "`a${9}b`" + `
    `).(string), "a9b")
}
