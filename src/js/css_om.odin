package js

// CSS.escape() and CSS.supports(). The UI installs shared declaration and
// condition hooks; standalone interpreter tests use a syntactic fallback.

import "core:fmt"
import "core:strings"
import csspkg "../css"

// Hook do CSS.supports: `css_prop_is_known` vive no pacote ui (conhece a tabela
// de props do motor de estilo); o js não pode importá-lo (ciclo). O ui instala
// via @(init), igual ao g_dom_query. Contrato: recebe a propriedade JÁ em minúsculas
// e o valor cru; devolve se o motor RECONHECE a propriedade. nil => heurística.
Css_Supports_Fn :: proc(prop: string, value: string) -> bool
g_css_supports: Css_Supports_Fn

// Syntax validation for CSSStyleDeclaration setters; independent of whether a
// feature is rendered. Nil keeps the standalone interpreter usable.
g_css_value_valid: Css_Supports_Fn
g_css_condition_supports: proc(condition: string) -> bool

// ToString (spec, via ToPrimitive) para os argumentos — resultado no
// temp_allocator (vale só até o fim da chamada nativa, que é tudo que precisamos).
@(private = "file")
css_str :: proc(vm: ^Interp, v: Value) -> string {
    sb: strings.Builder
    strings.builder_init(&sb, context.temp_allocator)
    write_text_spec(&sb, vm, v)
    return strings.to_string(sb)
}

install_css :: proc(vm: ^Interp) {
    css := new_object(vm)
    css.props["escape"]   = mk_native(vm, css_escape_native)
    css.props["supports"] = mk_native(vm, css_supports_native)
    env_define(vm.global, "CSS", css)
}

// ── CSS.escape ───────────────────────────────────────────────────────────────
// CSSOM §"serialize an identifier": produz um identificador CSS válido a partir
// de qualquer string. Opera sobre code points; regras exatas da spec.
@(private = "file")
css_escape_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := css_str(vm, arg(args, 0))
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    for cp, i in s { // cp = rune, i = índice de BYTE (= índice de char p/ os casos que testamos, ver abaixo)
        switch {
        case cp == 0:
            // NULL → U+FFFD REPLACEMENT CHARACTER
            strings.write_rune(&b, '�')
        case (cp >= 0x1 && cp <= 0x1f) || cp == 0x7f:
            // controle → \<hex><espaço>
            fmt.sbprintf(&b, "\\%x ", cp)
        case i == 0 && cp >= '0' && cp <= '9':
            // 1º char dígito → \<hex><espaço>
            fmt.sbprintf(&b, "\\%x ", cp)
        case i == 1 && cp >= '0' && cp <= '9' && len(s) >= 1 && s[0] == '-':
            // 2º char dígito quando o 1º é '-'. i(byte)==1 coincide com "2º char"
            // exatamente porque a única forma de o 1º char ser '-' é 1 byte ASCII.
            fmt.sbprintf(&b, "\\%x ", cp)
        case i == 0 && cp == '-' && len(s) == 1:
            // '-' sozinho → "\-"
            strings.write_string(&b, "\\-")
        case cp >= 0x80 || cp == '-' || cp == '_' ||
             (cp >= '0' && cp <= '9') || (cp >= 'A' && cp <= 'Z') || (cp >= 'a' && cp <= 'z'):
            // preservados literalmente
            strings.write_rune(&b, cp)
        case:
            // qualquer outro → '\' + o char
            strings.write_rune(&b, '\\')
            strings.write_rune(&b, cp)
        }
    }
    return own_str(vm, strings.to_string(b))
}

// ── CSS.supports ─────────────────────────────────────────────────────────────
// Duas formas: supports(property, value) e supports(conditionText). A de UM
// argumento tem DOIS passos no CSSOM (ver css_supports_cond) — só a at-rule
// `@supports` exige parênteses; aqui `CSS.supports('color: red')` é válido.
@(private = "file")
css_supports_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) >= 2 && args[1] != nil {
        p := css_str(vm, arg(args, 0))
        v := css_str(vm, arg(args, 1))
        return css_supports_pair(p, v)
    }
    return css_supports_cond(css_str(vm, arg(args, 0)))
}

// Um par (propriedade, valor). Fonte de verdade = hook do ui (props do motor);
// sem ele, heurística sintática. `!important` no valor é inválido em @supports.
@(private = "file")
css_supports_pair :: proc(prop, value: string) -> bool {
    p := strings.trim_space(prop)
    v := strings.trim_space(value)
    if p == "" || v == "" do return false
    lp := strings.to_lower(p, context.temp_allocator)
    if g_css_supports != nil do return g_css_supports(lp, v)
    lv := strings.to_lower(v, context.temp_allocator)
    if strings.contains(lv, "!important") do return false
    return css_ident_plausible(lp) // fallback headless (sem pacote ui)
}

