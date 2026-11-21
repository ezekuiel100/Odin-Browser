package js

import "core:testing"

// ── RegExp ES2022–ES2025: modificadores, flag d, flag v ─────────────────────
// Antes: `(?i:a)` era SyntaxError (o script inteiro morria no literal), `/x/d` não
// tinha `.indices`, `/[\p{L}--[a-z]]/v` lia `--[` como chars soltos, e a flag i
// só sabia caixa ASCII. Cada teste abaixo REPROVA no binário de 20/11/2026.

@(private = "file")
expect_str :: proc(t: ^testing.T, src, want: string, loc := #caller_location) {
    v, ok := run(src).(string)
    testing.expectf(t, ok && v == want, "%s\n  esperado %q, veio %v", src, want, run(src), loc = loc)
}

// ── modificadores (?ims-ims:...) ──

@(test)
test_regex_mod_i_so_dentro_do_grupo :: proc(t: ^testing.T) {
    expect_str(t, `[/(?i:a)b/.test("Ab"), /(?i:a)b/.test("AB"), /(?i:a)b/.test("aB")].join()`, "true,false,false")
}

@(test)
test_regex_mod_remove_i :: proc(t: ^testing.T) {
    expect_str(t, `[/(?-i:a)b/i.test("aB"), /(?-i:a)b/i.test("AB")].join()`, "true,false")
}

@(test)
test_regex_mod_aninhado :: proc(t: ^testing.T) {
    expect_str(t, `[/(?i:a(?-i:b)c)/.test("AbC"), /(?i:a(?-i:b)c)/.test("ABC")].join()`, "true,false")
}

@(test)
test_regex_mod_s_e_m :: proc(t: ^testing.T) {
    expect_str(t, `[/(?s:.)/.test("\n"), /./.test("\n"), /a\n(?m:^b)/.test("a\nb"), /a\n^b/.test("a\nb")].join()`,
               "true,false,true,false")
}

@(test)
test_regex_mod_nao_captura :: proc(t: ^testing.T) {
    expect_str(t, `var m = /(?i:(a))/.exec("A"); m.length + ":" + m[1]`, "2:A")
}

// Erros da gramática: em `new RegExp` lançam SyntaxError; em LITERAL são early
// error (o script nem começa — o `n = 1` não roda).
@(test)
test_regex_mod_erros :: proc(t: ^testing.T) {
    expect_str(t, `
        function se(s) { try { new RegExp(s); return "aceitou " + s; } catch (e) { return e.name; } }
        [se("(?ii:a)"), se("(?i-i:a)"), se("(?-:a)"), se("(?i)a"), se("(?I:a)"), se("(?x:a)")].join()`,
        "SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError")
    expect_str(t, `var n = 0, r; try { eval("n = 1; /(?ii:a)/"); r = "sem erro, n=" + n } catch (e) { r = n + ":" + e.name } r`, "0:SyntaxError")
    // `(?i-:)` é válido (só os DOIS lados vazios é erro)
    expect_str(t, `/(?i-:a)/.test("A") + ""`, "true")
}

// ── flag d ──

@(test)
test_regex_d_indices :: proc(t: ^testing.T) {
    expect_str(t, `var m = /b(c)?(?<x>d)/d.exec("abd");
        JSON.stringify(m.indices) + "|" + (m.indices[1] === undefined) + "|" + JSON.stringify(m.indices.groups.x)`,
        "[[1,3],null,[2,3]]|true|[2,3]")
    expect_str(t, `var m = /a/d.exec("xa"); ("groups" in m.indices) + ":" + m.indices.groups`, "true:undefined")
    expect_str(t, `/a/.exec("a").indices + "|" + /a/d.hasIndices + /a/.hasIndices`, "undefined|truefalse")
}

// ── flags ──

@(test)
test_regex_flags_canonicas_e_validadas :: proc(t: ^testing.T) {
    expect_str(t, `new RegExp("a", "yvgsimd").flags + "|" + String(/x/ig)`, "dgimsvy|/x/gi")
    expect_str(t, `
        function se(f) { try { new RegExp("a", f); return "aceitou " + f; } catch (e) { return e.name; } }
        [se("gg"), se("x"), se("uv")].join()`, "SyntaxError,SyntaxError,SyntaxError")
    expect_str(t, `[/a/v.unicodeSets, /a/u.unicodeSets, /a/v.unicode].join()`, "true,false,false")
}

// ── flag v: operações de conjunto ──

