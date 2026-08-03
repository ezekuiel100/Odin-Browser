package css

// Avaliação da <supports-condition> do `@supports` (CSS Conditional Rules 3 §2).
//
// ANTES (até 2026-07-29) as duas pontas estavam erradas, e em silêncio:
//   - `parse_block` tratava `@supports` como TRANSPARENTE (junto de `@layer`):
//     o conteúdo entrava SEMPRE, condição ignorada. Ou seja, o fallback de
//     `@supports not (display:grid){…}` era aplicado POR CIMA do caminho
//     moderno — o padrão de progressive enhancement virava sobrescrita.
//   - `parse_rule_body` (o `@supports` ANINHADO por CSS nesting) nem tinha
//     ramo: caía no `skip_at_rule` e o bloco inteiro era DESCARTADO.
//
// Gramática (a mesma do `CSS.supports()` em js/css_om.odin, que delega aqui):
//   condition := or
//   or        := and ( 'or'  and )*
//   and       := not ( 'and' not )*
//   not       := 'not' primary | primary
//   primary   := '(' ( declaration | condition ) ')' | general-enclosed
//
// ── A decisão de projeto que importa: LÓGICA DE TRÊS VALORES ────────────────
// Cada nó devolve `(val, ok)`. `ok=false` significa "não sei avaliar esta
// SINTAXE" — que é diferente de "avaliei e deu falso". No TOPO, não-sei ⇒
// **true**, preservando o comportamento antigo: sintaxe que não modelamos
// nunca faz CSS SUMIR (a spec manda false; aqui false seria pior que inútil,
// porque a nossa ignorância viraria remoção de conteúdo do site).
// `and`/`or` só propagam o não-sei quando o outro lado não decide sozinho:
// `false and ?` = false, `true or ?` = true.
//
// ⚠️ LIMITE CONHECIDO: o hook julga a declaração inteira, mas a checagem de
// VALOR do lado do ui é parcial (ver css_supports_decl em ui/style.odin) —
// prop conhecida + valor que não sabemos julgar ⇒ true. `@supports (foo: bar)`
// com `foo` desconhecida é o caso 100% confiável.
//
// ⚠️ IRMÃ DESTE ARQUIVO: `js/css_om.odin` tem a MESMA gramática para o
// `CSS.supports()` do JS. Não foi unificada de propósito — o default de
// "não sei" é OPOSTO nas duas: aqui permissivo (não sumir com CSS), lá
// ESTRITO (feature-detect que responde true manda o site pelo caminho
// moderno que não sabemos renderizar). O que É compartilhado, e é o que
// importa, é a POLÍTICA: os dois chamam a mesma `css_supports_decl` do ui.
// Ao mexer na gramática de um, olhe o outro.
// ⚠️ E uma diferença que NÃO é acidente: o `CSS.supports(texto)` do JS tem um 2º
// passo do CSSOM — texto que não parseia como condição é tentado como
// <declaration> nua, e por isso `CSS.supports('color: red')` (sem parênteses) é
// true. A at-rule NÃO tem esse passo: `@supports color: red {…}` é inválida, o
// prelúdio dela é uma <supports-condition> e ponto. Não copie o fallback p/ cá.

import "core:strings"

// Hook instalado pelo pacote ui (`@(init)` em style.odin): "o motor implementa
// esta declaração?". O css é folha e o ui importa css, então a fonte de verdade
// (`css_prop_is_known` + checagem de valor) chega por ponteiro de proc.
// Nil ⇒ permissivo (ver supports_declaration).
Prop_Supported_Fn :: #type proc(prop: string, value: string) -> bool

g_prop_supported: Prop_Supported_Fn

// Entrada pública: a condição crua entre `@supports` e `{`.
supports_condition :: proc(cond: string) -> bool {
    return supports_condition_with(cond, g_prop_supported)
}

// Variante com hook EXPLÍCITO. Os testes usam esta forma para não escrever no
// global `g_prop_supported` — global mutável + runner paralelo de testes é a
// receita de flake que já mordeu este projeto (M192/M216/M217).
supports_condition_with :: proc(cond: string, fn: Prop_Supported_Fn) -> bool {
    val, ok := sup_or(cond, fn)
    return ok ? val : true // não-sei no topo ⇒ permissivo
}

// Uma declaração `(prop: value)` da condição.
supports_declaration :: proc(prop, value: string, fn: Prop_Supported_Fn) -> bool {
    p := strings.to_lower(strings.trim_space(prop), context.temp_allocator)
    v := strings.trim_space(value)
    if p == "" || v == "" do return false
    // `!important` dentro de @supports é inválido por spec.
    if strings.contains(strings.to_lower(v, context.temp_allocator), "!important") do return false
    // Custom property: quem PARSEIA a declaração a suporta — e nós parseamos
    // (`var()` + cascata de `--x` existem). `@supports (--x: y)` é o teste
    // clássico de "tem custom properties?" e TEM de dar true, senão derrubamos
    // o sistema de temas inteiro de sites que ainda fazem essa detecção.
    if strings.has_prefix(p, "--") do return true
    if fn == nil do return true // sem hook: permissivo (= comportamento antigo)
    return fn(p, v)
}

