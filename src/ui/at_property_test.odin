package ui

// `@property --nome { syntax; inherits; initial-value }` — registro do VALOR
// INICIAL de uma custom property.
//
// Por que existe: a at-rule caía em `skip_at_rule`, então a variável simplesmente
// NÃO EXISTIA. O **Tailwind v4 declara `--tw-translate-x/y/z`, `--tw-scale-*` e
// `--tw-skew-*` SÓ por `@property`** e depois escreve
// `translate: var(--tw-translate-x) var(--tw-translate-y)`; com metade das
// variáveis sem resolver, a declaração inteira era descartada e NENHUMA utilidade
// de transform do site funcionava (`hover:-translate-y-1`, `group-hover:scale-105`).
// Medido no ultra-photo.com: o card não levantava no hover mesmo depois de o
// `@media (hover:hover)` passar a casar.
//
// Modelo: a at-rule vira a regra sintética `:root{--nome: <initial-value>}` com
// prioridade ABAIXO de qualquer regra real, então ela só decide onde ninguém
// declarou. As degradações estão nomeadas nos testes do fim deste arquivo.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// Computed do primeiro elemento com a tag pedida, pela pipeline REAL
// (parse HTML + parse CSS + compute_styles) — é a única forma de ver a herança
// da raiz, que é por onde o valor registrado chega ao elemento.
@(private = "file")
computed_de :: proc(html_src, css, tag: string) -> Computed {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo: ^dompkg.Node
    walk :: proc(n: ^dompkg.Node, tag: string, out: ^^dompkg.Node) {
        if n.kind == .Element && n.tag == tag && out^ == nil do out^ = n
        for c in n.children do walk(c, tag, out)
    }
    walk(dom, tag, &alvo)
    if alvo == nil do return Computed{}
    return styles[alvo]
}

@(private = "file")
HTML_UM :: `<html><body><p class="a">x</p></body></html>`

// O caso do Tailwind: só UM dos dois eixos é declarado pelo autor; o outro
// existe apenas como initial-value registrado.
@(test)
at_property_alimenta_o_var_que_ninguem_declarou :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: false; initial-value: 0px }
            .a { --ty: -10px; translate: var(--tx) var(--ty); }`
    c := computed_de(HTML_UM, css, "p")
    testing.expect(t, c.has_transform, "a declaracao translate NAO pode ser descartada")
    testing.expectf(t, c.transform_tx == 0,   "tx devia vir do initial-value (0), veio %v", c.transform_tx)
    testing.expectf(t, c.transform_ty == -10, "ty devia ser -10, veio %v", c.transform_ty)
}

// ⚠️ O teste que prova que o de cima pode falhar: SEM a at-rule, o mesmo CSS
// dá outro resultado. (Hoje o var não-resolvido some do valor e o -10px escorrega
// para o eixo X — a spec mandaria invalidar a declaração inteira, degradação
// pré-existente e anotada; o que importa aqui é que o eixo Y NÃO sai certo.)
@(test)
sem_at_property_o_eixo_y_nao_sai :: proc(t: ^testing.T) {
    css :: `.a { --ty: -10px; translate: var(--tx) var(--ty); }`
    c := computed_de(HTML_UM, css, "p")
    testing.expect(t, c.transform_ty != -10, "sem o registro, ty NAO pode sair correto")
}

// Declaração do autor GANHA do valor registrado (a regra sintética entra abaixo
// de tudo na cascata).
@(test)
autor_ganha_do_initial_value :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: false; initial-value: 0px }
            .a { --tx: 5px; translate: var(--tx) 0px; }`
    c := computed_de(HTML_UM, css, "p")
    testing.expectf(t, c.transform_tx == 5, "o 5px do autor tem de vencer o 0px registrado, veio %v", c.transform_tx)
}

// ... inclusive quando o autor declara no :root — mas SÓ se a propriedade herda
// (`inherits: true`), porque é a herança que a leva do :root até o descendente.
@(test)
autor_no_root_ganha_do_initial_value :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: true; initial-value: 0px }
            :root { --tx: 7px }
            .a { translate: var(--tx) 0px; }`
    c := computed_de(HTML_UM, css, "p")
    testing.expectf(t, c.transform_tx == 7, "o :root do autor tem de vencer o registrado, veio %v", c.transform_tx)
}

// `inherits: false` NÃO atravessa a fronteira do elemento: a declaração do autor
// no :root vale p/ o :root, e o descendente que não declara volta ao INICIAL.
// (É o par do teste acima — a MESMA folha, mudando só o descritor `inherits`.)
@(test)
inherits_false_nao_atravessa_o_elemento :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: false; initial-value: 0px }
            :root { --tx: 7px }
            .a { translate: var(--tx) 0px; }`
    c := computed_de(HTML_UM, css, "p")
    testing.expectf(t, c.transform_tx == 0,
        "com inherits:false o descendente usa o INICIAL (0), nao o 7px do :root; veio %v", c.transform_tx)
}

