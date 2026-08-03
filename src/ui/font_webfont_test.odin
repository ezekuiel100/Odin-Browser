package ui

// Por que a webfont do svelte.dev não aparecia — TRÊS defeitos independentes, em
// camadas diferentes, cada um bastando sozinho para matar a fonte:
//
//   1. `src` relativo do `@font-face` resolvia contra a URL DA PÁGINA, não da
//      FOLHA que o declarou → 404 (o CSS do site mora em /_app/immutable/assets/).
//   2. de várias `@font-face` com a mesma (família, peso, estilo) e
//      `unicode-range` diferente, ficávamos com a PRIMEIRA — que na ordem de
//      quem gera esse CSS é `cyrillic-ext`: uma fonte sem uma letra do texto.
//   3. a família declarada pelo shorthand `font:` nunca chegava ao resolvedor:
//      mandávamos o valor INTEIRO (`500 5.4rem/1.2 "dm serif display", georgia`),
//      cujo 1º item da lista não casa com nada — e a família caía na genérica.
//
// O nº 3 é o mais amplo: vale para QUALQUER site que declare fonte por shorthand.

import "core:testing"
import "core:strings"

@(test)
test_font_shorthand_familia :: proc(t: ^testing.T) {
    // A prova precisa de uma família que classifique DIFERENTE da fallback: com
    // `"Courier New", serif`, extrair certo dá Mono e extrair errado cai no
    // `serif` (o 1º item, com o tamanho grudado, não casa com nada).
    c := test_compute_one(`div{font:400 16px/1.5 "Courier New", serif}`)
    testing.expectf(t, c.font_family == .Mono, "família do shorthand = Courier New (Mono), veio %v", c.font_family)
    testing.expectf(t, abs(c.font_size - 16) < 0.01, "o tamanho continua saindo do shorthand, veio %v", c.font_size)
    testing.expectf(t, abs(c.line_height - 1.5) < 0.01, "e o line-height também, veio %v", c.line_height)

    // barra SOLTA e keyword de estilo antes do tamanho
    c2 := test_compute_one(`div{font:italic 500 32px / 1.2 "Courier New", serif}`)
    testing.expectf(t, c2.font_family == .Mono, "barra solta: família = Mono, veio %v", c2.font_family)
    testing.expect(t, c2.italic, "italic do shorthand continua valendo")

    // sem line-height
    c3 := test_compute_one(`div{font:16px "Courier New", serif}`)
    testing.expectf(t, c3.font_family == .Mono, "sem line-height: família = Mono, veio %v", c3.font_family)

    // o LONGHAND vence o shorthand quando os dois estão na mesma regra
    c4 := test_compute_one(`div{font:16px "Courier New", serif; font-family: Georgia}`)
    testing.expectf(t, c4.font_family == .Serif, "font-family longhand vence, veio %v", c4.font_family)

    // CONTROLE: `font:inherit` não tem tamanho nem família — não pode mexer em nada
    c5 := test_compute_one(`div{font:inherit}`)
    testing.expectf(t, !c5.has_font_family, "font:inherit não define família, veio has=%v", c5.has_font_family)

    // CONTROLE: shorthand sem família (só tamanho) não zera nem inventa família
    c6 := test_compute_one(`div{font:16px}`)
    testing.expectf(t, !c6.has_font_family, "font:16px não define família, veio has=%v", c6.has_font_family)
}

@(test)
test_sheet_chunks :: proc(t: ^testing.T) {
    // A base de cada trecho do css concatenado. Sem marca = tudo com a base da
    // página (comportamento antigo, e o caso dos testes).
    ch := sheet_chunks("a{color:red}", "https://p.com/", context.temp_allocator)
    testing.expectf(t, len(ch) == 1 && ch[0].base == "https://p.com/", "sem marca: 1 trecho com a base da página, veio %v", len(ch))

    // duas folhas de diretórios diferentes
    css := strings.concatenate({
        "a{}",
        "\n", CSS_SHEET_MARK, "https://p.com/assets/x.css", ">>*/\n",
        "@font-face{font-family:F;src:url(./f.woff2)}",
        "\n", CSS_SHEET_MARK, "https://p.com/outro/y.css", ">>*/\n",
        "b{}",
    }, context.temp_allocator)
    ch2 := sheet_chunks(css, "https://p.com/", context.temp_allocator)
    testing.expectf(t, len(ch2) == 3, "esperava 3 trechos, veio %v", len(ch2))
    if len(ch2) == 3 {
        testing.expectf(t, ch2[0].base == "https://p.com/", "1º trecho = base da página, veio %q", ch2[0].base)
        testing.expectf(t, ch2[1].base == "https://p.com/assets/x.css", "2º trecho = folha de assets, veio %q", ch2[1].base)
        testing.expect(t, strings.contains(ch2[1].css, "@font-face"), "o @font-face tem de cair no trecho da folha que o declarou")
        testing.expectf(t, ch2[2].base == "https://p.com/outro/y.css", "3º trecho = a outra folha, veio %q", ch2[2].base)
    }

    // marca truncada (css cortado no meio): não pode perder o resto nem entrar em laço
    ch3 := sheet_chunks(strings.concatenate({"a{}", CSS_SHEET_MARK, "https://p.com/x.css"}, context.temp_allocator),
                        "https://p.com/", context.temp_allocator)
    testing.expectf(t, len(ch3) == 2, "marca truncada: 2 trechos, veio %v", len(ch3))
}
