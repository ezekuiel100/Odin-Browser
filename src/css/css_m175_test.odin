package css

// M175 — o parser de seletor PARAVA no primeiro pseudo desconhecido e jogava fora
// o resto do composto (`pseudo = name; break`, o comentário dizia "ignora o resto
// do seletor"). Quando o que vinha depois era uma RESTRIÇÃO, a regra ficava mais
// PERMISSIVA do que o autor escreveu:
//
//     :root.disclosure-open body:before { opacity: 1 }
//
// virava `:root body:before`, ou seja "a raiz SEMPRE". No astro.build essa regra
// acende o backdrop de modal (`position:fixed; inset:0; background:#0d0f14`, que
// fica em `opacity:0` até o menu abrir) — e a página inteira saía coberta por uma
// cor só. Era a causa do site renderizar "em branco".
//
// Dois consertos: (1) guardar o primeiro nome de pseudo e CONTINUAR lendo o
// composto; (2) `:root` passa a virar a tag `html` SEMPRE, não só quando o
// composto está vazio — senão `:root.dark` perdia a raiz e degenerava em `.dark`.

import "core:testing"
import "core:strings"

@(private = "file")
prim :: proc(sel: string) -> (Compound, bool) {
    texto := strings.concatenate({sel, " ", "{", " color: red ", "}"}, context.temp_allocator)
    rules, _ := parse(texto)
    if len(rules) == 0 do return Compound{}, false
    if len(rules[0].selectors) == 0 do return Compound{}, false
    s := rules[0].selectors[0]
    if len(s.parts) == 0 do return Compound{}, false
    return s.parts[0], true
}

@(private = "file")
tem_classe :: proc(c: Compound, nome: string) -> bool {
    for cl in c.classes do if cl == nome do return true
    return false
}

// O caso do astro.build: a classe grudada no `:root` TEM de sobreviver.
@(test)
m175_root_com_classe_preserva_a_classe :: proc(t: ^testing.T) {
    c, ok := prim(":root.disclosure-open")
    testing.expect(t, ok, "parseou")
    if !ok do return
    testing.expectf(t, c.tag == "html", "`:root` vira a tag html, tem %q", c.tag)
    testing.expect(t, tem_classe(c, "disclosure-open"), "a classe do composto NAO pode ser descartada")
}

// `:root.x` tem de sair IGUAL a `html.x` — é a mesma coisa escrita de dois jeitos.
@(test)
m175_root_classe_equivale_a_html_classe :: proc(t: ^testing.T) {
    a, ok1 := prim(":root.dark")
    b, ok2 := prim("html.dark")
    testing.expect(t, ok1 && ok2, "parsearam")
    if !(ok1 && ok2) do return
    testing.expectf(t, a.tag == b.tag, "mesma tag: %q vs %q", a.tag, b.tag)
    testing.expect(t, tem_classe(a, "dark") && tem_classe(b, "dark"), "ambos guardam a classe")
}

// Não é só classe: atributo depois do pseudo também era descartado (`:root[data-tema]`
// é o outro jeito padrão de tematizar).
@(test)
m175_root_com_atributo :: proc(t: ^testing.T) {
    c, ok := prim(":root[data-tema=\"escuro\"]")
    testing.expect(t, ok, "parseou")
    if !ok do return
    testing.expectf(t, c.tag == "html", "tag html, tem %q", c.tag)
    testing.expectf(t, len(c.attrs) == 1, "o atributo sobrevive, tem %d", len(c.attrs))
}

// `:root` sozinho segue casando a raiz (não-regressão do caminho antigo).
@(test)
m175_root_sozinho_intacto :: proc(t: ^testing.T) {
    c, ok := prim(":root")
    testing.expect(t, ok, "parseou")
    if !ok do return
    testing.expectf(t, c.tag == "html", "tag html, tem %q", c.tag)
    testing.expect(t, len(c.classes) == 0, "sem classe")
    testing.expect(t, !c.pseudo_only, "nao pode virar pseudo_only (casaria NADA)")
}

// A regra geral, além do `:root`: qualquer restrição escrita DEPOIS de um pseudo
// desconhecido tem de continuar valendo.
@(test)
m175_restricao_depois_de_pseudo_generico :: proc(t: ^testing.T) {
    c, ok := prim(":defined.minha-classe")
    testing.expect(t, ok, "parseou")
    if !ok do return
    testing.expect(t, tem_classe(c, "minha-classe"), "classe apos pseudo generico sobrevive")
}
