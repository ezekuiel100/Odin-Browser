package ui

// GATE DE EQUIVALÊNCIA DE GRAFIA (criado no M172).
//
// Por que este arquivo existe: o bug do M172 (borda preta em todo site Tailwind)
// passou por 481 reftests WPT, 462 unitários, 12 goldens, Test262 e html5lib com
// TUDO verde. Não foi azar — é um ponto cego ESTRUTURAL: os nossos gates testam
// FUNCIONALIDADE, e o que quebrou foi GRAFIA. `border-color` funcionava. `oklch()`
// funcionava (tem 5 testes só dele). O que não existia era um teste que escrevesse
// os dois JUNTOS — porque todo corpus que temos é de sintaxe antiga: o WPT escreve
// `red` e `#ccc`, e nós copiamos esse hábito nos nossos próprios testes. A web
// moderna escreve a MESMA feature com outra ortografia, e era exatamente aí que o
// valor era picado antes de chegar no código que funcionava.
//
// A ideia deste gate: escrever o MESMO valor nas duas grafias e exigir que o
// Computed saia IGUAL. É auto-verificável — não precisa de Chrome, não precisa de
// golden p/ manter, e qualquer divergência É um bug de parse por definição.
//
// ⚠️ Ao adicionar uma propriedade que aceita <color> ou <length>, ACRESCENTE UMA
// LINHA AQUI. É mais barato que descobrir pelo screenshot de um usuário.

import "core:testing"
import "core:fmt"

// Uma linha do gate: duas grafias do MESMO valor + o campo do Computed a comparar.
@(private = "file")
Grafia :: struct {
    nome:  string,
    velha: string, // sintaxe antiga (a que os nossos testes e o WPT usam)
    nova:  string, // MESMO valor em sintaxe moderna
    vars:  string, // custom properties, quando a grafia moderna usa var()
    ler:   proc(c: ^Computed) -> [4]f64,
    tol:   f64, // 0 = exato; cor via oklch converte por espaço de cor, daí a folga
}

@(private = "file")
canais :: proc(c: u32) -> [4]f64 {
    return {f64((c >> 16) & 0xff), f64((c >> 8) & 0xff), f64(c & 0xff), 0}
}

@(private = "file")
um :: proc(v: f64) -> [4]f64 { return {v, 0, 0, 0} }

