package css

// `unicode-range` — não fazemos subsetting, mas precisamos saber se uma face tem
// as letras latinas básicas: quem gera CSS de webfont publica a MESMA (família,
// peso, estilo) uma vez por bloco Unicode, e como só guardamos UMA face por
// combinação, ficar com a primeira significava ficar com o cirílico.

import "core:testing"

@(test)
test_unicode_range_cobre_latim :: proc(t: ^testing.T) {
    chk :: proc(t: ^testing.T, v: string, esperado: bool) {
        got := range_cobre_latim(v)
        testing.expectf(t, got == esperado, "range_cobre_latim(%q) = %v, esperava %v", v, got, esperado)
    }
    // os subsets reais que aparecem no CSS do Google Fonts / Fontsource
    chk(t, "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+2000-206F", true)  // latin
    chk(t, "U+0100-02AF,U+0304,U+0308,U+1E00-1EFF,U+2020", false)           // latin-ext
    chk(t, "U+0301,U+0400-045F,U+0490-0491,U+2116", false)                  // cyrillic
    chk(t, "U+1F00-1FFF", false)                                            // greek-ext
    chk(t, "U+0102-0103,U+1EA0-1EF9,U+20AB", false)                         // vietnamese
    // formas da sintaxe (css-fonts §4.5)
    chk(t, "U+41", true)          // ponto único = 'A'
    chk(t, "U+42", false)         // ponto único vizinho
    chk(t, "U+0041-005A", true)   // faixa
    chk(t, "U+00??", true)        // curinga 0000..00FF
    chk(t, "U+01??", false)       // curinga que não pega o 'A'
    chk(t, "u+0000-00ff", true)   // minúsculas
    chk(t, "U+0400-045F, U+0041", true) // basta UMA faixa da lista cobrir
    chk(t, "lixo", false)         // valor inválido não afirma cobertura
}

@(test)
test_face_latin_no_parse :: proc(t: ^testing.T) {
    // Sem o descritor, a face cobre tudo (é o default da spec).
    faces := parse_faces_only(`@font-face{font-family:F;src:url(a.woff2)}`)
    defer free_faces(&faces)
    testing.expect(t, len(faces) == 1, "esperava 1 face")
    if len(faces) == 1 do testing.expect(t, faces[0].latin, "sem unicode-range, a face cobre o latim")

    // Com o descritor, o parse decide.
    f2 := parse_faces_only(
        `@font-face{font-family:F;src:url(cyr.woff2);unicode-range:U+0400-045F}` +
        `@font-face{font-family:F;src:url(lat.woff2);unicode-range:U+0000-00FF}`)
    defer free_faces(&f2)
    testing.expectf(t, len(f2) == 2, "esperava 2 faces, veio %v", len(f2))
    if len(f2) == 2 {
        testing.expect(t, !f2[0].latin, "a face cirílica NÃO cobre o latim")
        testing.expect(t, f2[1].latin, "a face latina cobre")
    }
}
