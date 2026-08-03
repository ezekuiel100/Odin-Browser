package js

// M167 — índices de string em CODE UNITS UTF-16.
//
// O JS mede strings em unidades UTF-16; o motor ARMAZENA UTF-8 e contava CODE
// POINTS. Idêntico no BMP inteiro (acentos, CJK, ...), divergia no astral:
// `"😀".length` dava 1 em vez de 2. Os 5 helpers `str_r*` são a única camada de
// tradução, então `length`, `s[i]`, slice/substring/indexOf, `.index` de regex e
// `lastIndex` acertaram todos de uma vez.
//
// ⚠️ DEGRADAÇÃO ANOTADA (testada em m167_par_surrogate_e_atomico): metade de um par
// surrogate não é representável em UTF-8, então um índice que cai NO MEIO de um par
// arredonda para a fronteira seguinte e o par é tratado atomicamente. `slice(0,1)`
// de um emoji devolve o emoji, não o high surrogate solto. O que isso preserva — e
// é o que importa na prática — é `s.slice(0,i) + s.slice(i) === s` para todo i.
// `charCodeAt` NÃO sofre disso: devolve um número, e o surrogate correto.
//
// Os literais de emoji são montados por String.fromCodePoint para o FONTE deste
// arquivo ficar ASCII puro (char invisível/astral no fonte é armadilha recorrente).

import "core:testing"

@(private = "file")
EMOJI :: `String.fromCodePoint(0x1F600)` // 😀 — 1 code point, 2 code units

@(private = "file")
run_s :: proc(src: string) -> string {
    v := run(src)
    s, _ := v.(string)
    return s
}

// ── length ───────────────────────────────────────────────────────────────────

@(test)
m167_length_conta_code_units :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(EMOJI + `.length`)), f64(2))
    testing.expect_value(t, as_number(run(`(` + EMOJI + ` + "a").length`)), f64(3))
    testing.expect_value(t, as_number(run(`("a" + ` + EMOJI + ` + "b").length`)), f64(4))
    testing.expect_value(t, as_number(run(`(` + EMOJI + ` + ` + EMOJI + `).length`)), f64(4))
}

@(test)
m167_bmp_inalterado :: proc(t: ^testing.T) {
    // A parte que NÃO pode mudar: todo o BMP contava certo antes e continua.
    testing.expect_value(t, as_number(run(`"abc".length`)), f64(3))
    testing.expect_value(t, as_number(run(`"ação".length`)), f64(4))
    testing.expect_value(t, as_number(run(`"中文".length`)), f64(2))
    testing.expect_value(t, as_number(run(`"".length`)), f64(0))
    testing.expect_value(t, run_s(`"ação"[1]`), "ç")
    testing.expect_value(t, run_s(`"ação".slice(1,3)`), "çã")
    testing.expect_value(t, run_s(`"ação".charAt(3)`), "o")
    testing.expect_value(t, as_number(run(`"ação".charCodeAt(1)`)), f64(231)) // ç
    testing.expect_value(t, as_number(run(`"ação".indexOf("ã")`)), f64(2))
    testing.expect_value(t, run_s(`"ação".toUpperCase()`), "AÇÃO")
    testing.expect_value(t, run_s(`"中文".split("").join("|")`), "中|文")
}

// ── charCodeAt / codePointAt ─────────────────────────────────────────────────

@(test)
m167_char_code_at_devolve_surrogate :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(EMOJI + `.charCodeAt(0)`)), f64(0xD83D))
    testing.expect_value(t, as_number(run(EMOJI + `.charCodeAt(1)`)), f64(0xDE00))
    // fora do range → NaN
    testing.expect_value(t, run(EMOJI + `.charCodeAt(2) !== ` + EMOJI + `.charCodeAt(2)`).(bool), true)
}

@(test)
m167_code_point_at_devolve_code_point :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(EMOJI + `.codePointAt(0)`)), f64(0x1F600))
    // no índice do 2º unit, a spec devolve o low surrogate solto
    testing.expect_value(t, as_number(run(EMOJI + `.codePointAt(1)`)), f64(0xDE00))
    testing.expect_value(t, as_number(run(`"a".codePointAt(0)`)), f64(97))
    testing.expect_value(t, as_number(run(`"ç".codePointAt(0)`)), f64(231))
    // charCodeAt e codePointAt PRECISAM diferir agora (eram o mesmo proc)
    testing.expect_value(t, run(EMOJI + `.charCodeAt(0) !== ` + EMOJI + `.codePointAt(0)`).(bool), true)
}

