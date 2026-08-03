package js

// M58: índices de string por CODE POINT (aproximação do UTF-16 do JS sobre
// UTF-8). length/charAt/charCodeAt/at/s[i]/slice/substring/indexOf/lastIndexOf/
// padStart/split('')/search/match.index/exec lastIndex agora contam runes.
// Divergência deliberada: não-BMP (emoji) conta 1 (spec: 2, par surrogate).
// Rodar: odin test src/js

import "core:testing"

@(test)
test_utf8_length :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'café'.length`)), f64(4))
    testing.expect_value(t, as_number(run(`'ação'.length`)), f64(4))
    testing.expect_value(t, as_number(run(`'abc'.length`)), f64(3)) // ASCII intacto
}

@(test)
test_utf8_index_access :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'café'[3]`).(string), "é")
    testing.expect_value(t, run(`'café'[0]`).(string), "c")
    testing.expect_value(t, run(`typeof 'abc'[9]`).(string), "undefined")
}

@(test)
test_utf8_char_at :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'ação'.charAt(1)`).(string), "ç")
    testing.expect_value(t, run(`'ação'.charAt(99)`).(string), "")
}

@(test)
test_utf8_char_code_at :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'ção'.charCodeAt(0)`)), f64(231)) // ç
    testing.expect_value(t, as_number(run(`'abc'.charCodeAt(1)`)), f64(98))  // b
}

@(test)
test_utf8_at_negative :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'café'.at(-1)`).(string), "é")
}

@(test)
test_utf8_slice_substring :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'café da manhã'.slice(0, 4)`).(string), "café")
    testing.expect_value(t, run(`'café'.slice(-1)`).(string), "é")
    testing.expect_value(t, run(`'coração'.substring(4, 7)`).(string), "ção")
}

@(test)
test_utf8_index_of :: proc(t: ^testing.T) {
    // o índice devolvido serve p/ slice (consistência rune↔rune)
    testing.expect_value(t, as_number(run(`'até já'.indexOf('já')`)), f64(4))
    testing.expect_value(t, run(`var s='até já'; s.slice(s.indexOf('já'))`).(string), "já")
    testing.expect_value(t, as_number(run(`'ééa'.lastIndexOf('a')`)), f64(2))
}

@(test)
test_utf8_split_empty :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'café'.split('').join('|')`).(string), "c|a|f|é")
    testing.expect_value(t, as_number(run(`'café'.split('').length`)), f64(4))
}

@(test)
test_utf8_pad :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'é'.padStart(3, '-')`).(string), "--é")
    testing.expect_value(t, as_number(run(`'é'.padStart(3).length`)), f64(3))
    testing.expect_value(t, run(`'x'.padEnd(3, 'ç')`).(string), "xçç")
}

@(test)
test_utf8_regex_index :: proc(t: ^testing.T) {
    // .index em runes: serve direto no slice
    testing.expect_value(t, run(`
        var s = 'préço: 42';
        var m = /\d+/.exec(s);
        m.index + ':' + s.slice(m.index)
    `).(string), "7:42")
}

@(test)
test_utf8_regex_global_loop :: proc(t: ^testing.T) {
    // lastIndex em runes: loop global não trava nem pula em texto acentuado
    testing.expect_value(t, run(`
        var re = /a/g, s = 'ávaliação', idxs = [], m;
        while ((m = re.exec(s)) !== null) idxs.push(m.index);
        idxs.join(',')
    `).(string), "2,5") // á-v-a-l-i-a-ç-ã-o: 'a' nos índices 2 e 5
}

@(test)
test_utf8_search :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'café 42'.search(/\d/)`)), f64(5))
}

@(test)
test_utf8_for_of_still_runes :: proc(t: ^testing.T) {
    // regressão M21: for-of por code points continua
    testing.expect_value(t, as_number(run(`
        var n = 0;
        for (var c of 'café') n++;
        n
    `)), f64(4))
}

@(test)
test_from_char_code :: proc(t: ^testing.T) {
    // 99='c', 231='ç', 227='ã', 111='o'
    testing.expect_value(t, run(`String.fromCharCode(99, 231, 227, 111)`).(string), "cção")
}