// A forma EXATA que o Tailwind v4 emite: o eixo vem de um calc() com espaços
// dentro dos parenteses (`calc(var(--spacing) * -1)`). Fatiar o valor por ESPAÇO
// quebrava justamente aqui — a classe de defeito do M172/M173.
@(test)
at_property_com_calc_do_tailwind :: proc(t: ^testing.T) {
    css :: `@property --tw-translate-x { syntax: "<length-percentage>"; inherits: false; initial-value: 0 }
            @property --tw-translate-y { syntax: "<length-percentage>"; inherits: false; initial-value: 0 }
            :root { --spacing: 0.25rem }
            .a { --tw-translate-y: calc(var(--spacing) * -1);
                 translate: var(--tw-translate-x) var(--tw-translate-y); }`
    c := computed_de(HTML_UM, css, "p")
    testing.expect(t, c.has_transform, "translate do Tailwind nao pode ser descartado")
    testing.expectf(t, c.transform_ty == -4, "0.25rem * -1 = -4px, veio %v", c.transform_ty)
}

// `scale` com as duas metades registradas (o `group-hover:scale-105`).
@(test)
at_property_alimenta_scale :: proc(t: ^testing.T) {
    css :: `@property --sx { syntax: "<number>"; inherits: false; initial-value: 1 }
            .a { --sy: 105%; scale: var(--sx) var(--sy); }`
    c := computed_de(HTML_UM, css, "p")
    testing.expect(t, c.has_transform, "scale nao pode ser descartado")
    testing.expectf(t, c.transform_sx == 1,    "sx devia vir do initial-value, veio %v", c.transform_sx)
    testing.expectf(t, c.transform_sy == 1.05, "sy devia ser 1.05, veio %v", c.transform_sy)
}

// Sem `initial-value` não há o que registrar — não pode inventar um valor.
@(test)
at_property_sem_initial_value_nao_registra :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "*"; inherits: false }
            .a { --ty: -10px; translate: var(--tx) var(--ty); }`
    c := computed_de(HTML_UM, css, "p")
    testing.expect(t, c.transform_ty != -10, "sem initial-value nada e registrado")
}

// `inherits: false` com um ANCESTRAL declarando: o filho volta ao inicial.
// (Este teste nasceu invertido, documentando a degradação de quando `inherits`
// era ignorado; virou teste de correção quando o descritor passou a valer.)
@(test)
inherits_false_o_filho_volta_ao_inicial :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: false; initial-value: 0px }
            .pai { --tx: 30px }
            .a { translate: var(--tx) 0px; }`
    c := computed_de(`<html><body><div class="pai"><p class="a">x</p></div></body></html>`, css, "p")
    testing.expectf(t, c.transform_tx == 0,
        "o filho NAO herda o 30px do pai: volta ao inicial 0; veio %v", c.transform_tx)
}

// ... e o mesmo ancestral COM `inherits: true` continua alcançando o filho —
// é o par que prova que o descritor é lido, e não que a herança sumiu.
@(test)
inherits_true_o_filho_herda :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: true; initial-value: 0px }
            .pai { --tx: 30px }
            .a { translate: var(--tx) 0px; }`
    c := computed_de(`<html><body><div class="pai"><p class="a">x</p></div></body></html>`, css, "p")
    testing.expectf(t, c.transform_tx == 30, "com inherits:true o filho herda o 30px; veio %v", c.transform_tx)
}

// O elemento que DECLARA a propriedade usa o próprio valor mesmo com inherits:false
// (o reset é só p/ quem não declara) — e o valor não escapa p/ o filho.
@(test)
inherits_false_quem_declara_usa_o_proprio :: proc(t: ^testing.T) {
    css :: `@property --tx { syntax: "<length>"; inherits: false; initial-value: 0px }
            .pai { --tx: 30px; translate: var(--tx) 0px }
            .a { translate: var(--tx) 0px; }`
    html :: `<html><body><div class="pai"><p class="a">x</p></div></body></html>`
    pai := computed_de(html, css, "div")
    filho := computed_de(html, css, "p")
    testing.expectf(t, pai.transform_tx == 30, "quem declara usa o proprio valor; veio %v", pai.transform_tx)
    testing.expectf(t, filho.transform_tx == 0, "e ele NAO escapa p/ o filho; veio %v", filho.transform_tx)
}