// `selector(<complex-selector>)`: respondemos com o PARSER DE SELETOR REAL.
// Um composto que o parser marca `pseudo_only` (`::selection`, `::marker`,
// `::-webkit-*`…) ou `is_unresolved` (`:is()` com argumento não avaliável) é
// exatamente "casa nada neste motor" ⇒ não suportado. `:has(a)`,
// `:focus-visible`, `:nth-child(2n+1)` passam, que é a verdade.
supports_selector :: proc(sel: string) -> bool {
    s := strings.trim_space(sel)
    if s == "" do return false
    sels := parse_selectors(s)
    defer {
        for &x in sels do free_selector(&x)
        delete(sels)
    }
    if len(sels) != 1 do return false // lista de seletores não é <complex-selector>
    for part in sels[0].parts {
        if part.pseudo_only || part.is_unresolved do return false
    }
    return true
}

// ── gramática ───────────────────────────────────────────────────────────────

@(private = "file")
sup_or :: proc(s0: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    s := strings.trim_space(s0)
    if i := sup_find_top_kw(s, "or"); i >= 0 {
        lv, lok := sup_and(s[:i], fn)
        rv, rok := sup_or(s[i + 2:], fn)
        if lok && lv do return true, true
        if rok && rv do return true, true
        if lok && rok do return false, true
        return false, false
    }
    return sup_and(s, fn)
}

@(private = "file")
sup_and :: proc(s0: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    s := strings.trim_space(s0)
    if i := sup_find_top_kw(s, "and"); i >= 0 {
        lv, lok := sup_not(s[:i], fn)
        rv, rok := sup_and(s[i + 3:], fn)
        if lok && !lv do return false, true
        if rok && !rv do return false, true
        if lok && rok do return true, true
        return false, false
    }
    return sup_not(s, fn)
}

@(private = "file")
sup_not :: proc(s0: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    s := strings.trim_space(s0)
    if len(s) >= 3 && strings.equal_fold(s[:3], "not") &&
       (len(s) == 3 || is_space(s[3]) || s[3] == '(') {
        v, k := sup_not(strings.trim_space(s[3:]), fn)
        return !v, k // não-sei negado continua não-sei
    }
    return sup_primary(s, fn)
}

@(private = "file")
sup_primary :: proc(s0: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    s := strings.trim_space(s0)
    if s == "" do return false, false
    if s[0] == '(' {
        close := sup_match_paren(s, 0)
        if close < 0 do return false, false
        // sobra depois do ')' que fecha ⇒ forma que não modelamos
        if strings.trim_space(s[close + 1:]) != "" do return false, false
        return sup_paren_inner(s[1:close], fn)
    }
    return sup_general_enclosed(s, fn)
}

// `general-enclosed`: `funcao(...)`. Só respondemos o que sabemos de verdade.
@(private = "file")
sup_general_enclosed :: proc(s: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    open := strings.index_byte(s, '(')
    if open <= 0 do return false, false
    close := sup_match_paren(s, open)
    if close < 0 || strings.trim_space(s[close + 1:]) != "" do return false, false
    name := strings.to_lower(strings.trim_space(s[:open]), context.temp_allocator)
    switch name {
    case "selector":
        return supports_selector(s[open + 1:close]), true
    case "font-tech", "font-format":
        // Sem `@font-face` não carregamos fonte nenhuma: a resposta é NÃO, e é
        // uma resposta que sabemos dar (ok=true, não "não sei").
        return false, true
    }
    return false, false
}

@(private = "file")
sup_paren_inner :: proc(inner0: string, fn: Prop_Supported_Fn) -> (val: bool, ok: bool) {
    inner := strings.trim_space(inner0)
    if inner == "" do return false, false
    // condição aninhada? começa com '(' / 'not', ou tem and|or no topo
    if inner[0] == '(' ||
       (len(inner) >= 3 && strings.equal_fold(inner[:3], "not") &&
        (len(inner) == 3 || is_space(inner[3]) || inner[3] == '(')) ||
       sup_find_top_kw(inner, "and") >= 0 || sup_find_top_kw(inner, "or") >= 0 {
        return sup_or(inner, fn)
    }
    ci := sup_index_top(inner, ':')
    if ci < 0 do return false, false // `(lixo)` sem ':' = general-enclosed
    return supports_declaration(inner[:ci], inner[ci + 1:], fn), true
}

// ── varredura respeitando profundidade de parênteses ─────────────────────────

// Índice do ')' que casa com o '(' em `open`. -1 se não fechar.
@(private = "file")
sup_match_paren :: proc(s: string, open: int) -> int {
    depth := 0
    for i := open; i < len(s); i += 1 {
        switch s[i] {
        case '(': depth += 1
        case ')':
            depth -= 1
            if depth == 0 do return i
        }
    }
    return -1
}

// Índice do 1º byte `b` na profundidade 0. -1 se não houver.
@(private = "file")
sup_index_top :: proc(s: string, b: u8) -> int {
    depth := 0
    for i := 0; i < len(s); i += 1 {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case:
            if depth == 0 && s[i] == b do return i
        }
    }
    return -1
}

// Índice da keyword `kw` (palavra inteira, case-insensitive) na profundidade 0,
// delimitada por espaço / '(' / ')' / limites. -1 se não houver.
@(private = "file")
sup_find_top_kw :: proc(s, kw: string) -> int {
    depth := 0
    for i := 0; i < len(s); i += 1 {
        switch s[i] {
        case '(': depth += 1; continue
        case ')': depth -= 1; continue
        }
        if depth != 0 do continue
        if i + len(kw) > len(s) do continue
        if !strings.equal_fold(s[i:i + len(kw)], kw) do continue
        before_ok := i == 0 || is_space(s[i - 1]) || s[i - 1] == ')'
        aj := i + len(kw)
        after_ok := aj >= len(s) || is_space(s[aj]) || s[aj] == '('
        if before_ok && after_ok do return i
    }
    return -1
}