@(test)
m167_from_char_code_recombina_par :: proc(t: ^testing.T) {
    // fromCharCode recebe CODE UNITS: um par adjacente vira um emoji só
    testing.expect_value(t, as_number(run(`String.fromCharCode(0xD83D, 0xDE00).length`)), f64(2))
    testing.expect_value(t, as_number(run(`String.fromCharCode(0xD83D, 0xDE00).codePointAt(0)`)), f64(0x1F600))
    testing.expect_value(t, run(`String.fromCharCode(0xD83D, 0xDE00) === ` + EMOJI).(bool), true)
    // fromCodePoint recebe CODE POINTS: sem recombinar
    testing.expect_value(t, as_number(run(`String.fromCodePoint(0x1F600).length`)), f64(2))
    testing.expect_value(t, as_number(run(`String.fromCodePoint(65, 66).length`)), f64(2))
    testing.expect_value(t, run_s(`String.fromCharCode(65, 66, 67)`), "ABC")
    // ida e volta
    testing.expect_value(t, run(`String.fromCharCode(` + EMOJI + `.charCodeAt(0), ` + EMOJI + `.charCodeAt(1)) === ` + EMOJI).(bool), true)
}

// ── fatiamento ───────────────────────────────────────────────────────────────

@(test)
m167_slice_em_fronteiras_normais :: proc(t: ^testing.T) {
    src :: `var s = "ab" + ` + EMOJI + ` + "cd";` // length 6: a b [emoji x2] c d
    testing.expect_value(t, as_number(run(src + ` s.length`)), f64(6))
    testing.expect_value(t, run_s(src + ` s.slice(0,2)`), "ab")
    testing.expect_value(t, run_s(src + ` s.slice(4)`), "cd")
    testing.expect_value(t, run_s(src + ` s.substring(0,2)`), "ab")
    testing.expect_value(t, as_number(run(src + ` s.indexOf("c")`)), f64(4))
    testing.expect_value(t, as_number(run(src + ` s.indexOf("cd")`)), f64(4))
    testing.expect_value(t, run(src + ` s.slice(2,4) === ` + EMOJI).(bool), true)
}

@(test)
m167_par_surrogate_e_atomico :: proc(t: ^testing.T) {
    // A degradação: um índice no meio do par arredonda p/ a fronteira seguinte,
    // então slice(0,1) devolve o emoji inteiro em vez do high surrogate solto.
    testing.expect_value(t, run(EMOJI + `.slice(0,1) === ` + EMOJI).(bool), true)
    // MAS a propriedade que importa se mantém para TODO índice:
    src := `
        var s = "ab" + String.fromCodePoint(0x1F600) + "cd";
        var ruins = [];
        for (var i = 0; i <= s.length; i++) {
            if (s.slice(0,i) + s.slice(i) !== s) ruins.push(i);
        }
        ruins.length;
    `
    testing.expect_value(t, as_number(run(src)), f64(0))
}

// ── regex e outros consumidores dos mesmos helpers ───────────────────────────

@(test)
m167_indices_de_regex_acompanham :: proc(t: ^testing.T) {
    // `.index` sai dos mesmos helpers, então tem de contar code units também
    testing.expect_value(t, as_number(run(`("ab" + String.fromCodePoint(0x1F600) + "cd").match(/cd/).index`)), f64(4))
    testing.expect_value(t, as_number(run(`"abc".match(/c/).index`)), f64(2))
    // lastIndex de /g avança em code units
    src := `
        var re = /x/g;
        var s = String.fromCodePoint(0x1F600) + "x";
        re.exec(s);
        re.lastIndex;
    `
    testing.expect_value(t, as_number(run(src)), f64(3))
    testing.expect_value(t, as_number(run(`String.fromCodePoint(0x1F600).replace(/a/, "b").length`)), f64(2))
}

@(test)
m167_metodos_que_usam_length :: proc(t: ^testing.T) {
    // padStart/repeat/at/split contam pelo mesmo str_rlen
    testing.expect_value(t, as_number(run(`String.fromCodePoint(0x1F600).padStart(4, "-").length`)), f64(4))
    testing.expect_value(t, as_number(run(`String.fromCodePoint(0x1F600).repeat(2).length`)), f64(4))
    testing.expect_value(t, run(`String.fromCodePoint(0x1F600).at(0) === String.fromCodePoint(0x1F600)`).(bool), true)
    testing.expect_value(t, run_s(`"abc".at(-1)`), "c")
    testing.expect_value(t, as_number(run(`("a" + String.fromCodePoint(0x1F600)).split("").length`)), f64(2)) // split por code point
    testing.expect_value(t, as_number(run(`JSON.stringify(String.fromCodePoint(0x1F600)).length`)), f64(4)) // 2 aspas + 2 units
}