@(test)
grafia_moderna_equivale_a_antiga :: proc(t: ^testing.T) {
    linhas := []Grafia{
        // ——— COR ———
        // a linha que teria pego o M172 no dia em que ele entrou
        {"border-color: hex vs oklch", "border-color: #f1f5f9", "border-color: oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.border_c[0]) }, 6},
        {"border shorthand: hex vs oklch", "border: 1px solid #f1f5f9", "border: 1px solid oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.border_c[0]) }, 6},
        {"outline: hex vs oklch", "outline: 2px solid #f1f5f9", "outline: 2px solid oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.outline_c) }, 6},
        {"text-decoration: hex vs oklch", "text-decoration: underline #f1f5f9", "text-decoration: underline oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.deco_color) }, 6},
        {"color: hex vs oklch", "color: #f1f5f9", "color: oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.color) }, 6},
        {"background-color: hex vs oklch", "background-color: #f1f5f9", "background-color: oklch(0.968 0.007 247.896)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.bg) }, 6},
        // rgb() moderno (canais por ESPAÇO) vs legado (vírgulas): tem de dar EXATO
        {"color: rgb virgulas vs espacos", "color: rgb(241,245,249)", "color: rgb(241 245 249)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.color) }, 0},
        {"border-color: rgb virgulas vs espacos", "border-color: rgb(255,0,0)", "border-color: rgb(255 0 0)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.border_c[0]) }, 0},
        {"color: hsl virgulas vs espacos", "color: hsl(210,40%,96%)", "color: hsl(210 40% 96%)", "",
         proc(c: ^Computed) -> [4]f64 { return canais(c.color) }, 1},
        // indireção por custom property (o Tailwind v4 põe TUDO atrás de var())
        {"color: literal vs var()", "color: #f1f5f9", "color: var(--c)", "--c: #f1f5f9",
         proc(c: ^Computed) -> [4]f64 { return canais(c.color) }, 0},
        {"border-color: literal vs var()", "border-color: #f1f5f9", "border-color: var(--c)", "--c: #f1f5f9",
         proc(c: ^Computed) -> [4]f64 { return canais(c.border_c[0]) }, 0},

        // ——— COMPRIMENTO ———
        {"width: px vs calc", "width: 100px", "width: calc(60px + 40px)", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"width: px vs var()", "width: 100px", "width: var(--w)", "--w: 100px",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"padding: px vs calc", "padding: 10px", "padding: calc(4px + 6px)", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.padding[0])) }, 0.01},
        {"flex basis: px vs calc", "flex: 1 1 100px", "flex: 1 1 calc(50px + 50px)", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.flex_basis)) }, 0.01},
        // SINAL unário depois de operador com ESPAÇO — a forma que o Tailwind v4
        // emite p/ toda utilidade negativa (`calc(var(--spacing) * -1)`). O scanner
        // lia o '-' como subtração e o calc inteiro falhava em silêncio.
        {"width: px vs calc com sinal unario", "width: 100px", "width: calc(200px * -1 + 300px)", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"translate: negativo literal vs calc do Tailwind", "translate: 0px -4px", "translate: 0px calc(var(--s) * -1)", "--s: 4px",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.transform_ty)) }, 0.01},
        // NOTAÇÃO CIENTÍFICA: o Tailwind v4 escreve `rounded-full` como
        // `border-radius: 3.40282e38px`. O scanner parava no `e` e a decl sumia.
        {"width: decimal vs expoente", "width: 1000px", "width: 1e3px", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"border-radius: decimal vs expoente", "border-radius: 500px", "border-radius: 5e2px", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.border_radius[0])) }, 0.01},
        // SUB-EXPRESSÃO como operando do `*`. A spec pede que um lado seja escalar;
        // a validação era TEXTUAL ("parseia como número?"), então só um literal
        // contava e qualquer parêntese à DIREITA reprovava — a conta falhava e a
        // declaração sumia em silêncio. À esquerda funcionava, o que escondia o
        // defeito. As duas linhas abaixo são a grafia do `space-y-*` do Tailwind v4.
        {"width: px vs calc com sub-expressao a direita", "width: 100px", "width: calc(100px * calc(1 - 0))", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"width: px vs calc com parenteses a direita", "width: 100px", "width: calc(50px * (1 + 1))", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.width)) }, 0.01},
        {"margin-bottom: px vs calc do space-y", "margin-bottom: 12px",
         "margin-bottom: calc(calc(var(--s) * 3) * calc(1 - var(--r)))", "--s: 4px; --r: 0",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.margin[2])) }, 0.01},
        // CONTROLE (não discrimina sozinho: decl descartada também daria 0) — está
        // aqui p/ travar o outro ramo do space-y, o que multiplica pelo reverse.
        {"margin-top: zero vs o ramo reverse do space-y (controle)", "margin-top: 0px",
         "margin-top: calc(calc(var(--s) * 3) * var(--r))", "--s: 4px; --r: 0",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.margin[0])) }, 0.01},
        // PORCENTAGEM que sai de um calc: `-translate-x-1/2` (centralização de
        // modal/overlay no Tailwind v4). Além do escalar acima, todo calc era
        // rotulado px — daí o deslocamento virava -50 PIXELS em vez de -50% da
        // própria caixa. O valor do Computed é fração (-0.5), como `-50%` literal.
        {"translate: -50% vs o calc do -translate-x-1/2", "translate: -50% 0",
         "translate: calc(calc(1 / 2 * 100%) * -1) 0", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.transform_tx)) }, 0.0001},

        // LINE-HEIGHT como COMPRIMENTO. Guardamos multiplicador, então 24px sobre
        // fonte 13px = 1.846 — e é isso que as três grafias têm de dar. A do meio é
        // a que o Tailwind v4 emite (`leading-6`, e o `/6` de `text-[13px]/6`); a
        // função tinha scanner próprio que exigia dígito no 1º byte e devolvia o
        // default 1.3 p/ calc() — o bloco de código saía com as linhas apertadas.
        {"line-height: px vs calc do Tailwind", "font-size:13px; line-height: 24px",
         "font-size:13px; line-height: calc(var(--s) * 6)", "--s: 0.25rem",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},
        {"line-height: px vs rem", "font-size:13px; line-height: 24px", "font-size:13px; line-height: 1.5rem", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},
        // RAZÃO vinda de calc — a outra metade do par acima, e a que eu quebrei ao
        // fazer a primeira: `calc(1.75 / 1.125)` NÃO tem unidade, é razão pura (é
        // como o Tailwind v4 define `--text-lg--line-height`). Tratada como
        // comprimento, era dividida pela fonte e a linha COLAPSAVA (0.097).
        {"line-height: razao literal vs razao de calc", "line-height: 1.5555555",
         "line-height: calc(1.75 / 1.125)", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},
        {"line-height: razao de calc por var()", "line-height: 1.5555555",
         "line-height: var(--lh)", "--lh: calc(1.75 / 1.125)",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},
        // controle: número puro e % NÃO são comprimento e seguem sendo razão direta
        {"line-height: numero vs porcentagem", "line-height: 1.5", "line-height: 150%", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},

        // Unidade `lh` = a line-height COMPUTADA do próprio elemento. O Tailwind v4
        // escreve `min-h-lh` p/ dar a uma caixa a altura de UMA linha. O 2º par usa a
        // line-height vinda de calc(), que é como o Tailwind a emite — encadeia as
        // duas correções (o `lh` só sai certo se o calc do line-height sair certo).
        {"min-height: px vs lh", "font-size:16px; line-height:1.5; min-height:24px",
         "font-size:16px; line-height:1.5; min-height:1lh", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.minh)) }, 0.01},
        {"min-height: px vs lh com line-height de calc", "font-size:13px; line-height:24px; min-height:24px",
         "font-size:13px; line-height:calc(var(--s) * 6); min-height:1lh", "--s: 0.25rem",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.minh)) }, 0.01},

        // SHORTHAND `font` vs longhands. O shorthand entregava só itálico e família:
        // `body{font:16px/1.5 sans-serif}` não mexia em tamanho NEM em entrelinha — e
        // arrastava junto a unidade `lh`, que passava a medir contra a linha errada.
        // O 3º par é o que discrimina tamanho de PESO (os dois podem ser numéricos):
        // o tamanho tem unidade, `700` puro é peso.
        {"font shorthand vs longhand: tamanho", "font-size:24px", "font: 24px/2 sans-serif", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.font_size)) }, 0.01},
        {"font shorthand vs longhand: entrelinha", "font-size:24px; line-height:2", "font: 24px/2 sans-serif", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.line_height)) }, 0.001},
        {"font shorthand com peso numerico antes do tamanho", "font-size:24px", "font: 700 24px/2 sans-serif", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(c.font_size)) }, 0.01},

        // ——— PESO / PALAVRA-CHAVE ———
        {"font-weight: numero vs var()", "font-weight: 700", "font-weight: var(--fw)", "--fw: 700",
         proc(c: ^Computed) -> [4]f64 { return um(f64(int(c.weight))) }, 0},
        {"font-weight: bold vs 700", "font-weight: bold", "font-weight: 700", "",
         proc(c: ^Computed) -> [4]f64 { return um(f64(int(c.weight))) }, 0},

        // ——— POSIÇÃO EM DOIS EIXOS (onde o token errado troca de EIXO) ———
        {"background-position: % vs keyword", "background-position: 100% 50%", "background-position: right center", "",
         proc(c: ^Computed) -> [4]f64 { return {f64(c.bg_pos_x), f64(c.bg_pos_y), 0, 0} }, 0.001},
        {"transform-origin: % vs keyword", "transform-origin: 50% 100%", "transform-origin: center bottom", "",
         proc(c: ^Computed) -> [4]f64 { return {f64(c.transform_ox), f64(c.transform_oy), 0, 0} }, 0.001},

        // ——— MARGIN AUTO com valor FUNCIONAL no outro eixo ———
        // `margin: <len> auto` centraliza; com o split ingênuo o calc virava 3
        // tokens, caía no ramo "t r b l" e o `auto` era lido no índice errado.
        {"margin auto: px vs calc", "margin: 20px auto", "margin: calc(12px + 8px) auto", "",
         proc(c: ^Computed) -> [4]f64 { return um(c.margin_x_auto ? 1 : 0) }, 0},
    }

    for g in linhas {
        a := test_apply(g.velha, g.vars)
        b := test_apply(g.nova,  g.vars)
        va, vb := g.ler(&a), g.ler(&b)
        for i in 0 ..< 4 {
            d := va[i] - vb[i]
            if d < 0 do d = -d
            testing.expectf(t, d <= g.tol,
                "%s: grafia moderna diverge da antiga no componente %d — `%s` da %.3f, `%s` da %.3f (tol %.3f)",
                g.nome, i, g.velha, va[i], g.nova, vb[i], g.tol)
        }
    }
    fmt.printf("[gate de grafia] %d pares verificados\n", len(linhas))
}

