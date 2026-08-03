package js

// M162 — `strings.raw` de tagged template (String.raw) + `\u{...}` no regex.
//
//   (1) O array `strings` de um tagged template tinha `raw` apontando para SI
//       MESMO ("cooked == raw"), então String.raw`a\nb` devolvia uma quebra de
//       linha de verdade — o oposto do único motivo de String.raw existir. Agora
//       o lexer guarda os dois trechos em cada token de template (`text` cozido,
//       `raw` cru, ambos fatias do fonte) e eval_tagged monta um array próprio.
//
//   (2) `\u{XXXXX}` no regex só era lido como `\uNNNN` de 4 dígitos fixos, então
//       `/\u{1F600}/u` não casava nada. A forma com chaves é a única que alcança
//       code points acima de U+FFFF sem par surrogate.
//       ⚠️ Só vale com a flag `u`: SEM ela, a spec diz que `\u{2}` é "u repetido
//       2 vezes", e ler as chaves ali mudaria o sentido de padrões que já funcionam.
//       O teste do sentido antigo está aqui para travar isso.

import "core:testing"

@(private = "file")
str_of :: proc(src: string) -> string {
    v := run(src)
    s, _ := v.(string)
    return s
}

// ── (1) String.raw / strings.raw ─────────────────────────────────────────────

@(test)
m162_string_raw_preserva_escapes :: proc(t: ^testing.T) {
    // O `\n` no fonte tem de sair como BARRA + N, não como quebra de linha.
    testing.expect_value(t, str_of("String.raw`a\\nb`"), "a\\nb")
    testing.expect_value(t, str_of("String.raw`a\\tb`"), "a\\tb")
    testing.expect_value(t, str_of("String.raw`C:\\dir\\novo`"), "C:\\dir\\novo")
    testing.expect_value(t, str_of("String.raw`\\u0041`"), "\\u0041")
    testing.expect_value(t, str_of("String.raw`\\\\`"), "\\\\")
}

@(test)
m162_string_raw_com_substituicoes :: proc(t: ^testing.T) {
    testing.expect_value(t, str_of("String.raw`a${1}b`"), "a1b")
    testing.expect_value(t, str_of("String.raw`\\n${1}\\n`"), "\\n1\\n")
    testing.expect_value(t, str_of("var x = 5; String.raw`v=${x}!`"), "v=5!")
    // sem trechos literais nas pontas
    testing.expect_value(t, str_of("String.raw`${1}${2}`"), "12")
}

@(test)
m162_template_normal_continua_cozido :: proc(t: ^testing.T) {
    // O template COMUM (não-tagged) tem de seguir decodificando: é o caminho de
    // 99% do código, e trocar os dois arrays quebraria tudo.
    testing.expect_value(t, str_of("`a\\nb`"), "a\nb")
    testing.expect_value(t, str_of("`\\u0041`"), "A")
    testing.expect_value(t, str_of("`\\t`"), "\t")
    testing.expect_value(t, as_number(run("`a\\nb`.length")), f64(3))
    testing.expect_value(t, str_of("var x = 2; `v${x}`"), "v2")
}

@(test)
m162_tag_recebe_cooked_e_raw_distintos :: proc(t: ^testing.T) {
    // Uma tag qualquer vê os DOIS arrays, com o mesmo comprimento.
    src := `
        function tag(s) { return s[0] + "|" + s.raw[0] + "|" + s.length + "|" + s.raw.length }
        tag` + "`a\\nb`"
    testing.expect_value(t, str_of(src), "a\nb|a\\nb|1|1")
    // com interpolação: 2 chunks dos dois lados
    src2 := `
        function tag(s, v) { return s.raw.join(",") + "#" + v }
        tag` + "`x\\n${7}y`"
    testing.expect_value(t, str_of(src2), "x\\n,y#7")
}

@(test)
m162_raw_e_array_proprio_mas_alinhado :: proc(t: ^testing.T) {
    // lit-html valida o template com `strings.raw` — o array tem de existir, ser
    // um ARRAY, ter o mesmo comprimento, e NÃO ser o mesmo objeto do cozido.
    src := `
        function tag(s) {
            var ok = Array.isArray(s.raw) && s.raw.length === s.length && s.raw !== s;
            return ok ? "ok" : "falhou";
        }
        tag` + "`a\\nb${1}c`"
    testing.expect_value(t, str_of(src), "ok")
    testing.expect_value(t, run("(function(s){ return s.hasOwnProperty('raw') })`x`").(bool), true)
}