// Heurística usada só quando o hook é nil: é um identificador CSS plausível?
// -?<letra>(<letra>|<dígito>|-)* — sem espaços, sem ':'. NÃO afirma suporte a
// nada específico; só rejeita lixo óbvio para a forma sem página real dos testes.
@(private = "file")
css_ident_plausible :: proc(p: string) -> bool {
    if p == "" do return false
    i := 0
    if p[0] == '-' {
        if len(p) == 1 do return false
        i = 1
    }
    if !((p[i] >= 'a' && p[i] <= 'z')) do return false
    for ; i < len(p); i += 1 {
        c := p[i]
        if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') do return false
    }
    return true
}

// ── parser da <supports-condition> ───────────────────────────────────────────
// ⚠️ IRMÃ DESTE BLOCO: `css/supports.odin` avalia a MESMA gramática para a
// at-rule `@supports`. Não são uma só de propósito: o default de "não sei
// avaliar esta sintaxe" é OPOSTO — lá permissivo (não fazer CSS sumir por
// ignorância nossa), aqui ESTRITO (um feature-detect que responde true manda o
// site pelo caminho moderno que não sabemos renderizar). A POLÍTICA de "o motor
// suporta esta declaração?" é compartilhada: os dois chamam `css_supports_decl`
// do ui, via hook. Ao mexer numa gramática, olhe a outra.
// Gramática do @supports (aproximada, honrando precedência via recursão):
//   condition := or
//   or        := and ( 'or'  and  )*
//   and       := not ( 'and' not  )*
//   not       := 'not' primary | primary
//   primary   := '(' ( declaration | condition ) ')' | general-enclosed
// `general-enclosed` (selector(...), function(...), (lixo)) → false: não
// afirmamos detecção de seletor/função que não implementamos.
//
// ⚠️ O ALGORITMO DO CSSOM TEM DOIS PASSOS, e o 2º é exclusivo desta ponta (a
// at-rule não o tem — ver css/supports.odin):
//   1. avaliar o texto como <supports-condition>;
//   2. se aquilo não parseia, tentar o texto inteiro como <declaration> NUA.
// É o passo 2 que faz `CSS.supports('color: red')` — a forma de 1 argumento sem
// parênteses — devolver true nos navegadores. Faltava aqui: o `css_supports_primary`
// devolve false para tudo que não começa com '(', então a declaração pelada morria
// e o feature-detect via texto ficava respondendo "não suporto" para TUDO.
@(private = "file")
css_supports_cond :: proc(s0: string) -> bool {
    s := strings.trim_space(csspkg.declaration_text(s0))
    if s == "" do return false
    if g_css_condition_supports != nil {
        if g_css_condition_supports(s) do return true
        return css_supports_bare_decl(s)
    }
    if css_supports_or(s) do return true // passo 1
    return css_supports_bare_decl(s)     // passo 2
}

// Passo 1: a <supports-condition> propriamente dita. É esta (não a `_cond`) que a
// gramática recursa — o fallback de declaração vale SÓ no topo do texto; dentro de
// parênteses quem trata declaração é o `css_supports_paren_inner`.
@(private = "file")
css_supports_or :: proc(s0: string) -> bool {
    s := strings.trim_space(s0)
    if s == "" do return false
    if i := find_top_kw(s, "or"); i >= 0 {
        return css_supports_and(s[:i]) || css_supports_or(s[i + 2:])
    }
    return css_supports_and(s)
}

// Passo 2: o texto inteiro como <declaration>. O passo 1 devolve um bool só, então
// "avaliei e deu false" e "isto não parseia como condição" chegam aqui IGUAIS — e
// reciclar como declaração uma condição que avaliou false seria over-claim (o
// `(display:grid) and (foo:bar)` viraria a "propriedade" `(display:grid) and (foo`).
// Por isso exigimos a FORMA de uma declaração antes de perguntar ao motor:
//   • parênteses balanceados e nunca fechando antes de abrir — sobra de condição
//     (`color:red) or (foo:bar`) não é declaração;
//   • nenhum ';' de topo — `;` não faz parte de <declaration>;
//   • ':' de topo, e a propriedade um identificador CSS plausível — mata
//     `not color: red` e `(color`. Custom property (`--x: 1`) entra por fora do
//     ident plausível: o motor a parseia, e o hook responde true por isso.
// Fora dessa forma continua false, que é o default ESTRITO desta ponta.
@(private = "file")
css_supports_bare_decl :: proc(s: string) -> bool {
    if !parens_balanced(s) do return false
    if index_top(s, ';') >= 0 do return false
    ci := index_top(s, ':')
    if ci < 0 do return false
    lp := strings.to_lower(strings.trim_space(s[:ci]), context.temp_allocator)
    if !strings.has_prefix(lp, "--") && !css_ident_plausible(lp) do return false
    return css_supports_pair(s[:ci], s[ci + 1:])
}

