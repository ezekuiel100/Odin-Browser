package ui

// M172 — cor FUNCIONAL em borda/outline era descartada pelo tokenizador.
//
// Raiz: `border-color`, o shorthand `border`, `border-<lado>` e `outline` fatiavam
// o valor com strings.fields (split por ESPAÇO). Uma cor funcional moderna tem
// espaços DENTRO dos parênteses — `oklch(0.968 0.007 247.896)`, `rgb(241 245 249)`,
// `hsl(210 40% 96%)` — então o valor virava 3 tokens inválidos, nenhum parseava como
// cor e a declaração inteira era ignorada. O lado caía no fallback (currentColor),
// pintando borda PRETA onde o autor pediu cinza-quase-branco.
//
// Alcance: o Tailwind v4 escreve TODA cor em oklch(), então isso atingia toda
// `border-*` de todo site feito com ele (foi o card do tradebig.com.br, cuja borda
// real é `1px solid oklch(0.968 0.007 247.896)` = slate-100).
//
// Fix: split_top_level (agrupa parênteses), que já existia no mesmo arquivo.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// distância máxima por canal entre duas cores 0x00RRGGBB.
@(private = "file")
rgb_dist :: proc(a, b: u32) -> u32 {
    d :: proc(x, y: u32) -> u32 { return x > y ? x - y : y - x }
    return max(d((a >> 16) & 0xff, (b >> 16) & 0xff),
               d((a >>  8) & 0xff, (b >>  8) & 0xff),
               d( a        & 0xff,  b        & 0xff))
}

// slate-100 do Tailwind v4: oklch(0.968 0.007 247.896) == #f1f5f9 no Chrome.
@(private = "file")
SLATE100 :: "oklch(0.968 0.007 247.896)"
@(private = "file")
SLATE100_RGB :: u32(0xf1f5f9)

// O caso do site: longhand border-color com oklch().
@(test)
m172_border_color_oklch :: proc(t: ^testing.T) {
    c := test_apply("color: #0f172a; border-width: 1px; border-color: " + SLATE100)
    for s in 0 ..< 4 {
        testing.expectf(t, rgb_dist(c.border_c[s] & 0xffffff, SLATE100_RGB) <= 6,
            "lado %d: oklch slate-100 ~= #f1f5f9, tem #%06x", s, c.border_c[s] & 0xffffff)
    }
    // a marca do bug: cair no currentColor (texto quase preto) em vez da cor pedida
    testing.expect(t, c.border_c[0] != c.color, "borda NAO pode herdar currentColor aqui")
}

// Mesmo buraco pelo shorthand `border: <w> <style> <cor funcional>`.
@(test)
m172_border_shorthand_oklch :: proc(t: ^testing.T) {
    c := test_apply("color: #0f172a; border: 1px solid " + SLATE100)
    testing.expectf(t, c.border_w[0] == 1, "largura 1px preservada, tem %.1f", c.border_w[0])
    testing.expectf(t, rgb_dist(c.border_c[0] & 0xffffff, SLATE100_RGB) <= 6,
        "cor do shorthand ~= #f1f5f9, tem #%06x", c.border_c[0] & 0xffffff)
    // e por lado
    c2 := test_apply("border-top: 2px solid " + SLATE100)
    testing.expectf(t, c2.border_w[0] == 2, "border-top largura, tem %.1f", c2.border_w[0])
    testing.expectf(t, rgb_dist(c2.border_c[0] & 0xffffff, SLATE100_RGB) <= 6,
        "border-top cor, tem #%06x", c2.border_c[0] & 0xffffff)
}

// A sintaxe moderna de rgb()/hsl() separa canais por ESPAÇO — mesmo defeito, e aqui
// o valor esperado é EXATO (sem conversão de espaço de cor no meio).
@(test)
m172_border_color_rgb_hsl_com_espacos :: proc(t: ^testing.T) {
    c := test_apply("border-color: rgb(241 245 249)")
    testing.expectf(t, (c.border_c[0] & 0xffffff) == 0xf1f5f9,
        "rgb com espacos = #f1f5f9 exato, tem #%06x", c.border_c[0] & 0xffffff)

    c2 := test_apply("border-color: rgb(241 245 249 / 50%)")
    testing.expectf(t, (c2.border_c[0] & 0xffffff) == 0xf1f5f9,
        "rgb com alpha por barra, tem #%06x", c2.border_c[0] & 0xffffff)

    c3 := test_apply("border-color: hsl(210 40% 96%)")
    testing.expectf(t, rgb_dist(c3.border_c[0] & 0xffffff, 0xf1f4f9) <= 6,
        "hsl com espacos ~= #f1f4f9, tem #%06x", c3.border_c[0] & 0xffffff)
}