// ── (2) \u{...} no regex ─────────────────────────────────────────────────────

@(test)
m162_regex_u_chaves_casa_astral :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/\u{1F600}/u.test("\u{1F600}")`).(bool), true)
    testing.expect_value(t, run(`/\u{1F600}/u.test("x")`).(bool), false)
    // code point do BMP pela forma com chaves
    testing.expect_value(t, run(`/\u{41}/u.test("A")`).(bool), true)
    testing.expect_value(t, run(`/\u{e9}/u.test("é")`).(bool), true)
    // 6 dígitos (limite do espaço de code points)
    testing.expect_value(t, run(`/\u{10FFFF}/u.test("\u{10FFFF}")`).(bool), true)
    // dentro de classe de caracteres
    testing.expect_value(t, run(`/[\u{1F600}\u{1F601}]/u.test("\u{1F601}")`).(bool), true)
    // com quantificador
    testing.expect_value(t, run(`/\u{41}+/u.test("AAA")`).(bool), true)
    // e o match devolve o char certo (no lado Odin o escape de rune é \U + 8 hex)
    testing.expect_value(t, str_of(`"x\u{1F600}y".match(/\u{1F600}/u)[0]`), "\U0001F600")
}

@(test)
m162_regex_u4_digitos_nao_mudou :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/\u0041/.test("A")`).(bool), true)
    testing.expect_value(t, run(`/\u0041/u.test("A")`).(bool), true)
    testing.expect_value(t, run(`/\u00e9/.test("é")`).(bool), true)
    testing.expect_value(t, run(`/\x41/.test("A")`).(bool), true)
    testing.expect_value(t, run(`/[\u0041-\u005A]+/.test("ABC")`).(bool), true)
}

@(test)
m162_regex_sem_flag_u_mantem_sentido_antigo :: proc(t: ^testing.T) {
    // SEM a flag `u`, `\u{2}` é "u repetido exatamente 2 vezes" — ler as chaves
    // como code point aqui mudaria o sentido de um padrão legítimo.
    testing.expect_value(t, run(`/\u{2}/.test("uu")`).(bool), true)
    testing.expect_value(t, run(`/^\u{2}$/.test("uu")`).(bool), true)
    testing.expect_value(t, run(`/\u{2}/.test("\u0002")`).(bool), false)
}

@(test)
m162_regex_u_chaves_malformado_nao_derruba :: proc(t: ^testing.T) {
    // Escape malformado cai no tratamento leniente de sempre: o `\u` vira o literal
    // 'u' e NADA é consumido, sem travar o parser nem estourar. Quando o que sobra
    // não é um quantificador válido, o resto também vira literal:
    testing.expect_value(t, run(`/\u{/u.test("u{")`).(bool), true)
    testing.expect_value(t, run(`/\u{zz}/u.test("u{zz}")`).(bool), true)
    testing.expect_value(t, run(`/\u{}/u.test("u{}")`).(bool), true)

    // ⚠️ DEGRADAÇÃO ANOTADA: quando o que sobra É um quantificador válido, ele é
    // lido como tal — `/\u{110000}/u` vira `/u{110000}/` (u repetido 110000 vezes).
    // O JS real lança SyntaxError aqui (com a flag `u`, escape inválido é erro).
    // Não lançamos: o parser inteiro é tolerante por opção, e um SyntaxError a mais
    // derrubaria bundles que hoje carregam. O que garantimos é que compila e casa
    // NADA, em vez de casar por acidente.
    testing.expect_value(t, run(`/\u{110000}/u.test("u{110000}")`).(bool), false)
    testing.expect_value(t, run(`/\u{110000}/u.test("u")`).(bool), false)
    testing.expect_value(t, run(`/\u{1234567}/u.test("u{1234567}")`).(bool), false)
    // e o valor no limite superior VÁLIDO continua funcionando
    testing.expect_value(t, run(`/\u{10FFFF}/u.test("\u{10FFFF}")`).(bool), true)
}