// Mesmo gate, mas para as PROPRIEDADES LÓGICAS DE EIXO (padding-inline,
// padding-block, margin-inline, inset-inline/block). Elas não passam por
// test_apply: o aliasing lógico→físico mora em collect_decls, dentro da
// cascata. Por isso este teste usa test_compute_one, que roda a pipeline real.
//
// A grafia que importa é a do Tailwind v4: `px-4` NÃO vira `padding-left`, vira
// `padding-inline: calc(var(--spacing) * 4)` — valor único COM espaços internos.
// O atalho de eixo picava por espaço e cada lado recebia um caco inválido.
//
// Cada par tem um CONTROLE (mesma prop lógica com valor de um token só). Se o
// controle passa e a grafia moderna falha, o defeito é de PARSE, não de feature.
@(test)
grafia_prop_logica_de_eixo :: proc(t: ^testing.T) {
    Par :: struct {
        nome, velha, nova: string,
        ler:               proc(c: ^Computed) -> f64,
    }
    pares := []Par{
        {"padding-inline (controle: 1 token)", "div{padding-left:16px}", "div{padding-inline:16px}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[3]) }},
        {"padding-inline: calc do Tailwind", "div{padding-left:16px}", "div{--s:4px;padding-inline:calc(var(--s) * 4)}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[3]) }},
        {"padding-inline: calc, lado direito", "div{padding-right:16px}", "div{--s:4px;padding-inline:calc(var(--s) * 4)}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[1]) }},
        {"padding-block: calc do Tailwind", "div{padding-top:8px}", "div{--s:4px;padding-block:calc(var(--s) * 2)}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[0]) }},
        {"margin-inline: calc", "div{margin-right:16px}", "div{margin-inline:calc(4px * 4)}",
         proc(c: ^Computed) -> f64 { return f64(c.margin[1]) }},
        {"inset-block: calc", "div{position:absolute;top:12px}", "div{position:absolute;inset-block:calc(4px + 8px)}",
         proc(c: ^Computed) -> f64 { return f64(c.inset[0]) }},
        // dois valores explícitos, cada um funcional: <start> <end>
        {"padding-inline: 2 calc distintos (start)", "div{padding-left:8px}", "div{padding-inline:calc(4px + 4px) calc(8px + 8px)}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[3]) }},
        {"padding-inline: 2 calc distintos (end)", "div{padding-right:16px}", "div{padding-inline:calc(4px + 4px) calc(8px + 8px)}",
         proc(c: ^Computed) -> f64 { return f64(c.padding[1]) }},
    }
    for p in pares {
        a := test_compute_one(p.velha)
        b := test_compute_one(p.nova)
        va, vb := p.ler(&a), p.ler(&b)
        d := va - vb
        if d < 0 do d = -d
        testing.expectf(t, d <= 0.01,
            "%s: `%s` da %.2f, `%s` da %.2f", p.nome, p.velha, va, p.nova, vb)
    }
    fmt.printf("[gate de grafia logica] %d pares verificados\n", len(pares))
}