// A regra 1-4 valores TEM de continuar contando por VALOR, não por token: uma cor
// funcional é UM valor. `red oklch(...)` = 2 valores (t/b vermelho, r/l claro) —
// com o split ingênuo virariam 4 tokens e a atribuição por lado saía embaralhada.
@(test)
m172_border_color_multivalor_com_funcao :: proc(t: ^testing.T) {
    c := test_apply("border-color: red " + SLATE100)
    testing.expectf(t, (c.border_c[0] & 0xffffff) == 0xff0000, "topo vermelho, tem #%06x", c.border_c[0] & 0xffffff)
    testing.expectf(t, (c.border_c[2] & 0xffffff) == 0xff0000, "baixo vermelho, tem #%06x", c.border_c[2] & 0xffffff)
    testing.expectf(t, rgb_dist(c.border_c[1] & 0xffffff, SLATE100_RGB) <= 6, "direita clara, tem #%06x", c.border_c[1] & 0xffffff)
    testing.expectf(t, rgb_dist(c.border_c[3] & 0xffffff, SLATE100_RGB) <= 6, "esquerda clara, tem #%06x", c.border_c[3] & 0xffffff)
}

// outline passa por parse_border (outro tokenizador, mesmo defeito).
@(test)
m172_outline_oklch :: proc(t: ^testing.T) {
    c := test_apply("color: #0f172a; outline: 2px solid " + SLATE100)
    testing.expectf(t, c.outline_w == 2, "outline 2px, tem %.1f", c.outline_w)
    testing.expectf(t, rgb_dist(c.outline_c & 0xffffff, SLATE100_RGB) <= 6,
        "outline com oklch, tem #%06x", c.outline_c & 0xffffff)
}

// GUARDA de não-regressão do tokenizador: as formas que JÁ funcionavam (hex,
// palavra-chave, rgb com vírgulas) e a contagem 1-4 de border-width por lado.
@(test)
m172_formas_antigas_intactas :: proc(t: ^testing.T) {
    c := test_apply("border-color: #f1f5f9")
    testing.expectf(t, (c.border_c[0] & 0xffffff) == 0xf1f5f9, "hex intacto, tem #%06x", c.border_c[0] & 0xffffff)

    c2 := test_apply("border-color: red green blue")
    testing.expectf(t, (c2.border_c[0] & 0xffffff) == 0xff0000, "3 valores: topo red, tem #%06x", c2.border_c[0] & 0xffffff)
    testing.expectf(t, (c2.border_c[1] & 0xffffff) == 0x008000, "3 valores: laterais green, tem #%06x", c2.border_c[1] & 0xffffff)
    testing.expectf(t, (c2.border_c[2] & 0xffffff) == 0x0000ff, "3 valores: baixo blue, tem #%06x", c2.border_c[2] & 0xffffff)

    c3 := test_apply("border-color: rgb(241,245,249)")
    testing.expectf(t, (c3.border_c[0] & 0xffffff) == 0xf1f5f9, "rgb com virgulas intacto, tem #%06x", c3.border_c[0] & 0xffffff)

    c4 := test_apply("border-width: 1px 2px 3px 4px")
    testing.expect(t, c4.border_w[0] == 1 && c4.border_w[1] == 2 && c4.border_w[2] == 3 && c4.border_w[3] == 4,
        "border-width 4 valores por lado intacto")

    // `transparent` na borda continua invisível (byte de alpha = 1), não preto.
    c5 := test_apply("border: 1px solid transparent")
    testing.expectf(t, (c5.border_c[0] >> 24) == 1, "transparent segue quase-invisivel, tem alpha %d", c5.border_c[0] >> 24)
}