@(private = "file")
css_supports_and :: proc(s0: string) -> bool {
    s := strings.trim_space(s0)
    if i := find_top_kw(s, "and"); i >= 0 {
        return css_supports_not(s[:i]) && css_supports_and(s[i + 3:])
    }
    return css_supports_not(s)
}

@(private = "file")
css_supports_not :: proc(s0: string) -> bool {
    s := strings.trim_space(s0)
    if len(s) >= 3 && strings.equal_fold(s[:3], "not") && (len(s) == 3 || is_ws(s[3]) || s[3] == '(') {
        rest := strings.trim_space(s[3:])
        // ⚠️ O `primary` devolve false por DOIS motivos opostos — "avaliei e não
        // suporto" e "isto nem é condição" — e o `not` inverte os dois igual. Sem
        // esta guarda, `not color: red` (sintaxe INVÁLIDA: falta o parêntese)
        // virava TRUE pela porta dos fundos, com o motor AFIRMANDO o que não sabe.
        // Texto que não tem forma de <supports-in-parens> não é negável: a condição
        // é inválida, e quem decide o que fazer com ela é o passo 2 do `_cond`.
        if !is_supports_in_parens(rest) do return false
        return !css_supports_not(rest)
    }
    return css_supports_primary(s)
}

// Tem a FORMA de um <supports-in-parens>? `(…)`, `funcao(…)` ou outro `not …`.
// Só a forma — se o conteúdo é suportado é outra pergunta, feita pelo primary.
@(private = "file")
is_supports_in_parens :: proc(s: string) -> bool {
    if s == "" do return false
    if s[0] == '(' do return match_paren(s, 0) >= 0
    if len(s) >= 3 && strings.equal_fold(s[:3], "not") && (len(s) == 3 || is_ws(s[3]) || s[3] == '(') {
        return true // negação dupla: o primary de verdade está um nível abaixo
    }
    open := strings.index_byte(s, '(') // general-enclosed: `selector(.foo)`, `font-tech(x)`
    if open <= 0 || match_paren(s, open) < 0 do return false
    return css_ident_plausible(strings.to_lower(s[:open], context.temp_allocator))
}

@(private = "file")
css_supports_primary :: proc(s0: string) -> bool {
    s := strings.trim_space(s0)
    if s == "" do return false
    if s[0] != '(' do return false // general-enclosed (selector(...), etc.) → não afirmamos
    close := match_paren(s, 0)
    if close < 0 do return false
    return css_supports_paren_inner(s[1:close])
}

@(private = "file")
css_supports_paren_inner :: proc(inner0: string) -> bool {
    inner := strings.trim_space(inner0)
    if inner == "" do return false
    // condição aninhada? começa com '(' / 'not' / tem and|or no topo
    if inner[0] == '(' ||
       (len(inner) >= 3 && strings.equal_fold(inner[:3], "not") && (len(inner) == 3 || is_ws(inner[3]) || inner[3] == '(')) ||
       find_top_kw(inner, "and") >= 0 || find_top_kw(inner, "or") >= 0 {
        return css_supports_or(inner) // condição, não `_cond`: sem fallback de declaração aqui dentro
    }
    // declaração: propriedade ':' valor (1º ':' no topo)
    ci := index_top(inner, ':')
    if ci < 0 do return false
    return css_supports_pair(inner[:ci], inner[ci + 1:])
}

// ── utilidades de varredura (respeitando profundidade de parênteses) ──────────
@(private = "file")
is_ws :: proc(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// Índice do ')' que casa com o '(' em `open`. -1 se não fechar.
@(private = "file")
match_paren :: proc(s: string, open: int) -> int {
    return csspkg.token_group_end(s, open)
}

// Os parênteses fecham todos, e nenhum ')' aparece antes do seu '('? É o que
// separa uma <declaration> de um pedaço solto de condição (`a:b) or (c:d`).
@(private = "file")
parens_balanced :: proc(s: string) -> bool {
    return csspkg.tokens_balanced(s)
}

// Índice do 1º byte `b` na profundidade 0. -1 se não houver.
@(private = "file")
index_top :: proc(s: string, b: u8) -> int {
    return csspkg.token_index_top(s, b)
}

// Índice da keyword `kw` (palavra inteira, case-insensitive) na profundidade 0.
// Delimitada por whitespace / '(' / ')' / limites. -1 se não houver.
@(private = "file")
find_top_kw :: proc(s, kw: string) -> int {
    return csspkg.token_find_top_keyword(s, kw)
}