@(test)
test_regex_v_subtracao_e_intersecao :: proc(t: ^testing.T) {
    expect_str(t, `var r = /^[\p{L}--[a-z]]$/v; [r.test("A"), r.test("a"), r.test("é")].join()`, "true,false,true")
    expect_str(t, `[/^[\w&&\d]+$/v.test("123"), /[\w&&\d]/v.test("ab_")].join()`, "true,false")
    expect_str(t, `/[[a-z]--[aeiou]]+/v.exec("xbcdea")[0]`, "xbcd")
}

@(test)
test_regex_v_aninhada_e_negada :: proc(t: ^testing.T) {
    expect_str(t, `[/^[[a-c][x-z]]+$/v.test("abxz"), /[[a-c][x-z]]/v.test("m"), /^[^[a-z]]$/v.test("A"), /^[^[a-z]]$/v.test("q")].join()`,
               "true,false,true,false")
}

@(test)
test_regex_v_strings :: proc(t: ^testing.T) {
    expect_str(t, `var r = /^[\q{abc|d}]$/v; [r.test("abc"), r.test("d"), r.test("ab")].join()`, "true,true,false")
    // a MAIS LONGA primeiro, e a classe com strings pode ser quantificada
    expect_str(t, `/[\q{a|ab|abc}]/v.exec("abcd")[0]`, "abc")
    expect_str(t, `var r = /^[\q{ab}c]{2}$/v; [r.test("abc"), r.test("cab"), r.test("a")].join()`, "true,true,false")
    expect_str(t, `var r = /^[\q{ab|cd}--\q{ab}]$/v; [r.test("cd"), r.test("ab")].join()`, "true,false")
}

// i com subtração segue a spec: o `[a-z]` com i também tira o "A".
@(test)
test_regex_v_i :: proc(t: ^testing.T) {
    expect_str(t, `[/[\p{L}--[a-z]]/vi.test("A"), /[\p{L}--[a-z]]/vi.test("É")].join()`, "false,true")
}

@(test)
test_regex_v_erros_de_sintaxe :: proc(t: ^testing.T) {
    expect_str(t, `
        function se(s) { try { new RegExp(s, "v"); return "aceitou " + s; } catch (e) { return e.name; } }
        [se("[(]"), se("[a-]"), se("[a!!]"), se("[ab&&c]"), se("[a&&b--c]"), se("[a-z&&b]"), se("[z-a]"), se("[^\\q{ab}]")].join()`,
        "SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError")
    // os mesmos símbolos ESCAPADOS valem
    expect_str(t, `[/[\(\-]/v.test("("), /[\(\-]/v.test("-"), /[\&]/v.test("&")].join()`, "true,true,true")
    // em literal é early error
    expect_str(t, `var n = 0, r; try { eval("n = 1; /[(]/v"); r = "sem erro, n=" + n } catch (e) { r = n + ":" + e.name } r`, "0:SyntaxError")
}

// ── i com Unicode ──

@(test)
test_regex_i_unicode :: proc(t: ^testing.T) {
    expect_str(t, `[/ção/i.test("AÇÃO"), /[à-ú]/i.test("É")].join()`, "true,true")
    // Kelvin (U+212A) só casa "k" com u (simple case folding); sem u, não
    expect_str(t, `[/\u212A/i.test("k"), /\u212A/iu.test("k"), /[k]/iu.test("\u212A")].join()`, "false,true,true")
    // range que cruza letra e não-letra: `_` NÃO está em [0-Z] com i
    expect_str(t, `[/[0-Z]/i.test("_"), /[0-Z]/i.test("a")].join()`, "false,true")
    expect_str(t, `[/(?i:\b)/u.test("\u017f"), /\b/u.test("\u017f")].join()`, "true,false")
}

// ── miudezas ──

@(test)
test_regex_escapes_e_terminadores :: proc(t: ^testing.T) {
    expect_str(t, `[/[\b]/.test("\b"), /[\b]/.test("b"), /\cJ/.test("\n"), /[\cJ]/.test("\n")].join()`, "true,false,true,true")
    expect_str(t, `[/./.test("\r"), /./.test("\u2028"), /a$/m.test("a\r\nb")].join()`, "false,false,true")
}

@(test)
test_regex_source_e_tostring :: proc(t: ^testing.T) {
    expect_str(t, `new RegExp("").source + "|" + String(new RegExp("a/b[/]"))`, `(?:)|/a\/b[/]/`)
    // expando própria sombreia o método (antes era descartada em silêncio)
    expect_str(t, `var re = /x/; re.toString = Object.prototype.toString; re.toString()`, "[object RegExp]")
}