// —— 2ª parte do M172: `font-weight: inherit` ——
//
// O A/B contra o Chrome do MESMO card destapou isto: o nome da empresa (`<h3>`)
// saía em NEGRITO. `apply_ua_defaults` põe .Bold em h1..h6 ANTES das declarações
// do autor, e o preflight de todo framework moderno desfaz isso com
// `h1,…,h6 { font-weight: inherit }` — palavra-chave que o motor ignorava, então
// o reset não tinha efeito. Precisa do pipeline COM ÁRVORE: `test_apply` aplica
// decls a um Computed solto, sem pai de quem herdar e sem defaults de UA.
@(test)
m172_font_weight_inherit :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="pai"><h3 class="alvo">nome</h3><h3 class="ctrl">nome</h3></div>`)
    rules, _ := csspkg.parse(`.alvo { font-weight: inherit }`)
    styles, _ := compute_styles(dom, &rules, 800, 600)

    alvo := m172_find_class(dom, "alvo")
    ctrl := m172_find_class(dom, "ctrl")
    testing.expect(t, alvo != nil && ctrl != nil, "fixture montada")
    if alvo == nil || ctrl == nil do return

    testing.expectf(t, fw_class(styles[alvo].weight) == .Regular,
        "h3 com font-weight:inherit herda do pai (Regular), tem %v", styles[alvo].weight)
    // guarda: sem o reset, o h3 TEM de continuar negrito (senão o teste não prova nada)
    testing.expectf(t, fw_class(styles[ctrl].weight) == .Bold,
        "h3 SEM reset segue negrito do UA, tem %v", styles[ctrl].weight)
}

// `inherit` herda o peso REAL do pai, não um "normal" fixo.
@(test)
m172_font_weight_inherit_de_pai_negrito :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="pai"><h3 class="alvo">nome</h3></div>`)
    rules, _ := csspkg.parse(`.pai { font-weight: 700 } .alvo { font-weight: inherit }`)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo := m172_find_class(dom, "alvo")
    testing.expect(t, alvo != nil, "fixture montada")
    if alvo == nil do return
    testing.expectf(t, fw_class(styles[alvo].weight) == .Bold,
        "pai 700 -> inherit = Bold, tem %v", styles[alvo].weight)
}

// O shorthand `text-decoration` tinha o MESMO tokenizador ingênuo da borda.
@(test)
m172_text_decoration_cor_funcional :: proc(t: ^testing.T) {
    c := test_apply("text-decoration: underline " + SLATE100)
    testing.expect(t, c.underline, "underline preservado")
    testing.expectf(t, rgb_dist(c.deco_color & 0xffffff, SLATE100_RGB) <= 6,
        "cor do shorthand com oklch, tem #%06x", c.deco_color & 0xffffff)

    // não-regressão: cor por palavra-chave e estilo no mesmo shorthand
    c2 := test_apply("text-decoration: dotted red underline")
    testing.expect(t, c2.underline && c2.deco_style == .Dotted, "estilo dotted + underline")
    testing.expectf(t, (c2.deco_color & 0xffffff) == 0xff0000, "cor red, tem #%06x", c2.deco_color & 0xffffff)
}

// —— 3ª parte do M172: font-weight/font-style vindos de custom property ——
//
// O Tailwind v4 não escreve o número: `.font-bold { font-weight: var(--font-weight-bold) }`
// com `--font-weight-bold: 700` no :root. font-weight era lido SEM resolve_var, o
// valor cru não casava nenhum case e o peso herdado permanecia — todo `font-bold`
// do site virava texto normal (ticker e preço do card).
@(test)
m172_font_weight_via_var :: proc(t: ^testing.T) {
    c := test_apply("font-weight: var(--font-weight-bold)", "--font-weight-bold: 700")
    testing.expectf(t, fw_class(c.weight) == .Bold, "var(--font-weight-bold)=700 -> Bold, tem %v", c.weight)

    c2 := test_apply("font-weight: var(--w)", "--w: 600")
    testing.expectf(t, fw_class(c2.weight) == .Semi, "var 600 -> Semi, tem %v", c2.weight)

    // fallback do var() quando a custom property não existe
    c3 := test_apply("font-weight: var(--nao-existe, 700)")
    testing.expectf(t, fw_class(c3.weight) == .Bold, "fallback do var -> Bold, tem %v", c3.weight)

    // número literal segue funcionando (não-regressão)
    c4 := test_apply("font-weight: 700")
    testing.expectf(t, fw_class(c4.weight) == .Bold, "700 literal -> Bold, tem %v", c4.weight)

    c5 := test_apply("font-style: var(--s)", "--s: italic")
    testing.expect(t, c5.italic, "font-style por var -> italico")
}

@(private = "file")
m172_find_class :: proc(n: ^dompkg.Node, cls: string) -> ^dompkg.Node {
    if n == nil do return nil
    if n.attrs != nil {
        if v, ok := n.attrs["class"]; ok && v == cls do return n
    }
    for c in n.children {
        if r := m172_find_class(c, cls); r != nil do return r
    }
    return nil
}
