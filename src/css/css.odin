package css

// Parser de CSS simplificado: transforma texto CSS numa lista de regras
// (seletor + declarações). Suporta seletores simples (tag, .classe, #id),
// seletores de atributo ([a], [a=v], ~= |= ^= $= *=), todos os combinadores
// (descendente, >, +, ~), pseudo-classes estruturais (:first/last/only-child,
// :nth-child/:nth-of-type com An+B — avaliadas contra o DOM pelo motor de
// estilo), listas separadas por vírgula, @media (min/max-width), @keyframes
// e !important (via split_important, aplicado na cascata).
//
// Também suporta :not(X) e :is()/:where() com compostos simples (argumentos
// não suportados, como :not(:hover) ou :is(div p), são aproximados de forma
// segura: o :not ignora o argumento no MATCHING; o :is vira sempre-ativo).
// ⚠️ "ignora no matching" nunca quis dizer "ignora na ESPECIFICIDADE" — a spec
// conta o argumento tenha o motor sabido avaliá-lo ou não, e a aproximação só
// vale para QUEM CASA. Ver `nots_spec`. E CSS nesting
// (regras aninhadas com &, combinadores relativos e @media aninhado — os
// seletores são expandidos textualmente em parse_rule_body).
//
// @import é resolvido ANTES do parse (append_css_with_imports na coleta de
// CSS baixa e inlina as folhas); statements remanescentes são pulados aqui.
//
// @font-face é parseado em fontface.odin (o download e o atlas ficam no ui).

import "core:strings"
import "core:strconv"
import "core:math"
import "core:mem"

// Combinador entre dois compostos da cadeia. Adjacent = '+' (irmão anterior
// imediato), Sibling = '~' (qualquer irmão anterior).
Combinator :: enum u8 { Descendant, Child, Adjacent, Sibling }

// Composto simples: tag + classes + id.
// Pseudo-elemento alvo de um composto. Before/After geram caixas (::before/::after);
// Placeholder estiliza o TEXTO-DICA de <input>/<textarea> (M218); Other =
// pseudo-classe/elemento qualquer (:hover, ::selection…).
Pseudo_Kind :: enum u8 { None, Before, After, FirstLetter, Placeholder, Other }

// Estado do elemento exigido pelo composto (:hover/:focus/:active). None = a
// regra vale sempre; os demais só quando o elemento está naquele estado (o
// motor reavalia por frame na pintura). :nth-child/:not/etc. continuam None
// (aproximados como sempre ativos).
Element_State :: enum u8 { None, Hover, Focus, Active }

// Seletor de atributo: [name] (Exists), [name=v], [name~=v] (palavra),
// [name|=v] (v ou v-…), [name^=v], [name$=v], [name*=v].
Attr_Op :: enum u8 { Exists, Equals, Includes, Dash, Prefix, Suffix, Substr }
Attr_Sel :: struct { name: string, op: Attr_Op, val: string }

// Pseudo-classe estrutural exigida pelo composto (posição entre irmãos; a
// avaliação contra o DOM fica no motor de estilo). Child/Of_Type usam nth_a/b
// (índice casa se = a·k + b, k ≥ 0, 1-based); Last_* contam do fim; Only =
// :only-child. first-child ≡ nth-child(0n+1).
Nth_Kind :: enum u8 { None, Child, Last_Child, Of_Type, Last_Of_Type, Only, Only_Of_Type }

// Pseudos de estado de formulário/UI avaliados por ATRIBUTO no DOM (não por
// frame). Checked/Disabled/Required/ReadOnly exigem o atributo; os pares
// Enabled/Optional/ReadWrite exigem a AUSÊNCIA do respectivo.
UI_State :: enum u8 { Checked, Disabled, Enabled, Required, Optional, ReadOnly, ReadWrite }

// :dir(ltr)/:dir(rtl) — casa pela DIRECIONALIDADE do elemento (atributo `dir`,
// herdada, default ltr — NÃO a prop CSS `direction`; avaliada no motor de estilo
// que tem a árvore). Never = argumento inválido (`:dir(foopy)`, `:dir()`,
// `:dir(ltr, rtl)`): parseia mas casa NADA. None = sem :dir() neste composto.
Dir_Req :: enum u8 { None, Ltr, Rtl, Never }

Compound :: struct {
    tag:     string,            // "" ou "*" = qualquer
    classes: [dynamic]string,
    id:      string,
    specificity: [3]int,       // (IDs, classes/attrs/pseudos, types/pseudo-elements)
    attrs:   [dynamic]Attr_Sel, // seletores de atributo ([type="text"]…)
    nth_kind:    Nth_Kind,      // pseudo-classe estrutural (:first-child/:nth-child…)
    nth_a, nth_b: int,          // An+B de :nth-child()/:nth-of-type()
    ui_states: bit_set[UI_State], // :checked/:disabled/… (avaliados por atributo)
    dir_req:     Dir_Req,         // :dir(ltr)/:dir(rtl) (avaliado por direcionalidade no motor)
    nots:    [dynamic]Selector, // :not(X): o elemento NÃO pode casar nenhum X (seletores completos)
    ors:     [dynamic]Selector, // :is(A, B): o elemento precisa casar ALGUM (seletores completos)
    has:     [dynamic]Has_Arg,  // :has(S): o elemento precisa TER algo casando S (relacional)
    ors_spec: int,              // contribuição de spec do :is (máx dos args; :where = 0)
    // Contribuição de spec do :not/:has — o MÁXIMO dos argumentos (Selectors 4
    // §17), não a soma, e contado mesmo para argumento que o matching IGNORA.
    // ⚠️ separado de `nots`/`has` de propósito: `:not(:focus)` não entra em
    // `nots` (não sabemos avaliar estado num casamento estático, e negar por ele
    // esconderia a regra), mas a especificidade dele existe do mesmo jeito. Era
    // esse zero que fazia `.show-on-focus:not(:focus)` do github valer 10 e
    // perder para um utilitário de classe única.
    nots_spec: int,
    has_spec:  int,
    is_unresolved: bool,        // :is()/:where() com argumento não avaliável (ver pseudo_only)
    pseudo:      Pseudo_Kind,   // pseudo-elemento alvo (::before/::after/…)
    pseudo_only: bool,          // pseudo Other sem tag/classe/id (ex.: ::placeholder): casa com nada
    state:       Element_State, // :hover/:focus/:active exigido (None = sempre)
    // Casa NADA, tenha o composto o que tiver. Duas origens (ver
    // pseudo_never_matches e parse_compound):
    //   • pseudo-classe de ESTADO que é FALSA num render estático (`:target`,
    //     `:invalid`, `:autofill`, `:fullscreen`…). Antes caíam no balde
    //     "pseudo desconhecida" e o composto seguia casando TODO elemento —
    //     `input:invalid{border-color:red}` pintava todo input, e
    //     `#p:target{display:none}` ESCONDIA conteúdo que não era alvo.
    //   • argumento inválido/não suportado num `:nth-*()` (`:nth-child(bogus)`,
    //     `:nth-child(2n of .x)`): não sabemos casar, então não inventamos.
    never:       bool,
    // `:empty` — o elemento não pode ter filho elemento nem texto não-branco.
    // Avaliado no motor de estilo (precisa da ÁRVORE), como :nth-*/:dir.
    empty_req:   bool,
}

// Seletor complexo: cadeia de compostos (esquerda→direita; o último é o alvo)
// ligados por combinadores. combs[i] liga parts[i] a parts[i+1].
Selector :: struct {
    parts:   [dynamic]Compound,
    combs:   [dynamic]Combinator,
    spec:    int,               // projeção legada, apenas para sondas/testes
    specificity: [3]int,        // comparar lexicograficamente, sem carry entre colunas
    loose:   bool,              // usou aproximação (combinador de irmão + ~)
}

// Argumento de :has(): seletor relativo com o combinador que liga o escopo
// (o elemento sob teste) ao 1º composto. lead Descendant = ":has(.x)"; Child =
// ":has(> .x)"; Adjacent/Sibling = ":has(+ .x)"/":has(~ .x)".
Has_Arg :: struct {
    lead: Combinator,
    sel: Selector,
    group_end: bool, // alternativas OR até este ponto; grupos :has separados são AND
}

// Esquema de cor exigido por `@media (prefers-color-scheme: …)`. Any = a regra
// não depende do esquema; Light/Dark = só aplica no esquema correspondente
// (avaliado contra g_prefers_dark no motor de estilo).
Color_Scheme :: enum u8 { Any, Light, Dark }

// Ranks finais de cascade layers: normal maior vence; important inverte.
// Reservado acima dos ranks densos produzidos pelo registro (layers.odin).
LAYER_UNLAYERED :: 0x3fff_ffff // acima dos ranks densos, sem multiplicação de prioridade

// Prioridade das regras SINTETIZADAS a partir de `@property` (o valor inicial de
// uma custom property registrada). layer_compare mantém esse rank como fallback
// abaixo de qualquer regra REAL, inclusive ao inverter layers por !important.
// Aproxima initial-value: só vale onde ninguém declarou.
LAYER_REGISTERED :: -1

Rule :: struct {
    selectors: [dynamic]Selector,
    decls:     map[string]string, // propriedade -> valor
    order:     int,               // ordem de origem (desempate)
    layer_rank: int,              // LAYER_UNLAYERED ou rank hierárquico final (normal maior vence)
    // condição @media (px). min/max < 0 = sem limite; excluded = não aplicar.
    media_min:      f32,
    media_max:      f32,
    media_excluded: bool,
    media_scheme:   Color_Scheme, // prefers-color-scheme (Any = indiferente)
    // (min-/max-)aspect-ratio: limites da razão vw/vh do viewport. <0 = sem limite.
    // `A/0` (inclusive `0/0`, que a spec converte em `1/0`) = +Inf.
    media_ar_min:   f32,
    media_ar_max:   f32,
    // condição @container: avaliada contra o CONTÊINER (ancestral com
    // container-type), não contra o viewport. name=="" → qualquer contêiner.
    cq_active: bool,
    cq_name:   string,
    cq_min, cq_max: f32,
    // Regra SINTÉTICA de `@property … { inherits: false }`. A regra em si é a
    // mesma `:root{--x:V}` das outras (é o que dá o valor onde ninguém declarou),
    // mas o passe de estilo precisa saber que a propriedade NÃO herda: um
    // descendente que não a declara volta ao valor inicial em vez de ver a do
    // ancestral. Marcado aqui — e não num registro global — para não haver estado
    // de parse com tempo de vida próprio: a Rule já é possuída e liberada.
    reg_noinherit: bool,
}

// Condição de um bloco @container, propagada pelo parse_block.
Container_Q :: struct { active: bool, name: string, min, max: f32 }

// Condição de uma media query (subconjunto: min/max-width + tipo + esquema de cor).
@(private)
// `unknown` e `no_match` são TRANSIENTES do parse — são os valores U e F da lógica
// de 3 valores da MQ4 (`unknown` = feature <general-enclosed> que não sabemos avaliar;
// `no_match` = feature que sabemos avaliar e deu FALSO, ex.: `(hover: none)` num
// desktop com mouse). Os dois PRECISAM ser distintos por causa do `not`: ele inverte
// T↔F mas MANTÉM U. `parse_media_query` os resolve em `excluded` antes de retornar,
// então nenhum dos dois chega ao Rule.
Media :: struct { min, max: f32, excluded: bool, scheme: Color_Scheme, ar_min, ar_max: f32, unknown: bool, no_match: bool }

// Condição VAZIA (casa qualquer viewport): os limites usam -1 como "sem limite", o
// resto é zero-value. Por campo NOMEADO de propósito — somar um campo ao Media não
// pode quebrar em silêncio um literal posicional.
@(private)
media_any :: proc() -> Media {
    return Media{min = -1, max = -1, ar_min = -1, ar_max = -1}
}

// CAPACIDADE DO DISPOSITIVO (media queries de interação, MQ4 §10). Somos uma janela
// de DESKTOP com mouse: `:hover` funciona de verdade (o `--render` recebe a posição
// do cursor e o interativo rastreia o mouse) e o ponteiro é FINO. Se algum dia
// houver backend de toque, é aqui que a resposta muda.
@(private)
HOVER_CAPABLE :: true
@(private)
POINTER_FINE  :: true

// @keyframes: um stop (0%/50%/from/to) e o conjunto nomeado.
Keyframe :: struct { pct: f32, decls: map[string]string }
Keyframe_Set :: struct { name: string, stops: [dynamic]Keyframe }

// ── Parsing ─────────────────────────────────────────────────────────────────

// Devolve as regras e os @keyframes coletados (nome → stops). Ambos owned.
// As `@font-face` são DESCARTADAS aqui — quem precisa delas chama
// `parse_with_faces` (só o pipeline de página; manter esta assinatura evita
// churn em ~40 chamadas de teste que não têm nada a ver com fontes).
parse :: proc(input: string) -> (rules: [dynamic]Rule, keyframes: [dynamic]Keyframe_Set) {
    r, k, f := parse_with_faces(input)
    free_faces(&f)
    return r, k
}

// Como `parse`, mas devolve também as `@font-face` coletadas (owned; liberar com
// `free_faces`).
parse_with_faces :: proc(input: string) -> (rules: [dynamic]Rule, keyframes: [dynamic]Keyframe_Set, faces: [dynamic]Font_Face) {
    src := strip_comments(input, context.temp_allocator)
    order := 0
    layers: Layer_Registry
    defer delete(layers.nodes)
    parse_block(src, &rules, &keyframes, &faces, &order, media_any(), LAYER_UNLAYERED, &layers)
    layer_finalize(&layers, rules[:])
    return
}

// Parseia regras recursivamente. layer_rank é a identidade transitória do
// layer atual; só parse_with_faces a converte para rank final.
@(private)
parse_block :: proc(src: string, rules: ^[dynamic]Rule, keyframes: ^[dynamic]Keyframe_Set, faces: ^[dynamic]Font_Face, order: ^int, media: Media, layer_rank: int, layers: ^Layer_Registry, cq := Container_Q{}) {
    i := 0
    n := len(src)

    for i < n {
        for i < n && is_space(src[i]) do i += 1
        if i >= n do break

        if src[i] == '@' {
            // palavra-chave do at-rule. Também para em '(' — o CSS MINIFICADO cola
            // a condição na keyword sem espaço (`@media(min-width:64rem)`); sem isto
            // a keyword virava "media(min-width:64rem)", `kw=="media"` falhava e o
            // bloco @media INTEIRO era pulado (Tailwind responsivo `sm:`/`lg:` sumia).
            kw_start := i + 1
            j := kw_start
            for j < n && !is_space(src[j]) && src[j] != '{' && src[j] != ';' && src[j] != '(' do j += 1
            kw := strings.to_lower(src[kw_start:j], context.temp_allocator)

            if kw == "media" {
                // prelúdio (condição) até '{'
                pre_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n do break
                cond := parse_media_query(src[pre_start:j])
                j += 1 // pula '{'
                // bloco balanceado
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                parse_block(src[blk_start:blk_end], rules, keyframes, faces, order, combine_media(media, cond), layer_rank, layers, cq)
                i = j
                continue
            }

            // @container <nome>? (cond): como @media, mas a condição avalia contra
            // o viewport (proxy). Antes o bloco era descartado → placement perdido.
            if kw == "container" {
                pre_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n do break
                prelude := src[pre_start:j]
                cond := parse_container_query(prelude)
                inner := Container_Q{active = true, name = container_query_name(prelude),
                                     min = cond.min, max = cond.max}
                // @container aninhado: o mais INTERNO manda (aninhar é raro).
                j += 1 // pula '{'
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                parse_block(src[blk_start:blk_end], rules, keyframes, faces, order, media, layer_rank, layers, inner)
                i = j
                continue
            }

            // @keyframes nome { 0%{...} 50%{...} to{...} }: coleta os stops.
            if kw == "keyframes" || strings.has_suffix(kw, "-keyframes") { // -webkit-keyframes
                name_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n do break
                name := strings.trim_space(src[name_start:j])
                j += 1 // '{'
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                parse_keyframes(name, src[blk_start:blk_end], keyframes)
                i = j
                continue
            }

            // @supports: a condição é AVALIADA (supports.odin). Falsa ⇒ o bloco
            // INTEIRO é descartado — é o que faz o fallback de
            // `@supports not (…)` parar de ser aplicado por cima do caminho
            // moderno. Sintaxe que não sabemos avaliar continua permissiva
            // (supports_condition devolve true), então nada de CSS some por
            // ignorância nossa.
            if kw == "supports" {
                cond_start := j
                for j < n && src[j] != '{' && src[j] != ';' do j += 1
                if j >= n || src[j] == ';' { i = j + 1; continue }
                cond := src[cond_start:j]
                j += 1 // '{'
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                if supports_condition(cond) {
                    parse_block(src[blk_start:blk_end], rules, keyframes, faces, order, media, layer_rank, layers, cq)
                }
                i = j
                continue
            }

            // @layer: statements registram ordem; blocos reabrem identidades.
            // Wrappers vendor continuam transparentes, sem criar layers.
            if kw == "layer" ||
               strings.has_prefix(kw, "-webkit-") || strings.has_prefix(kw, "-moz-") {
                pre_start := j
                j = layer_prelude_end(src, j)
                if j >= n do break
                inner_layer := layer_rank
                if kw == "layer" {
                    inner_layer = layer_prelude(layers, layer_rank, src[pre_start:j], src[j] == '{')
                }
                if src[j] == ';' { i = j + 1; continue }
                j += 1
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                if inner_layer != -1 {
                    parse_block(src[blk_start:blk_end], rules, keyframes, faces, order, media, inner_layer, layers, cq)
                }
                i = j
                continue
            }

            // @property --nome { syntax:…; inherits:…; initial-value: V }
            if kw == "property" {
                name_start := j
                for j < n && src[j] != '{' && src[j] != ';' do j += 1
                if j >= n do break
                if src[j] == ';' { i = j + 1; continue } // sem corpo: inválido
                name := strings.trim_space(src[name_start:j])
                j += 1 // '{'
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                register_property(name, src[blk_start:blk_end], rules, order, media, cq)
                i = j
                continue
            }

            // @font-face { font-family: …; src: url(…) format(…) } — a face é
            // DESCRITA aqui; baixar/decodificar/injetar no atlas é do ui.
            if kw == "font-face" {
                for j < n && src[j] != '{' && src[j] != ';' do j += 1
                if j >= n || src[j] == ';' { i = j + 1; continue }
                j += 1 // '{'
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                if faces != nil do parse_font_face(src[blk_start:blk_end], faces)
                i = j
                continue
            }

            // outros @-rules (@import...): pula
            i = skip_at_rule(src, i)
            continue
        }

        // regra normal: seletor até '{'; o corpo pode ter declarações e regras
        // aninhadas (CSS nesting) — parse_rule_body consome até o '}' do corpo.
        sel_start := i
        for i < n && src[i] != '{' do i += 1
        if i >= n do break
        sel_text := strings.trim_space(src[sel_start:i])
        i += 1
        i = parse_rule_body(src, i, sel_text, rules, keyframes, order, media, layer_rank, layers, cq)
    }
}

// Corpo de uma regra: declarações planas + regras aninhadas (CSS nesting) +
// @media aninhado. Consome até o '}' que fecha o corpo (ou o fim do texto) e
// devolve o índice seguinte. Emite a regra do próprio seletor (se houver
// declarações) com a ordem reservada ANTES das aninhadas — na cascata, as
// declarações do pai vêm antes das regras aninhadas, como na spec.
@(private)
parse_rule_body :: proc(src: string, start: int, sel_text: string, rules: ^[dynamic]Rule, keyframes: ^[dynamic]Keyframe_Set, order: ^int, media: Media, layer_rank: int, layers: ^Layer_Registry, cq := Container_Q{}) -> int {
    n := len(src)
    i := start
    decls_sb := strings.builder_make(context.temp_allocator)
    my_order := order^
    order^ += 1

    for i < n {
        for i < n && is_space(src[i]) do i += 1
        if i >= n do break
        if src[i] == '}' { i += 1; break }

        if src[i] == '@' {
            kw_start := i + 1
            j := kw_start
            for j < n && !is_space(src[j]) && src[j] != '{' && src[j] != ';' && src[j] != '(' do j += 1
            kw := strings.to_lower(src[kw_start:j], context.temp_allocator)
            // @layer em CSS nesting mantém o seletor e muda somente o layer.
            if kw == "layer" {
                pre_start := j
                j = layer_prelude_end(src, j)
                if j >= n { i = n; break }
                inner_layer := layer_prelude(layers, layer_rank, src[pre_start:j], src[j] == '{')
                if src[j] == ';' { i = j + 1; continue }
                j += 1
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                if inner_layer != -1 {
                    parse_rule_body(src[blk_start:blk_end], 0, sel_text, rules, keyframes, order, media, inner_layer, layers, cq)
                }
                i = j
                continue
            }
            // @media aninhado: o bloco contém declarações/aninhadas do MESMO
            // seletor, com a condição combinada.
            if kw == "media" {
                pre_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n { i = n; break }
                cond := parse_media_query(src[pre_start:j])
                j += 1
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                parse_rule_body(src[blk_start:blk_end], 0, sel_text, rules, keyframes, order, combine_media(media, cond), layer_rank, layers, cq)
                i = j
                continue
            }
            // @supports ANINHADO (CSS nesting): antes caía no skip_at_rule e o
            // bloco era descartado inteiro — o erro oposto ao do top-level.
            // Condição verdadeira ⇒ o conteúdo pertence ao MESMO seletor (como
            // o @media aninhado), sem mexer na media.
            if kw == "supports" {
                pre_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n { i = n; break }
                cond := src[pre_start:j]
                j += 1
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                if supports_condition(cond) {
                    parse_rule_body(src[blk_start:blk_end], 0, sel_text, rules, keyframes, order, media, layer_rank, layers, cq)
                }
                i = j
                continue
            }
            // @container aninhado: mesma condição-como-media (proxy viewport)
            if kw == "container" {
                pre_start := j
                for j < n && src[j] != '{' do j += 1
                if j >= n { i = n; break }
                cond := parse_container_query(src[pre_start:j])
                j += 1
                depth := 1
                blk_start := j
                for j < n && depth > 0 {
                    if src[j] == '{' do depth += 1
                    else if src[j] == '}' do depth -= 1
                    j += 1
                }
                blk_end := depth == 0 ? j - 1 : n
                parse_rule_body(src[blk_start:blk_end], 0, sel_text, rules, keyframes, order, combine_media(media, cond), layer_rank, layers, cq)
                i = j
                continue
            }
            i = skip_at_rule(src, i)
            continue
        }

        // segmento até '{' (regra aninhada), ';' (declaração) ou '}' (última
        // declaração do corpo). ()/[] protegem ; e { internos (ex.: url()).
        seg_start := i
        depth := 0
        kind: u8 = 0
        for i < n {
            ch := src[i]
            if ch == '(' || ch == '[' do depth += 1
            else if ch == ')' || ch == ']' { if depth > 0 do depth -= 1 }
            else if depth == 0 && (ch == '{' || ch == ';' || ch == '}') {
                kind = ch
                break
            }
            i += 1
        }

        if kind == '{' {
            nested_sel := strings.trim_space(src[seg_start:i])
            i += 1
            combined := combine_nested_selector(sel_text, nested_sel)
            i = parse_rule_body(src, i, combined, rules, keyframes, order, media, layer_rank, layers, cq)
            continue
        }
        seg := strings.trim_space(src[seg_start:i])
        if seg != "" {
            strings.write_string(&decls_sb, seg)
            strings.write_byte(&decls_sb, ';')
        }
        if kind == ';' do i += 1
        // '}' fica para o topo do loop fechar o corpo
    }

    // emite mesmo com corpo vazio (a{}) — consumidores contam as regras
    sels := parse_selector_list(sel_text)
    if len(sels) > 0 {
        append(rules, Rule{
            selectors      = sels,
            decls          = parse_decls(strings.to_string(decls_sb), context.allocator),
            order          = my_order,
            layer_rank     = layer_rank,
            media_min      = media.min,
            media_max      = media.max,
            media_excluded = media.excluded,
            media_scheme   = media.scheme,
            media_ar_min   = media.ar_min,
            media_ar_max   = media.ar_max,
            cq_active      = cq.active,
            cq_name        = strings.clone(cq.name), // OWNED (ver free_rules)
            cq_min         = cq.min,
            cq_max         = cq.max,
        })
    } else {
        delete(sels)
    }
    return i
}

// `@property --nome { … initial-value: V }` vira a regra SINTÉTICA `:root{--nome:V}`
// com prioridade LAYER_REGISTERED (abaixo de tudo), então ela só decide onde ninguém
// declarou — que é o efeito observável de um valor inicial registrado.
//
// Por que importa: o **Tailwind v4 declara `--tw-translate-x/y/z`, `--tw-scale-*` e
// `--tw-skew-*` SÓ aqui**, e depois escreve `translate: var(--tw-translate-x)
// var(--tw-translate-y)`. Sem registro, metade das variáveis não resolvia e a
// declaração inteira era descartada: NENHUMA utilidade de transform do site
// funcionava (`hover:-translate-y-1`, `group-hover:scale-105`, …).
//
// ⚠️ DEGRADAÇÕES (cada uma com teste dizendo qual é):
//   • `inherits: false` NÃO é honrado — a variável entra na raiz e herda pela árvore
//     toda, então um descendente enxerga o valor do ANCESTRAL onde deveria ver o
//     inicial. O caso que importa (ninguém declarou ⇒ use o inicial) fica correto.
//   • `syntax` não é validado: um valor que não casa o tipo declarado deveria tornar
//     a declaração inválida, e aqui passa.
//   • sem `initial-value` não registramos nada (a spec exige o descritor p/ syntax
//     não-universal; com `syntax:"*"` o inicial é o valor garantido-inválido, que é
//     justamente o que já acontece quando a variável não existe).
@(private = "file")
register_property :: proc(name: string, body: string, rules: ^[dynamic]Rule, order: ^int, media: Media, cq: Container_Q) {
    if !strings.has_prefix(name, "--") do return
    d := parse_decls(body, context.temp_allocator)
    init, ok := d["initial-value"]
    if !ok do return
    // `inherits` é obrigatório na spec; ausente, assumimos `true` (o comportamento
    // natural de custom property) em vez de descartar o registro.
    noinherit := false
    if iv, k := d["inherits"]; k {
        noinherit = strings.equal_fold(strings.trim_space(iv), "false")
    }
    sels := parse_selector_list(":root")
    if len(sels) == 0 do return
    decls := make(map[string]string)
    decls[strings.clone(name)] = strings.clone(strings.trim_space(init))
    my_order := order^
    order^ += 1
    append(rules, Rule{
        selectors      = sels,
        decls          = decls,
        order          = my_order,
        layer_rank     = LAYER_REGISTERED,
        media_min      = media.min,
        media_max      = media.max,
        media_excluded = media.excluded,
        media_scheme   = media.scheme,
        media_ar_min   = media.ar_min,
        media_ar_max   = media.ar_max,
        cq_active      = cq.active,
        cq_name        = strings.clone(cq.name), // OWNED (ver free_rules)
        cq_min         = cq.min,
        cq_max         = cq.max,
        reg_noinherit  = noinherit,
    })
}

// Combina o seletor pai com o de uma regra aninhada (produto cartesiano das
// listas). '&' é substituído textualmente pelo seletor pai; sem '&', o
// aninhado é relativo ao pai como descendente ("pai aninhado" — cobre também
// "> .x", que vira "pai > .x"). Resultado em temp_allocator (mesma vida do
// texto-fonte das regras).
@(private)
combine_nested_selector :: proc(parent, nested: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    first := true
    for np in split_selector_list_top(nested) {
        ns := strings.trim_space(np)
        if ns == "" do continue
        for pp in split_selector_list_top(parent) {
            ps := strings.trim_space(pp)
            if ps == "" do continue
            if !first do strings.write_string(&sb, ", ")
            first = false
            if strings.contains(ns, "&") {
                for ci in 0 ..< len(ns) {
                    if ns[ci] == '&' do strings.write_string(&sb, ps)
                    else             do strings.write_byte(&sb, ns[ci])
                }
            } else {
                strings.write_string(&sb, ps)
                strings.write_byte(&sb, ' ')
                strings.write_string(&sb, ns)
            }
        }
    }
    return strings.to_string(sb)
}

// Avalia se uma regra se aplica ao viewport de largura vw (px).
media_matches :: proc(r: Rule, vw: f32, vh: f32 = 720, dark: bool = false) -> bool {
    // Por campo NOMEADO: os campos de media do Rule são uma CÓPIA achatada do Media.
    return media_eval(Media{
        min = r.media_min, max = r.media_max, excluded = r.media_excluded,
        scheme = r.media_scheme, ar_min = r.media_ar_min, ar_max = r.media_ar_max,
    }, vw, vh, dark)
}

// A avaliação em si, sobre a condição já parseada. Existe separada porque o
// `window.matchMedia()` do JS precisa avaliar uma condição CRUA, que nunca virou
// Rule — e duas cópias desta lógica divergiriam caladas (lição do M213).
media_eval :: proc(m: Media, vw: f32, vh: f32 = 720, dark: bool = false) -> bool {
    if m.excluded do return false
    if m.min >= 0 && vw < m.min do return false
    if m.max >= 0 && vw > m.max do return false
    if m.scheme == .Dark  && !dark do return false
    if m.scheme == .Light &&  dark do return false
    // aspect-ratio: razão vw/vh do viewport. min = razão precisa ser >= limite;
    // max = <= limite. Limite +Inf (de `A/0`): min nunca casa (razão finita),
    // max sempre casa. Igualdade exata (`aspect-ratio:R`) chega como ar_min=ar_max=R.
    if (m.ar_min >= 0 || m.ar_max >= 0) && vh > 0 {
        ar := vw / vh
        if m.ar_min >= 0 && ar < m.ar_min do return false
        if m.ar_max >= 0 && ar > m.ar_max do return false
    }
    return true
}

// `window.matchMedia(query).matches`: parseia a query CRUA e avalia contra o
// viewport. MESMO parser e MESMA avaliação do `@media` da folha de estilo — é o
// que garante que o CSS e o JS da mesma página não discordem sobre "sou mobile?".
// ⚠️ query VAZIA (ou só espaço) é lista de media INVÁLIDA: por spec vira
// `not all`, que NÃO casa — ao contrário do prelúdio vazio de um `@media`, onde
// vazio significa "sem condição" e casa sempre. Os dois usam o mesmo parser, então
// a diferença tem de ser tratada AQUI.
media_query_matches :: proc(query: string, vw: f32, vh: f32 = 720, dark: bool = false) -> bool {
    if strings.trim_space(query) == "" do return false
    return media_eval(parse_media_query(query), vw, vh, dark)
}

@(private)
combine_media :: proc(a, b: Media) -> Media {
    m: Media
    m.min = max(a.min, b.min)
    if a.max < 0      do m.max = b.max
    else if b.max < 0 do m.max = a.max
    else              do m.max = min(a.max, b.max)
    // aspect-ratio: min = o mais restritivo (maior); max = o mais restritivo (menor)
    m.ar_min = max(a.ar_min, b.ar_min)
    if a.ar_max < 0      do m.ar_max = b.ar_max
    else if b.ar_max < 0 do m.ar_max = a.ar_max
    else                 do m.ar_max = min(a.ar_max, b.ar_max)
    m.excluded = a.excluded || b.excluded
    // esquema de cor: se um lado exige e o outro é indiferente, herda a exigência;
    // se ambos exigem esquemas DIFERENTES, a condição é impossível (excluded).
    if a.scheme == .Any {
        m.scheme = b.scheme
    } else if b.scheme == .Any {
        m.scheme = a.scheme
    } else if a.scheme == b.scheme {
        m.scheme = a.scheme
    } else {
        m.excluded = true
    }
    return m
}

// Parseia a condição de uma media query. Suporta min/max-width (+ device-),
// tipos screen/all/print; recursos não suportados marcam excluded (não aplica).
@(private)
parse_media_query :: proc(prelude: string) -> Media {
    m := media_any()
    s := strings.to_lower(strings.trim_space(prelude), context.temp_allocator)
    if s == "" do return m

    // CABEÇA = tudo antes do 1º '(' = `[not|only]? <media-type>? [and]?`.
    head_end := strings.index_byte(s, '(')
    head := head_end < 0 ? s : s[:head_end]
    negate := false
    type_result := true // sem tipo explícito (só features) = "all" implícito → casa
    for word in strings.fields(head, context.temp_allocator) {
        switch word {
        case "not":  negate = true
        case "only": // dica p/ browsers legados; sem efeito
        case "and":  // conector; as features são tratadas no loop de parênteses
        case:
            // <media-type>: só screen/all casam este dispositivo (tela); print e
            // qualquer tipo DESCONHECIDO (tv/unknown/…) não casam (F definitivo).
            type_result = word == "all" || word == "screen"
        }
    }

    i := 0
    for {
        op := strings.index_byte(s[i:], '(')
        if op < 0 do break
        op += i
        // fecha no parêntese BALANCEADO (o valor pode ter calc(...) aninhado, cujo
        // ')' interno não deve encerrar o recurso — senão `min-width: calc(100in`
        // chega truncado e o calc não parseia).
        depth := 0
        cp := op
        for cp < len(s) {
            if s[cp] == '(' do depth += 1
            else if s[cp] == ')' { depth -= 1; if depth == 0 do break }
            cp += 1
        }
        if cp >= len(s) do break // sem fechamento
        apply_media_feature(&m, s[op + 1:cp])
        i = cp + 1
    }

    // Lógica de 3 valores da MQ4 {T=casa, F=não-casa, U=desconhecido}. base =
    // type_result AND features; feature <general-enclosed> desconhecida → U; feature
    // que sabemos avaliar e deu falso (`(hover: none)`) → F. **F ganha de U** (F AND U
    // = F em Kleene). `not` inverte T↔F mas MANTÉM U (not unknown = unknown). Só T faz
    // a regra aplicar; F e U → excluded. Assim: `not <tipo-desconhecido>`=T (aplica),
    // `<tipo-desconhecido>`=F, `(feature-desconhecida)`=U (não aplica),
    // `not (feature-desconhecida)`=U (não aplica), `not (hover: none)`=T (APLICA).
    base := 0 // 0=T, 1=F, 2=U
    if      !type_result || m.no_match do base = 1
    else if m.unknown                  do base = 2
    if negate {
        switch base { case 0: base = 1; case 1: base = 0; } // U permanece U
    }
    m.excluded = base != 0
    m.unknown  = false // transientes: não vazam p/ o Rule
    m.no_match = false
    return m
}

// @container <nome>? (condição): reusa a máquina de @media, mas avaliando a
// condição contra o VIEWPORT como proxy (não rastreamos o tamanho real do
// container). Extrai só o "(condição)" (a partir do 1º '('), descartando o nome
// do container — senão o nome viraria um media-type desconhecido e nada casaria.
// Mapeia inline-size/block-size p/ width/height. Sem condição => casa sempre.
// Motivo: sites modernos (ex.: MDN) põem grid-column/placement dentro de
// @container; antes o bloco INTEIRO era descartado (skip_at_rule) e os itens
// caíam em auto-place (a sidebar colapsava numa gutter).
@(private="file")
// Nome antes da condição: `@container cartao (min-width:400px)` → "cartao".
// Sem nome (ou começando por `(`/`not`/`style(`) → "" = qualquer contêiner.
container_query_name :: proc(prelude: string) -> string {
    t := strings.trim_space(prelude)
    paren := strings.index_byte(t, '(')
    if paren >= 0 do t = strings.trim_space(t[:paren])
    if t == "" do return ""
    // só um identificador simples conta como nome
    for i in 0 ..< len(t) {
        c := t[i]
        if !(c == '-' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) do return ""
    }
    if t == "not" || t == "and" || t == "or" do return ""
    return t
}

parse_container_query :: proc(prelude: string) -> Media {
    paren := strings.index_byte(prelude, '(')
    if paren < 0 do return parse_media_query("") // sem condição → casa sempre
    cond := prelude[paren:]
    cond, _ = strings.replace_all(cond, "inline-size", "width",  context.temp_allocator)
    cond, _ = strings.replace_all(cond, "block-size",  "height", context.temp_allocator)
    return parse_media_query(cond)
}

// ── Media queries de RANGE (MQ4) ────────────────────────────────────────────
// `(width >= 40rem)`, `(width < 80rem)`, `(40rem <= width)` e a forma de dois
// lados `(40rem <= width < 80rem)`. É a grafia que o **Tailwind v4 emite por
// padrão** — nada de `min-width:`. Sem isto a feature não tinha ':', virava
// <general-enclosed> desconhecida e o bloco @media INTEIRO era descartado: todo
// `sm:`/`lg:` do site sumia e a página caía no layout MOBILE dentro de um
// viewport de desktop (grids de 1 coluna, `.container` sem max-width).
@(private="file")
Media_Cmp :: enum { Lt, Le, Gt, Ge, Eq }

// `<` e `>` são ESTRITOS; como só guardamos min/max inclusivos, desloca-se o
// limite por um epsilon de sub-pixel (o viewport é medido em px inteiros, então
// nenhuma largura real cai no vão).
@(private="file")
RANGE_EPS :: f32(0.001)

@(private="file")
flip_cmp :: proc(c: Media_Cmp) -> Media_Cmp {
    switch c {
    case .Lt: return .Gt
    case .Le: return .Ge
    case .Gt: return .Lt
    case .Ge: return .Le
    case .Eq: return .Eq
    }
    return c
}

// Identificador de feature: só letras minúsculas e '-' (a condição já chega em
// caixa baixa). É o que separa `width` de `40rem` nos dois lados do comparador.
@(private="file")
is_feature_ident :: proc(s: string) -> bool {
    if s == "" do return false
    for i in 0 ..< len(s) {
        c := s[i]
        if !(c == '-' || (c >= 'a' && c <= 'z')) do return false
    }
    return true
}

// Aplica `nome <cmp> valor` com o NOME sempre à esquerda (quem inverte é o
// chamador, via flip_cmp). Limite negativo é fixado em 0: nenhum viewport é
// negativo, então `width >= -5px` casa sempre e `width < 0px` casa nunca.
@(private="file")
apply_range_cmp :: proc(m: ^Media, name: string, cmp: Media_Cmp, val: string) {
    switch name {
    case "width", "device-width":
        px, ok := parse_media_len(val)
        if !ok { m.unknown = true; return }
        switch cmp {
        case .Ge: m.min = max(px, 0)
        case .Gt: m.min = max(px + RANGE_EPS, 0)
        case .Le: m.max = max(px, 0)
        case .Lt: m.max = max(px - RANGE_EPS, 0)
        case .Eq: m.min = max(px, 0); m.max = max(px, 0)
        }
    case "aspect-ratio", "device-aspect-ratio":
        r, ok := parse_media_ratio(val)
        if !ok { m.unknown = true; return }
        // degradação anotada: estrito e não-estrito colapsam no mesmo limite
        // (ar_min/ar_max não têm epsilon; a razão é contínua, não px inteiro).
        switch cmp {
        case .Ge, .Gt: m.ar_min = r
        case .Le, .Lt: m.ar_max = r
        case .Eq:      m.ar_min = r; m.ar_max = r
        }
    case: m.unknown = true // height/resolution/…: não modelados, segue <general-enclosed>
    }
}

// Devolve true se a feature É de range (achou comparador fora de parênteses) —
// tendo ou não conseguido interpretá-la. Comparador dentro de calc(...) não
// conta (daí o controle de profundidade).
@(private="file")
try_range_feature :: proc(m: ^Media, feat: string) -> bool {
    ops: [2]Media_Cmp
    at:  [2]int // início do comparador
    to:  [2]int // fim (exclusivo)
    n := 0
    depth := 0
    for i := 0; i < len(feat); i += 1 {
        c := feat[i]
        if c == '(' { depth += 1; continue }
        if c == ')' { depth -= 1; continue }
        if depth != 0 do continue
        if c != '<' && c != '>' && c != '=' do continue
        if n >= 2 { m.unknown = true; return true } // 3+ comparadores: inválido
        eq := i + 1 < len(feat) && feat[i + 1] == '='
        oplen := 1
        switch c {
        case '<': ops[n] = eq ? .Le : .Lt; if eq do oplen = 2
        case '>': ops[n] = eq ? .Ge : .Gt; if eq do oplen = 2
        case '=': ops[n] = .Eq
        }
        at[n] = i
        to[n] = i + oplen
        i = to[n] - 1
        n += 1
    }
    if n == 0 do return false

    if n == 1 {
        left  := strings.trim_space(feat[:at[0]])
        right := strings.trim_space(feat[to[0]:])
        if is_feature_ident(left) {
            apply_range_cmp(m, left, ops[0], right)
        } else if is_feature_ident(right) {
            apply_range_cmp(m, right, flip_cmp(ops[0]), left) // `40rem <= width`
        } else {
            m.unknown = true
        }
        return true
    }
    // dois lados: `<valor> <op> <nome> <op> <valor>` — o nome fica no MEIO.
    left  := strings.trim_space(feat[:at[0]])
    mid   := strings.trim_space(feat[to[0]:at[1]])
    right := strings.trim_space(feat[to[1]:])
    if !is_feature_ident(mid) { m.unknown = true; return true }
    apply_range_cmp(m, mid, flip_cmp(ops[0]), left)
    apply_range_cmp(m, mid, ops[1], right)
    return true
}

// Feature em CONTEXTO BOOLEANO: `(hover)` = "o dispositivo tem hover?". Só vale p/ os
// recursos de interação; qualquer outro nome segue <general-enclosed> desconhecido.
@(private = "file")
apply_boolean_feature :: proc(m: ^Media, name: string) {
    switch name {
    case "hover", "any-hover":     if !HOVER_CAPABLE do m.no_match = true
    case "pointer", "any-pointer": if !POINTER_FINE  do m.no_match = true
    case: m.unknown = true
    }
}

@(private)
apply_media_feature :: proc(m: ^Media, feat: string) {
    colon := strings.index_byte(feat, ':')
    if colon < 0 {
        // sem ':' pode ainda ser range (`width>=40rem`) ou booleana (`(hover)`);
        // só depois disso é <general-enclosed> desconhecida.
        if try_range_feature(m, feat) do return
        apply_boolean_feature(m, strings.trim_space(feat))
        return
    }
    name := strings.trim_space(feat[:colon])
    val  := strings.trim_space(feat[colon + 1:])
    // aspect-ratio (device- é aproximado pelo viewport): razão <n> [/ <n>].
    switch name {
    case "min-aspect-ratio", "min-device-aspect-ratio":
        if r, k := parse_media_ratio(val); k do m.ar_min = r
        else do m.unknown = true
        return
    case "max-aspect-ratio", "max-device-aspect-ratio":
        if r, k := parse_media_ratio(val); k do m.ar_max = r
        else do m.unknown = true
        return
    case "aspect-ratio", "device-aspect-ratio":
        if r, k := parse_media_ratio(val); k { m.ar_min = r; m.ar_max = r }
        else do m.unknown = true
        return
    // ── Recursos de INTERAÇÃO (MQ4 §10) ─────────────────────────────────────
    // `@media (hover: hover)` é o que o **Tailwind emite p/ o variant `hover:`** —
    // enquanto caía em <general-enclosed>, TODO estilo de hover do site era
    // descartado (o bloco tem os `hover:*` e `group-hover:*` inteiros).
    case "hover", "any-hover":
        switch val {
        case "hover": if !HOVER_CAPABLE do m.no_match = true
        case "none":  if  HOVER_CAPABLE do m.no_match = true
        case:         m.unknown = true // valor fora da spec
        }
        return
    case "pointer", "any-pointer":
        switch val {
        case "fine":           if !POINTER_FINE do m.no_match = true
        case "coarse", "none": if  POINTER_FINE do m.no_match = true
        case:                  m.unknown = true
        }
        return
    }
    px, ok := parse_media_len(val)
    switch name {
    case "min-width", "min-device-width": if ok do m.min = px
    case "max-width", "max-device-width": if ok do m.max = px
    case "width", "device-width":         if ok { m.min = px; m.max = px }
    case "prefers-color-scheme":
        switch strings.trim_space(feat[colon + 1:]) {
        case "dark":  m.scheme = .Dark
        case "light": m.scheme = .Light
        case:         m.unknown = true // valor desconhecido
        }
    case: m.unknown = true // recurso não suportado (orientation, hover, pointer, etc.)
    }
}

// Razão de media query: `<number> [ / <number> ]?`. Sem `/` = número/1. Um
// denominador 0 (inclui `0/0`, que a spec converte em `1/0`) → +Inf. Numerador 0
// com denominador>0 → 0. Números negativos/invalidos → (0,false) (recurso descartado).
@(private)
parse_media_ratio :: proc(v: string) -> (f32, bool) {
    s := strings.trim_space(v)
    num_s := s
    den_s := "1"
    if slash := strings.index_byte(s, '/'); slash >= 0 {
        num_s = strings.trim_space(s[:slash])
        den_s = strings.trim_space(s[slash + 1:])
    }
    num, ok1 := strconv.parse_f64(num_s)
    den, ok2 := strconv.parse_f64(den_s)
    if !ok1 || !ok2 || num < 0 || den < 0 do return 0, false
    if den == 0 do return math.inf_f32(1), true // A/0 (e 0/0) → infinito
    return f32(num / den), true
}

// Converte <número> + unidade absoluta p/ px. in/cm/mm/q/pt/pc são absolutas;
// em/rem usam 16px AQUI DE PROPÓSITO: este conversor só serve a MEDIA QUERY
// (parse_media_len/calc_conv_px), e em media query as unidades relativas à fonte
// valem o valor INICIAL de font-size, não o computado da raiz (CSS Values §5.1.3
// e Media Queries 4 §1.3). ⚠️ NÃO troque por uma base "de verdade": o `rem` que
// segue o `<html>` é o do pacote ui (style.odin, `rem_px`), e são coisas
// diferentes — `html{font-size:62.5%}` muda o rem das declarações e NÃO muda o
// da `@media (width>=40rem)`. Unidade desconhecida = px.
@(private)
len_unit_px :: proc(n: f64, unit: string) -> f32 {
    switch strings.trim_space(unit) {
    case "px", "":    return f32(n)
    case "in":        return f32(n * 96)
    case "cm":        return f32(n * 96 / 2.54)
    case "mm":        return f32(n * 96 / 25.4)
    case "q":         return f32(n * 96 / 25.4 / 4)
    case "pt":        return f32(n * 96 / 72)
    case "pc":        return f32(n * 16)
    case "em", "rem": return f32(n * 16)
    }
    return f32(n) // desconhecida: assume px
}

// Fim do NÚMERO CSS que começa em `start`: dígitos, '.', e o expoente científico
// (`e`/`E` + sinal opcional + dígitos). Devolve o próprio `start` quando não há
// número. É a ÚNICA rotina de varredura de número do motor — o `parse_len` do
// pacote ui também chama esta, para que "que grafia de número existe" tenha um
// lugar só.
//
// ⚠️ O expoente só é consumido se houver DÍGITO depois: `3em` e `2ex` também têm
// `e` colado no número, e engoli-lo mataria toda unidade que começa com 'e'.
// Motivo de existir: o Tailwind v4 escreve `rounded-full` como
// `border-radius: 3.40282e38px` — sem expoente, o número parava no `e`, a unidade
// virava "e38px" e a declaração inteira era descartada.
scan_number_end :: proc(s: string, start: int, allow_sign := false) -> int {
    i := start
    if allow_sign && i < len(s) && (s[i] == '+' || s[i] == '-') do i += 1
    dig := i
    for i < len(s) && (s[i] == '.' || (s[i] >= '0' && s[i] <= '9')) do i += 1
    if i == dig do return start // nenhum dígito: não é número
    if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
        k := i + 1
        if k < len(s) && (s[k] == '+' || s[k] == '-') do k += 1
        d := k
        for d < len(s) && s[d] >= '0' && s[d] <= '9' do d += 1
        if d > k do i = d // havia expoente de verdade
    }
    return i
}

@(private)
parse_media_len :: proc(v: string) -> (f32, bool) {
    s := strings.trim_space(v)
    if strings.has_prefix(s, "calc(") && strings.has_suffix(s, ")") {
        return eval_calc_px(s[5:len(s) - 1])
    }
    end := scan_number_end(s, 0)
    if end == 0 do return 0, false
    n, ok := strconv.parse_f64(s[:end])
    if !ok do return 0, false
    return len_unit_px(n, s[end:]), true
}

// Conversor de <número><unidade> p/ o valor final de um calc(), por DOMÍNIO (px
// p/ media; fração-do-giro p/ ângulos de gradiente). Devolve ok=false se a unidade
// não pertence ao domínio (rejeita o calc inteiro).
Calc_Conv :: proc(n: f64, unit: string) -> (f32, bool)

// Domínio de comprimento (media queries): unidades de length → px; % é inválido.
@(private)
calc_conv_px :: proc(n: f64, unit: string) -> (f32, bool) {
    if strings.trim_space(unit) == "%" do return 0, false
    return len_unit_px(n, unit), true
}

// Domínio ângulo/porcentagem (color-stops conic e ângulos de gradiente) → FRAÇÃO
// do giro completo (0..1). Para conic, 100% = 1 volta = 360deg (per css-images-4).
// Número puro = fator adimensional (multiplicações). Unidade fora do domínio → falha.
@(private)
calc_conv_turn :: proc(n: f64, unit: string) -> (f32, bool) {
    switch strings.to_lower(strings.trim_space(unit), context.temp_allocator) {
    case "":     return f32(n), true
    case "%":    return f32(n / 100), true
    case "deg":  return f32(n / 360), true
    case "grad": return f32(n * 0.9 / 360), true
    case "turn": return f32(n), true
    case "rad":  return f32(n * (180 / math.PI) / 360), true
    }
    return 0, false
}

// Avalia a expressão INTERNA de um calc() de media query em px (recursivo:
// expr = term (('+'|'-') term)*; term = fator (('*'|'/') fator)*; fator =
// <número><unidade> | '(' expr ')'). * e / operam numericamente. Devolve
// (0,false) se malformado ou sobrar lixo.
@(private)
eval_calc_px :: proc(expr: string) -> (f32, bool) {
    return eval_calc_domain(expr, calc_conv_px)
}

// Avalia calc() no domínio ângulo/% → fração do giro (0..1). Ex.: eval_calc_turn(
// "0deg + 100%")=1.0, ("90deg + 0%")=0.25. Usado por conic_pos e angle_to_deg.
@(private)
eval_calc_turn :: proc(expr: string) -> (f32, bool) {
    return eval_calc_domain(expr, calc_conv_turn)
}

@(private)
eval_calc_domain :: proc(expr: string, conv: Calc_Conv) -> (f32, bool) {
    p := 0
    v, ok := calc_expr(expr, &p, conv)
    for p < len(expr) && expr[p] == ' ' do p += 1
    if !ok || p != len(expr) do return 0, false
    return v, true
}

@(private)
calc_skip_ws :: proc(s: string, p: ^int) { for p^ < len(s) && s[p^] == ' ' do p^ += 1 }

@(private)
calc_expr :: proc(s: string, p: ^int, conv: Calc_Conv) -> (f32, bool) {
    v, ok := calc_term(s, p, conv)
    if !ok do return 0, false
    for {
        calc_skip_ws(s, p)
        if p^ >= len(s) do break
        op := s[p^]
        if op != '+' && op != '-' do break
        p^ += 1
        rhs, ok2 := calc_term(s, p, conv)
        if !ok2 do return 0, false
        v = op == '+' ? v + rhs : v - rhs
    }
    return v, true
}

@(private)
calc_term :: proc(s: string, p: ^int, conv: Calc_Conv) -> (f32, bool) {
    v, ok := calc_factor(s, p, conv)
    if !ok do return 0, false
    for {
        calc_skip_ws(s, p)
        if p^ >= len(s) do break
        op := s[p^]
        if op != '*' && op != '/' do break
        p^ += 1
        rhs, ok2 := calc_factor(s, p, conv)
        if !ok2 do return 0, false
        if op == '/' && rhs == 0 do return 0, false
        v = op == '*' ? v * rhs : v / rhs
    }
    return v, true
}

@(private)
calc_factor :: proc(s: string, p: ^int, conv: Calc_Conv) -> (f32, bool) {
    calc_skip_ws(s, p)
    if p^ >= len(s) do return 0, false
    if s[p^] == '(' {
        p^ += 1
        v, ok := calc_expr(s, p, conv)
        if !ok do return 0, false
        calc_skip_ws(s, p)
        if p^ >= len(s) || s[p^] != ')' do return 0, false
        p^ += 1
        return v, true
    }
    start := p^
    p^ = scan_number_end(s, start, true) // mesmo scanner do resto do motor (inclui expoente)
    if p^ == start do return 0, false
    n, ok := strconv.parse_f64(s[start:p^])
    if !ok do return 0, false
    // unidade: letras coladas ao número (+ '%' p/ o domínio angular)
    us := p^
    for p^ < len(s) && ((s[p^] >= 'a' && s[p^] <= 'z') || (s[p^] >= 'A' && s[p^] <= 'Z') || s[p^] == '%') do p^ += 1
    return conv(n, s[us:p^])
}

@(private)
skip_at_rule :: proc(src: string, start: int) -> int {
    i := start
    n := len(src)
    for i < n && src[i] != '{' && src[i] != ';' do i += 1
    if i >= n do return n
    if src[i] == ';' do return i + 1
    // bloco balanceado
    depth := 0
    for i < n {
        if src[i] == '{' do depth += 1
        else if src[i] == '}' {
            depth -= 1
            if depth == 0 do return i + 1
        }
        i += 1
    }
    return n
}

// Separa uma lista de seletores por vírgula no nível superior — vírgulas
// dentro de (parênteses) ou [colchetes] pertencem ao seletor (ex.: :not(a, b),
// [title="a,b"]). Resultado em temp_allocator.
@(private)
split_selector_list_top :: proc(text: string) -> []string {
    parts := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(text) {
        switch text[i] {
        case '(', '[': depth += 1
        case ')', ']': if depth > 0 do depth -= 1
        case ',': if depth == 0 { append(&parts, text[start:i]); start = i + 1 }
        }
    }
    append(&parts, text[start:])
    return parts[:]
}

// Parseia um texto de seletor avulso (ex.: vindo de querySelector) na lista de
// Selectors. Público: o matcher em ui/style usa p/ consultas do JS. Liberar
// cada um com free_selector + delete da lista. ATENÇÃO: os seletores fatiam
// `text` — case e libere enquanto `text` vive (não retenha).
parse_selectors :: proc(text: string) -> [dynamic]Selector {
    return parse_selector_list(text)
}

@(private)
parse_selector_list :: proc(text: string) -> [dynamic]Selector {
    sels: [dynamic]Selector
    for part in split_selector_list_top(text) {
        s := strings.trim_space(part)
        if s == "" do continue
        sel, ok := parse_complex(s)
        if ok do append(&sels, sel)
    }
    return sels
}

// Parseia um seletor complexo: cadeia de compostos ligados por combinadores
// (espaço = descendente, '>' = filho, '+' = irmão adjacente, '~' = irmão geral).
@(private)
parse_complex :: proc(sel: string) -> (Selector, bool) {
    out: Selector
    i := 0
    n := len(sel)
    next_comb := Combinator.Descendant
    pending := false // há um combinador/espaço aguardando antes do próximo composto

    for i < n {
        c := sel[i]
        switch c {
        case ' ', '\t', '\n', '\r', '\f':
            if len(out.parts) > 0 do pending = true
            i += 1
            continue
        case '>':
            next_comb = .Child; pending = true; i += 1
            continue
        case '+':
            next_comb = .Adjacent; pending = true; i += 1
            continue
        case '~':
            next_comb = .Sibling; pending = true; i += 1
            continue
        }
        // composto: lê até o próximo combinador/espaço. Espaços/combinadores
        // dentro de [colchetes] ou (parênteses) pertencem ao composto — ex.:
        // [title="a b"], :nth-child(-n + 3).
        start := i
        depth := 0
        for i < n {
            ch := sel[i]
            if ch == '[' || ch == '(' do depth += 1
            else if ch == ']' || ch == ')' { if depth > 0 do depth -= 1 }
            else if depth == 0 && is_sel_boundary(ch) do break
            i += 1
        }
        comp, ok := parse_compound(sel[start:i])
        if !ok do continue
        if len(out.parts) > 0 && pending {
            append(&out.combs, next_comb)
        }
        append(&out.parts, comp)
        out.spec += compound_spec(comp)
        out.specificity = specificity_add(out.specificity, comp.specificity)
        next_comb = .Descendant
        pending = false
    }

    if len(out.parts) == 0 do return {}, false
    return out, true
}

// Pseudo-elementos que não geram/estilizam uma caixa no nosso motor (fora
// ::before/::after). Regras que os miram não devem afetar o elemento hospedeiro.
@(private)
is_ignored_pseudo_element :: proc(name: string) -> bool {
    switch strings.to_lower(name, context.temp_allocator) {
    case "selection", "first-line",
         "marker", "backdrop", "file-selector-button", "cue", "cue-region",
         "spelling-error", "grammar-error", "target-text", "highlight":
        return true
    }
    lo := strings.to_lower(name, context.temp_allocator) // vendor: ::-webkit-*/-moz-*/-ms-*
    return strings.has_prefix(lo, "-webkit-") || strings.has_prefix(lo, "-moz-") || strings.has_prefix(lo, "-ms-")
}

// Remove escapes CSS de um identificador de classe: `\x` → `x`. O Tailwind v4
// escapa `:` `/` `.` `[` `]` `%` em classes utilitárias (`lg\:grid-cols-4`,
// `bg-white\/10`, `hover\:scale-\[1\.03\]`) porque o `class=""` no HTML tem os
// caracteres LITERAIS (`lg:grid-cols-4`). Guardamos a forma desescapada para
// casar com a classe do DOM e para a chave do índice by_class. Devolve string
// OWNED (clonada, mesmo sem escape) — liberada em free_compound.
@(private)
css_unescape :: proc(s: string) -> string {
    if strings.index_byte(s, '\\') < 0 do return strings.clone(s)
    sb := strings.builder_make()
    i := 0
    for i < len(s) {
        if s[i] == '\\' {
            i += 1
            if i >= len(s) do break
        }
        strings.write_byte(&sb, s[i])
        i += 1
    }
    return strings.to_string(sb)
}

// Parseia um composto simples (tag.classe#id), ignorando pseudo-classes.
@(private)
parse_compound :: proc(key: string) -> (Compound, bool) {
    out: Compound
    i := 0
    n := len(key)
    tag_start := i
    for i < n && key[i] != '.' && key[i] != '#' && key[i] != ':' && key[i] != '[' do i += 1
    // OWNED (ver nota de posse em free_compound): antes era fatia do `src` temp.
    if i > tag_start do out.tag = strings.clone(key[tag_start:i])
    if out.tag != "" && out.tag != "*" do out.specificity[2] += 1

    pseudo := "" // nome do 1º pseudo solto (sem tag/classe/id antes)
    for i < n {
        c := key[i]
        if c == '.' || c == '#' {
            i += 1
            name_start := i
            for i < n {
                if key[i] == '\\' { i += 2; continue } // escape CSS: `\x` faz parte do nome
                if key[i] == '.' || key[i] == '#' || key[i] == ':' || key[i] == '[' do break
                i += 1
            }
            if i > n do i = n // um `\` no fim pode ter passado de n
            name := key[name_start:i]
            // classe: guarda DESESCAPADA (owned) p/ casar com a classe literal do
            // DOM e virar chave do índice; `lg\:grid-cols-4` → `lg:grid-cols-4`.
            if c == '.' {
                append(&out.classes, css_unescape(name))
                out.specificity[1] += 1
            } else {
                out.specificity[0] += 1
                // Um elemento não pode ter dois IDs distintos. Repetir o mesmo
                // ID é válido e cada ocorrência contribui especificidade.
                if out.id != "" && out.id != name do out.never = true
                delete(out.id)
                out.id = strings.clone(name)
            }
        } else if c == '[' {
            i += 1
            close := i
            for close < n && key[close] != ']' do close += 1
            before := len(out.attrs)
            parse_attr_sel(key[i:close], &out)
            out.specificity[1] += len(out.attrs) - before
            i = close < n ? close + 1 : n
        } else if c == ':' {
            p := i
            for p < n && key[p] == ':' do p += 1 // pula ':' ou '::'
            double_colon := p - i >= 2
            ns := p
            for p < n && key[p] != '.' && key[p] != '#' && key[p] != ':' && key[p] != '(' && key[p] != '[' do p += 1
            name := key[ns:p]
            arg := ""
            if p < n && key[p] == '(' { // argumento entre parênteses balanceados
                depth := 1
                q := p + 1
                for q < n && depth > 0 {
                    if key[q] == '(' do depth += 1
                    else if key[q] == ')' do depth -= 1
                    q += 1
                }
                arg = key[p + 1 : depth == 0 ? q - 1 : q]
                p = q
            }
            // Um único parse por argumento: matching e especificidade compartilham
            // o Selector. Leia a tupla ANTES de liberar argumentos não avaliáveis.
            is_not := strings.equal_fold(name, "not")
            is_has := strings.equal_fold(name, "has")
            is_where := strings.equal_fold(name, "where")
            is_or := is_where || strings.equal_fold(name, "is") ||
                     strings.equal_fold(name, "matches") || strings.equal_fold(name, "-webkit-any")
            if is_not || is_has || is_or {
                best: [3]int
                group: [dynamic]Selector
                group_ok := true
                keep_or := is_or && len(out.ors) == 0
                group_start := len(out.has)
                for part in split_commas_top(arg) {
                    pt := strings.trim_space(part)
                    lead := Combinator.Descendant
                    if is_has { lead, pt = split_leading_combinator(pt) }
                    if pt == "" do continue
                    sel, ok := parse_complex(pt)
                    if !ok { group_ok = false; continue }
                    if specificity_compare(sel.specificity, best) > 0 do best = sel.specificity
                    if is_has {
                        append(&out.has, Has_Arg{lead = lead, sel = sel})
                        continue
                    }
                    tgt := sel.parts[len(sel.parts) - 1]
                    safe := len(sel.parts) > 1 || tgt.tag != "" || tgt.id != "" ||
                            len(tgt.classes) > 0 || len(tgt.attrs) > 0 ||
                            tgt.nth_kind != .None || tgt.empty_req || tgt.never ||
                            tgt.ui_states != {} || len(tgt.nots) > 0 || tgt.dir_req != .None
                    if is_not && safe {
                        append(&out.nots, sel)
                    } else if keep_or && safe {
                        append(&group, sel)
                    } else {
                        free_selector(&sel)
                    }
                    // Não interrompa: args posteriores ainda disputam o máximo,
                    // inclusive quando o grupo inteiro será rejeitado no matching.
                    if !safe do group_ok = false
                }
                if !is_where {
                    out.specificity = specificity_add(out.specificity, best)
                    legacy := specificity_legacy(best)
                    if is_not do out.nots_spec += legacy
                    else if is_has do out.has_spec += legacy
                    else do out.ors_spec += legacy
                }
                if keep_or {
                    if group_ok && len(group) > 0 {
                        out.ors = group
                    } else {
                        out.is_unresolved = true
                        for &s in group do free_selector(&s)
                        delete(group)
                    }
                }
                if is_has {
                    if len(out.has) == group_start do out.never = true
                    else do out.has[len(out.has) - 1].group_end = true
                }
                i = p
                continue
            }
            if double_colon || strings.equal_fold(name, "before") ||
               strings.equal_fold(name, "after") || strings.equal_fold(name, "first-letter") ||
               strings.equal_fold(name, "first-line") {
                out.specificity[2] += 1
            } else {
                out.specificity[1] += 1
            }
            // pseudo-classe estrutural (:first-child/:nth-child…): registra e
            // segue parseando o composto (ex.: li:first-child:hover)
            if kind, a, b, ok := parse_structural(name, arg); ok {
                if out.nth_kind == .None {
                    out.nth_kind = kind; out.nth_a = a; out.nth_b = b
                }
                i = p
                continue
            }
            // `:nth-*()` cujo ARGUMENTO não parseia (inválido, ou o `An+B of S`
            // que não suportamos): casa NADA. Cair no balde de pseudo
            // desconhecida faria `li:nth-child(2n of .x)` valer p/ TODO <li>.
            if is_nth_family(name) {
                out.never = true
                i = p
                continue
            }
            // `:empty` — avaliado contra a ÁRVORE no motor de estilo.
            if strings.equal_fold(name, "empty") {
                out.empty_req = true
                i = p
                continue
            }
            // pseudo-classe de estado FALSA num render estático (:target, :invalid…)
            if pseudo_never_matches(name) {
                out.never = true
                i = p
                continue
            }
            // pseudo de estado de formulário (:checked/:disabled/…): flag avaliada
            // por atributo no matching; segue parseando (ex.: input:checked:focus)
            if st, ok := parse_ui_state(name); ok {
                out.ui_states += {st}
                i = p
                continue
            }
            // :dir(ltr)/:dir(rtl): direcionalidade (avaliada no motor de estilo).
            // Espaços em volta do argumento são ignorados (`:dir( ltr )`). Qualquer
            // outro argumento (`:dir(foopy)`, vazio, ou com vírgula) parseia mas casa
            // NADA (Never) — o elemento mantém a cor base (WPT dir-selector-002/003).
            if strings.equal_fold(name, "dir") {
                if out.dir_req == .None {
                    a := strings.trim_space(arg)
                    if      strings.equal_fold(a, "ltr") do out.dir_req = .Ltr
                    else if strings.equal_fold(a, "rtl") do out.dir_req = .Rtl
                    else                                 do out.dir_req = .Never
                }
                i = p
                continue
            }
            // demais pseudos: guarda o nome (o PRIMEIRO) e SEGUE lendo o composto.
            // ⚠️ antes isto fazia `break`, descartando tudo que viesse depois — e o
            // que vem depois costuma ser uma RESTRIÇÃO: `:root.disclosure-open`
            // virava `:root` puro, ou seja "a raiz SEMPRE". No astro.build isso
            // acendia o backdrop de modal (`position:fixed; inset:0; opacity:0`,
            // que só deve acender com a classe no <html>) e a página inteira saía
            // coberta de uma cor só. Parar aqui só é seguro p/ pseudo-ELEMENTO,
            // que encerra o composto por definição; p/ pseudo-CLASSE o composto
            // continua. Guardar o primeiro nome preserva a classificação atual
            // (::before/::after/estado) sem mudar quem vence.
            if pseudo == "" do pseudo = name
            i = p
            continue
        } else {
            i += 1
        }
    }

    // classifica o pseudo alvo (::before/::after/::first-letter geram/estilizam
    // caixas; resto = Other)
    if strings.equal_fold(pseudo, "before")            do out.pseudo = .Before
    else if strings.equal_fold(pseudo, "after")        do out.pseudo = .After
    else if strings.equal_fold(pseudo, "first-letter") do out.pseudo = .FirstLetter
    else if strings.equal_fold(pseudo, "placeholder")  do out.pseudo = .Placeholder
    else if pseudo != ""                               do out.pseudo = .Other

    // Pseudo-ELEMENTOS que não renderizamos (::placeholder/::selection/::-webkit-*)
    // NUNCA aplicam ao estilo do próprio elemento — casam NADA, mesmo com tag.
    // Sem isto, `input::placeholder{color:...}` mudaria a cor do <input> em si.
    // (::before/::after já saíram acima; pseudo-CLASSES não suportadas seguem Other.)
    if out.pseudo == .Other && is_ignored_pseudo_element(pseudo) {
        out.pseudo_only = true
    }

    // estados de interação: a regra só vale quando o elemento está no estado.
    // `focus-visible`/`focus-within` (prefixo "focus") também são estado de foco —
    // sem isto NÃO viravam estado e a regra (ex.: `a:focus-visible{outline:2px #36c}`
    // da Wikipedia) casava TODO `<a>` estaticamente → outline azul em toda âncora.
    plo := strings.to_lower(pseudo, context.temp_allocator)
    if      strings.equal_fold(pseudo, "hover")  do out.state = .Hover
    else if strings.has_prefix(plo, "focus")     do out.state = .Focus
    else if strings.equal_fold(pseudo, "active") do out.state = .Active

    // Compound "só pseudo" (sem tag/classe/id): NÃO pode casar com todos os
    // elementos. Sem isto, regras como `::placeholder{}` ou (fatal)
    // `::-webkit-datetime-edit{display:inline-flex}` do reset do Tailwind seriam
    // aplicadas à página inteira. `:root` é a exceção → casa o elemento raiz.
    // ::before/::after "soltos" continuam válidos (casam todo elemento, mas só
    // geram caixa se tiverem `content`).
    // `:root` = elemento raiz → vira a tag `html` SEMPRE, não só quando o composto
    // está vazio. Com a tradução presa ao caso vazio, `:root.dark`/`:root[data-tema]`
    // (o jeito padrão de tematizar hoje) perdia a raiz e degenerava num seletor
    // solto de classe/atributo. Só preenche se ninguém já pôs tag (`div:root` não
    // faz sentido, mas não é nosso papel reescrever).
    if strings.equal_fold(pseudo, "root") && out.tag == "" {
        out.tag = strings.clone("html") // clona o LITERAL: `tag` é uniformemente owned
    }

    if out.tag == "" && out.id == "" && len(out.classes) == 0 && len(out.attrs) == 0 {
        if out.state != .None {
            // `:hover`/`:focus`/`:active` soltos casam qualquer elemento naquele
            // estado — não são pseudo_only (o estado já restringe a aplicação).
        } else if out.pseudo == .Other {
            out.pseudo_only = true
        } else if out.is_unresolved && out.nth_kind == .None && len(out.nots) == 0 {
            // :is()/:where() com argumento não avaliável (ex.: seletor complexo) e
            // SEM nenhuma outra restrição no composto → casa NADA em vez da página
            // toda. Sem isto, `:where(.divide-y > :not(:last-child)){border-bottom…}`
            // do Tailwind aplicaria a borda a todo elemento. (Quando há tag/classe/
            // id/atributo, o bloco não roda e a restrição existente vale — o :is
            // continua tratado como permissivo naquele caso.)
            out.pseudo_only = true
        } else if out.pseudo == .None && out.nth_kind == .None && out.ui_states == {} && out.dir_req == .None &&
                  !out.empty_req && !out.never &&
                  len(out.ors) == 0 && len(out.nots) == 0 && len(out.has) == 0 && !out.is_unresolved {
            // REDE DE SEGURANÇA da classe "composto vazio casa tudo": chegamos aqui
            // com tag/classe/id/atributo vazios, sem pseudo-elemento (::before/::after
            // saem antes e DEVEM casar todo elemento), sem estado, sem estrutural
            // (:nth), sem :is/:where/:not/:has e sem is_unresolved — ou seja, NENHUMA
            // restrição de espécie alguma. Isso não é `*` (que tem tag="*"); é
            // artefato de parsing de CSS degenerado/minificado (`[]`, `:not(,)`, e o
            // `:is()` vazio do github). Casa NADA, jamais a página inteira. Fecha a
            // classe toda em vez de um caso por vez (ver test_seletores_degenerados).
            out.pseudo_only = true
        }
    }
    return out, true
}

// Parseia o interior de um seletor de atributo ("name", "name=v", "name^=v"…)
// e acrescenta ao composto. Valores podem vir com aspas; a flag de case
// (" i"/" s") é removida e ignorada (sempre case-sensitive). Nomes assumidos
// já em minúsculas (como o parser de HTML normaliza os atributos do DOM).
@(private)
parse_attr_sel :: proc(body: string, out: ^Compound) {
    s := strings.trim_space(body)
    if s == "" do return
    name := s
    val := ""
    op := Attr_Op.Exists
    scan: for j in 0 ..< len(s) {
        c := s[j]
        if c == '=' {
            name = s[:j]; val = s[j + 1:]; op = .Equals
            break
        }
        if j + 1 < len(s) && s[j + 1] == '=' {
            switch c {
            case '~': op = .Includes
            case '|': op = .Dash
            case '^': op = .Prefix
            case '$': op = .Suffix
            case '*': op = .Substr
            case: continue
            }
            name = s[:j]; val = s[j + 2:]
            break scan
        }
    }
    name = strings.trim_space(name)
    if name == "" do return
    val = strings.trim_space(val)
    // flag de case-sensitivity após o valor: "x" i / "x" s
    if len(val) >= 2 && is_space(val[len(val) - 2]) {
        switch val[len(val) - 1] {
        case 'i', 'I', 's', 'S': val = strings.trim_space(val[:len(val) - 2])
        }
    }
    val = strings.trim(val, "\"'")
    // OWNED (ver free_compound): antes eram fatias do `src` temp
    append(&out.attrs, Attr_Sel{strings.clone(name), op, strings.clone(val)})
}

// Reconhece uma pseudo-classe estrutural pelo nome (+ argumento An+B quando
// houver). ok=false para pseudos não estruturais (:hover, :not…).
@(private)
parse_structural :: proc(name, arg: string) -> (kind: Nth_Kind, a, b: int, ok: bool) {
    n := strings.to_lower(name, context.temp_allocator)
    switch n {
    case "first-child":   return .Child, 0, 1, true
    case "last-child":    return .Last_Child, 0, 1, true
    case "only-child":    return .Only, 0, 0, true
    case "first-of-type": return .Of_Type, 0, 1, true
    case "last-of-type":  return .Last_Of_Type, 0, 1, true
    case "only-of-type":  return .Only_Of_Type, 0, 0, true
    case "nth-child":        if a2, b2, k := parse_nth(arg); k do return .Child, a2, b2, true
    case "nth-last-child":   if a2, b2, k := parse_nth(arg); k do return .Last_Child, a2, b2, true
    case "nth-of-type":      if a2, b2, k := parse_nth(arg); k do return .Of_Type, a2, b2, true
    case "nth-last-of-type": if a2, b2, k := parse_nth(arg); k do return .Last_Of_Type, a2, b2, true
    }
    return .None, 0, 0, false
}

// O nome é de um `:nth-*()`? Serve p/ separar "não é estrutural" (`:hover`) de
// "é estrutural mas o ARGUMENTO não parseia" (`:nth-child(bogus)`,
// `:nth-child(2n of .x)`) — o 2º caso não pode virar "casa todo mundo".
@(private)
is_nth_family :: proc(name: string) -> bool {
    switch strings.to_lower(name, context.temp_allocator) {
    case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type": return true
    }
    return false
}

// Pseudo-classe de ESTADO que é FALSA num render estático — casa NADA em vez de
// casar TUDO (que era o comportamento do balde "pseudo desconhecida").
//
// ⚠️ O critério é "estaticamente falsa", não "não implementada". Ficam DE FORA
// de propósito, seguindo permissivas, as que são estaticamente VERDADEIRAS na
// maioria dos elementos — `:valid`, `:in-range`, `:defined`, `:link`,
// `:any-link`, `:placeholder-shown` (input vazio MOSTRA o placeholder),
// `:default`: marcá-las como "casa nada" apagaria estilo que o Chrome aplica.
@(private)
pseudo_never_matches :: proc(name: string) -> bool {
    switch strings.to_lower(name, context.temp_allocator) {
    // navegação por fragmento — nenhum elemento é alvo no 1º render
    case "target", "target-within":                                   return true
    // histórico de visita (e privacidade)
    case "visited":                                                   return true
    // validação de formulário: um formulário recém-carregado não foi tocado
    case "invalid", "user-invalid", "user-valid", "out-of-range":      return true
    case "indeterminate", "autofill", "-webkit-autofill":              return true
    // modos de janela/diálogo
    case "modal", "fullscreen", "-webkit-full-screen", "picture-in-picture",
         "popover-open", "active-view-transition":                     return true
    // estado de mídia (<video>/<audio>) e cues do WebVTT
    case "paused", "playing", "seeking", "buffering", "stalled",
         "muted", "volume-locked", "current", "past", "future":        return true
    }
    return false
}

// Pseudo de estado de formulário/UI (avaliado por atributo). ok=false p/ os que
// não reconhecemos.
@(private)
parse_ui_state :: proc(name: string) -> (UI_State, bool) {
    switch strings.to_lower(name, context.temp_allocator) {
    case "checked":    return .Checked, true
    case "disabled":   return .Disabled, true
    case "enabled":    return .Enabled, true
    case "required":   return .Required, true
    case "optional":   return .Optional, true
    case "read-only":  return .ReadOnly, true
    case "read-write": return .ReadWrite, true
    }
    return .Checked, false
}

// Parseia o argumento An+B de :nth-*(): "odd", "even", "5", "2n", "2n+1",
// "-n + 3"… (a sintaxe "An+B of S" não é suportada → ok=false).
@(private)
parse_nth :: proc(input: string) -> (a, b: int, ok: bool) {
    s := strings.to_lower(strings.trim_space(input), context.temp_allocator)
    if s == "odd"  do return 2, 1, true
    if s == "even" do return 2, 0, true
    ni := strings.index_byte(s, 'n')
    if ni < 0 { // só B
        v, k := strconv.parse_int(s, 10)
        if !k do return 0, 0, false
        return 0, v, true
    }
    switch strings.trim_space(s[:ni]) { // parte A
    case "", "+": a = 1
    case "-":     a = -1
    case:
        v, k := strconv.parse_int(strings.trim_space(s[:ni]), 10)
        if !k do return 0, 0, false
        a = v
    }
    bs := strings.trim_space(s[ni + 1:]) // parte B (pode ter espaços: "2n + 1")
    if bs == "" do return a, 0, true
    buf := make([dynamic]u8, context.temp_allocator)
    for i in 0 ..< len(bs) {
        if bs[i] != ' ' && bs[i] != '\t' do append(&buf, bs[i])
    }
    v, k := strconv.parse_int(string(buf[:]), 10)
    if !k do return 0, 0, false
    return a, v, true
}

// O índice (1-based) satisfaz An+B para algum k ≥ 0?
nth_matches :: proc(a, b, idx: int) -> bool {
    if a == 0 do return idx == b
    d := idx - b
    return d % a == 0 && d / a >= 0
}

@(private)
is_sel_boundary :: proc(ch: u8) -> bool {
    switch ch {
    case ' ', '\t', '\n', '\r', '\f', '>', '+', '~': return true
    }
    return false
}

// Separa o combinador líder de um seletor relativo (:has). ">"/"+"/"~" no
// início → o combinador correspondente + o resto; sem líder → Descendant.
@(private)
split_leading_combinator :: proc(s: string) -> (Combinator, string) {
    t := strings.trim_space(s)
    if len(t) == 0 do return .Descendant, ""
    switch t[0] {
    case '>': return .Child,    strings.trim_space(t[1:])
    case '+': return .Adjacent, strings.trim_space(t[1:])
    case '~': return .Sibling,  strings.trim_space(t[1:])
    }
    return .Descendant, t
}

// Tupla (IDs, classes/atributos/pseudo-classes, tipos/pseudo-elementos).
// Sem carry entre colunas: onze classes continuam perdendo para um ID.
specificity_add :: proc(a, b: [3]int) -> [3]int {
    return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}
}

specificity_compare :: proc(a, b: [3]int) -> int {
    for i in 0..<3 {
        if a[i] < b[i] do return -1
        if a[i] > b[i] do return 1
    }
    return 0
}

// Projeção histórica para sondas; NÃO usar para decidir a cascata.
specificity_legacy :: proc(s: [3]int) -> int {
    return 100 * s[0] + 10 * s[1] + s[2]
}

@(private)
compound_spec :: proc(c: Compound) -> int {
    return specificity_legacy(c.specificity)
}

// Parseia um bloco de declarações ("color:red; font-weight:bold").
// Também serve para o atributo style="" inline.
parse_decls :: proc(text: string, allocator := context.allocator) -> map[string]string {
    decls := make(map[string]string, allocator)
    // separa por ';' no nível superior — ';' dentro de url(...)/parênteses ou
    // aspas pertence ao valor (ex.: url(data:image/svg+xml;base64,…)).
    n := len(text)
    start := 0
    depth := 0
    quote: u8 = 0
    for i := 0; i < n; i += 1 {
        ch := text[i]
        if quote != 0 {
            if ch == quote do quote = 0
            continue
        }
        switch ch {
        case '"', '\'': quote = ch
        case '(':       depth += 1
        case ')':       if depth > 0 do depth -= 1
        case ';':       if depth == 0 { add_decl(&decls, text[start:i], allocator); start = i + 1 }
        }
    }
    add_decl(&decls, text[start:], allocator)
    return decls
}

// Índice do primeiro ':' no nível superior (fora de parênteses/aspas). O nome
// da propriedade nunca contém '(' ou aspas, então isto separa prop:valor sem
// confundir com o ':' de url(data:…)/url(http://…). -1 se não houver.
@(private)
top_level_colon :: proc(s: string) -> int {
    depth := 0
    quote: u8 = 0
    for i := 0; i < len(s); i += 1 {
        ch := s[i]
        if quote != 0 {
            if ch == quote do quote = 0
            continue
        }
        switch ch {
        case '"', '\'': quote = ch
        case '(':       depth += 1
        case ')':       if depth > 0 do depth -= 1
        case ':':       if depth == 0 do return i
        }
    }
    return -1
}

@(private)
add_decl :: proc(decls: ^map[string]string, part: string, allocator: mem.Allocator) {
    colon := top_level_colon(part)
    if colon < 0 do return
    raw_prop := strings.trim_space(part[:colon])
    // custom properties (--name) são case-sensitive; demais vão pra lower
    prop: string
    if strings.has_prefix(raw_prop, "--") {
        prop = strings.clone(raw_prop, allocator)
    } else {
        prop = strings.to_lower(raw_prop, allocator)
    }
    val := strings.clone(strings.trim_space(part[colon + 1:]), allocator)
    if prop == "" || val == "" {
        delete(prop, allocator); delete(val, allocator)
        return
    }
    // Declaração inválida é IGNORADA (mantém o valor anterior, conforme a
    // cascata do CSS). Validamos o caso comum: um background/-image que invoca
    // linear-gradient() mas cujo gradiente não parseia. Sem var() (não dá p/
    // validar antes de resolver a variável).
    if (prop == "background-image" || prop == "background") && !strings.contains(val, "var(") {
        lo := strings.to_lower(val, context.temp_allocator)
        if strings.contains(lo, "linear-gradient(") || strings.contains(lo, "radial-gradient(") ||
           strings.contains(lo, "conic-gradient(") {
            if _, gok := parse_gradient(val); !gok {
                delete(prop, allocator); delete(val, allocator)
                return
            }
        }
    }
    if g_value_valid != nil {
        body, _ := split_important(val)
        if !g_value_valid(prop, body) {
            delete(prop, allocator); delete(val, allocator)
            return
        }
    }
    if old, ok := decls[prop]; ok {
        _, old_important := split_important(old)
        _, new_important := split_important(val)
        if old_important && !new_important {
            delete(prop, allocator); delete(val, allocator)
            return
        }
        // CADEIA DE FALLBACK (`width: 100px; width: -webkit-fill-available`): o
        // autor escreve a mesma propriedade DUAS vezes justamente porque o
        // suporte varia — a última que o motor entende é a que deve valer. Antes
        // a segunda sobrescrevia SEMPRE, e como ela é a que nós não sabemos
        // aplicar, o elemento ficava SEM a propriedade: um valor que não
        // implementamos não só era ignorado, ele APAGAVA o fallback do autor.
        // Isto é o que a cascata do CSS faz com declaração inválida (ela nem
        // entra), e transforma cada gap do motor de "perde a melhoria" em
        // "quebra o layout".
        // ⚠️ O juiz mora no pacote UI (g_value_usable) — só ele conhece as
        // unidades e palavras-chave IMPLEMENTADAS; duplicá-las aqui seria a
        // armadilha das duas cópias divergindo.
        if g_value_usable != nil {
            body,     _ := split_important(val)
            old_body, _ := split_important(old)
            if !g_value_usable(prop, old_body, body) {
                delete(prop, allocator); delete(val, allocator)
                return
            }
        }
        delete(old, allocator)
        delete(prop, allocator) // já existe a chave; descarta a nova cópia
        decls[prop] = val
    } else {
        decls[prop] = val
    }
}

// Juiz OPCIONAL de "este valor faz alguma coisa neste motor?", instalado pelo
// dono do motor de estilo (pacote ui, ver value_usable). nil = aceita tudo, que
// é o comportamento histórico — o pacote css sozinho não sabe quais unidades e
// palavras-chave estão implementadas. Consultado SÓ para decidir um duplicado
// dentro do MESMO bloco de declarações (ver add_decl).
g_value_usable: proc(prop, old_val, new_val: string) -> bool = nil

// Syntax hook owned by the style engine, applied even to a first declaration.
g_value_valid: proc(prop, value: string) -> bool

// Separa o sufixo "!important" do valor ("red !important" → "red", true).
// Case-insensitive; aceita espaços em volta do '!' ("red ! important").
// O valor devolvido é um slice do original (sem alocação).
split_important :: proc(val: string) -> (out: string, important: bool) {
    v := strings.trim_right_space(val)
    if len(v) < len("!important") do return val, false
    tail := v[len(v) - len("important"):]
    if !strings.equal_fold(tail, "important") do return val, false
    body := strings.trim_right_space(v[:len(v) - len("important")])
    if len(body) == 0 || body[len(body) - 1] != '!' do return val, false
    return strings.trim_right_space(body[:len(body) - 1]), true
}

// ── Casamento de seletor ────────────────────────────────────────────────────

// Casa um composto simples contra os dados de um elemento.
compound_matches :: proc(c: Compound, tag: string, classes: []string, id: string, attrs: map[string]string = nil) -> bool {
    if c.pseudo_only do return false // ::before/::placeholder/etc. soltos casam com nada
    if c.never do return false // :target/:invalid/:nth-child(bogus)… (ver Compound.never)
    if c.tag != "" && c.tag != "*" && c.tag != tag do return false
    if c.id != "" && c.id != id do return false
    for need in c.classes {
        found := false
        for cl in classes {
            if cl == need { found = true; break }
        }
        if !found do return false
    }
    for a in c.attrs {
        got, present := attrs[a.name]
        if !present do return false
        switch a.op {
        case .Exists: // presença basta
        case .Equals: if got != a.val do return false
        case .Includes: // valor é uma das palavras (separadas por espaço)
            found := false
            for f in strings.fields(got, context.temp_allocator) {
                if f == a.val { found = true; break }
            }
            if !found do return false
        case .Dash: // exatamente v ou prefixo "v-" (ex.: lang="pt-BR")
            if got != a.val &&
               !(len(got) > len(a.val) && strings.has_prefix(got, a.val) && got[len(a.val)] == '-') {
                return false
            }
        case .Prefix: if a.val == "" || !strings.has_prefix(got, a.val) do return false
        case .Suffix: if a.val == "" || !strings.has_suffix(got, a.val) do return false
        case .Substr: if a.val == "" || !strings.contains(got, a.val)   do return false
        }
    }
    // pseudos de estado (:checked/:disabled/…) por presença/ausência de atributo
    if c.ui_states != {} {
        has :: proc(attrs: map[string]string, name: string) -> bool { _, ok := attrs[name]; return ok }
        if .Checked   in c.ui_states && !has(attrs, "checked")  do return false
        if .Disabled  in c.ui_states && !has(attrs, "disabled") do return false
        if .Enabled   in c.ui_states &&  has(attrs, "disabled") do return false
        if .Required  in c.ui_states && !has(attrs, "required") do return false
        if .Optional  in c.ui_states &&  has(attrs, "required") do return false
        if .ReadOnly  in c.ui_states && !has(attrs, "readonly") do return false
        if .ReadWrite in c.ui_states &&  has(attrs, "readonly") do return false
    }
    return true
}

// ── Cores ───────────────────────────────────────────────────────────────────

// Converte um valor de cor CSS em 0xAARRGGBB. ok=false quando não reconhece.
parse_color :: proc(value: string) -> (rgb: u32, ok: bool) {
    v := strings.trim_space(value)
    if v == "" do return 0, false

    // Nome de função CSS é CASE-INSENSITIVE (css-syntax §2). O despacho comparava
    // o valor CRU, então `RGB(255,0,0)`/`HSL(...)` — grafia de folha antiga e de
    // CSS escrito à mão — caía em named_color e a declaração morria. `light-dark`
    // já usava equal_fold; as outras nove não. Passamos a forma MINÚSCULA adiante:
    // é o que os parsers de dentro esperam (unidade de ângulo, `in <espaço>` do
    // color-mix), e cor não carrega dado sensível a caixa.
    lo := strings.to_lower(v, context.temp_allocator)
    if lo[0] == '#' do return parse_hex(lo[1:])
    if strings.has_prefix(lo, "light-dark") do return parse_light_dark(lo)
    if strings.has_prefix(lo, "color-mix") do return parse_color_mix(lo)
    if strings.has_prefix(lo, "hsl") do return parse_hsl(lo)
    if strings.has_prefix(lo, "rgb") do return parse_rgb(lo)
    if strings.has_prefix(lo, "oklch") do return parse_oklch(lo)
    if strings.has_prefix(lo, "oklab") do return parse_oklab(lo)
    if strings.has_prefix(lo, "lch") do return parse_lch(lo)
    if strings.has_prefix(lo, "lab") do return parse_lab(lo)
    if strings.has_prefix(lo, "color(") do return parse_color_function(lo)
    return named_color(lo)
}

// Esquema de cor em uso, p/ resolver `light-dark()`. O ui seta antes do passe
// de estilo (espelha o `prefers-color-scheme`).
// ⚠️ a spec manda usar o `color-scheme` USADO DO ELEMENTO; aproximamos pelo da
// página inteira — degradação anotada. Sem isto, `light-dark(...)` não era
// reconhecida e caía em named_color → cor inválida (o braço escuro/preto).
g_dark_scheme: bool = false

// light-dark(<claro>, <escuro>) — escolhe o braço conforme o esquema em uso.
@(private)
parse_light_dark :: proc(v: string) -> (u32, bool) {
    open := strings.index_byte(v, '(')
    if open < 0 do return 0, false
    depth := 0; close := -1
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close < 0 do return 0, false
    parts := split_commas_top(v[open + 1:close])
    if len(parts) < 2 do return 0, false
    return parse_color(strings.trim_space(parts[g_dark_scheme ? 1 : 0]))
}

// color-mix(in <espaço>, <cor1> [p1%], <cor2> [p2%]) — mistura duas cores. O
// espaço de interpolação (oklab/lab/srgb) é IGNORADO (aproximamos em sRGB); p/ o
// caso dominante (Tailwind v4 `cor N% + transparent` = cor com N% de alpha) o
// espaço não importa. Mistura em ALPHA PRÉ-MULTIPLICADO (correto p/ transparência).
@(private)
parse_color_mix :: proc(v: string) -> (u32, bool) {
    open := strings.index_byte(v, '(')
    if open < 0 do return 0, false
    depth := 0; close := -1
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close < 0 do return 0, false
    parts := split_commas_top(v[open + 1:close])
    if len(parts) < 3 do return 0, false // "in <espaço>", cor1, cor2

    rgb1, a1, p1, ok1 := mix_color_pct(parts[1])
    rgb2, a2, p2, ok2 := mix_color_pct(parts[2])
    if !ok1 || !ok2 do return 0, false

    // resolve as porcentagens (omitidas: 50/50 ou complemento da outra)
    if p1 < 0 && p2 < 0 { p1 = 0.5; p2 = 0.5 }
    else if p1 < 0 { p1 = max(0, 1 - p2) }
    else if p2 < 0 { p2 = max(0, 1 - p1) }
    s := p1 + p2
    if s <= 0.0001 do return 0x01000000, true // ambas 0% → transparente
    alpha_scale := min(s, 1) // soma < 100% escala o alpha do resultado (spec)
    p1 /= s; p2 /= s

    // mistura em ALPHA PRÉ-MULTIPLICADO (usa o alpha REAL de cada cor)
    w1 := p1 * a1; w2 := p2 * a2
    wsum := w1 + w2
    ch :: proc(c: u32, sh: u32) -> f32 { return f32((c >> sh) & 0xff) }
    rr, gg, bb: f32 = 0, 0, 0
    if wsum > 0.0001 {
        rr = (w1*ch(rgb1, 16) + w2*ch(rgb2, 16)) / wsum
        gg = (w1*ch(rgb1, 8)  + w2*ch(rgb2, 8))  / wsum
        bb = (w1*ch(rgb1, 0)  + w2*ch(rgb2, 0))  / wsum
    }
    ao := wsum * alpha_scale
    R := u32(clamp(rr + 0.5, 0, 255))
    G := u32(clamp(gg + 0.5, 0, 255))
    B := u32(clamp(bb + 0.5, 0, 255))
    ab := ao >= 0.999 ? u32(0) : u32(clamp(ao*255 + 0.5, 1, 255)) // byte alto: 0 = opaco
    return ab << 24 | R << 16 | G << 8 | B, true
}

// alpha de uma cor 0xAARRGGBB em 0..1 (byte alto 0 = opaco).
@(private)
mix_alpha :: proc(c: u32) -> f32 {
    a := (c >> 24) & 0xff
    return a == 0 ? 1.0 : f32(a) / 255.0
}

// "cor [p%]" de dentro do color-mix → (rgb 0x00RRGGBB, alpha 0..1, fração p ou -1, ok).
@(private)
mix_color_pct :: proc(part: string) -> (rgb: u32, alpha: f32, pct: f32, ok: bool) {
    f := fields_top(strings.trim_space(part))
    if len(f) == 0 do return 0, 0, -1, false
    pct = -1
    color_str := strings.trim_space(part)
    if len(f) >= 2 && strings.has_suffix(f[len(f) - 1], "%") {
        pct = num_prefix(f[len(f) - 1]) / 100
        color_str = strings.join(f[:len(f) - 1], " ", context.temp_allocator)
    }
    cs := strings.trim_space(color_str)
    // `transparent` não é cor válida em named_color (p/ background:transparent = sem
    // fundo); no color-mix é alpha ZERO exato (senão dilui a outra cor).
    if strings.equal_fold(cs, "transparent") do return 0, 0, pct, true
    c, k := parse_color(cs)
    if !k do return 0, 0, -1, false
    return c & 0x00ffffff, mix_alpha(c), pct, true
}

// Extrai o caminho de url(...) (com ou sem aspas). "" se não houver.
extract_url :: proc(value: string) -> string {
    idx := strings.index(value, "url(")
    if idx < 0 do return ""
    start := idx + 4
    rest := value[start:]
    end := strings.index_byte(rest, ')')
    if end < 0 do return ""
    inner := strings.trim_space(rest[:end])
    return strings.trim(inner, "\"'")
}

// ── Gradientes ──────────────────────────────────────────────────────────────

GRAD_MAX_STOPS :: 8
Gradient_Dir :: enum u8 { Right, Left, Top, Bottom }

Gradient :: struct {
    active:    bool,
    radial:    bool,              // radial-gradient (elipse centrada); dir/angle ignorados
    conic:     bool,              // conic-gradient (varia por ÂNGULO ao redor do centro)
    diagonal:  bool,              // linear com ângulo NÃO axial → tesselar (senão usa dir)
    repeating: bool,             // repeating-*-gradient: o padrão [pos[0],pos[n-1]] se repete
    angle:    f32,                // linear: ângulo CSS (0=to top…); conic: 'from' em graus
    dir:      Gradient_Dir,       // eixo p/ o caminho rápido (só quando !diagonal)
    n:        int,
    cols:     [GRAD_MAX_STOPS]u32,
    pos:      [GRAD_MAX_STOPS]f32,  // linear/radial: 0..1 do eixo; conic: fração do giro (0..1);
                                    // se pos_px[i], guarda o valor em PX (resolvido no paint)
    pos_set:  [GRAD_MAX_STOPS]bool,
    pos_px:   [GRAD_MAX_STOPS]bool, // stop com posição em px → dividir pela linha do gradiente
    // color interpolation hint do SEGMENTO [i,i+1]: desloca onde a mistura A→B
    // chega a 50% (curva de potência per css-images-4). hint_pos = fração/turn,
    // ou VALOR px se hint_px (resolvido no paint como os stops).
    hint_pos: [GRAD_MAX_STOPS]f32,
    hint_set: [GRAD_MAX_STOPS]bool,
    hint_px:  [GRAD_MAX_STOPS]bool,

    // radial-gradient: prelúdio `[<shape> || <size>] [at <position>]`. Todo o
    // zero-value é o DEFAULT do CSS (elipse, farthest-corner, centro 50% 50%),
    // então gradiente sem prelúdio — e qualquer Gradient zerado — segue igual.
    r_size:    Radial_Size,
    r_circle:  bool,
    r_pos_set: bool, // false = centro 50% 50% (não dá p/ usar r_cx=0.5 como zero)
    r_rx_pct, r_ry_pct: bool, // raio explícito em % do lado (senão px)
    r_cx_pct, r_cy_pct: bool, // centro em % do lado (senão px a partir da borda)
    r_rx, r_ry: f32,
    r_cx, r_cy: f32,
}

// Tamanho da elipse final do radial-gradient (css-images-3 §3.3). O zero-value
// é o default da spec.
Radial_Size :: enum u8 {
    Farthest_Corner,
    Closest_Side,
    Closest_Corner,
    Farthest_Side,
    Explicit, // raios dados em px/% (1 valor = círculo, 2 = elipse)
}

// linear-gradient(...) — direção por palavra-chave (to right/left/top/bottom e
// cantos) ou Ndeg, ambos mapeados ao eixo dominante (diagonais aproximadas), e
// N color-stops "cor [pos%]". Precisa de ≥2 cores.
// Também radial-gradient(...) — o prelúdio (shape/size/'at …') é reconhecido e
// descartado; renderizamos como elipse centrada com os mesmos color-stops.
parse_gradient :: proc(value: string) -> (g: Gradient, ok: bool) {
    v  := strings.trim_space(value)
    lo := strings.to_lower(v, context.temp_allocator)

    // radial-gradient e conic-gradient têm prelúdio próprio; despacham.
    if strings.index(lo, "radial-gradient(") >= 0 {
        return parse_radial_gradient(v, lo)
    }
    if strings.index(lo, "conic-gradient(") >= 0 {
        return parse_conic_gradient(v, lo)
    }

    g.repeating = strings.contains(lo, "repeating-")

    idx := strings.index(lo, "linear-gradient(")
    if idx < 0 do return g, false
    open := idx + len("linear-gradient(") - 1

    depth := 0; close := -1 // acha o ')' que casa
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close < 0 do return g, false

    parts := split_commas_top(v[open + 1:close])
    if len(parts) < 2 do return g, false

    g.angle = 180 // padrão CSS: to bottom
    start := 0
    first := strings.to_lower(strings.trim_space(parts[0]), context.temp_allocator)
    if strings.has_prefix(first, "to ") {
        g.angle = angle_from_keywords(first[3:])
        start = 1
    } else if deg, ok := angle_to_deg(first); ok {
        g.angle = deg
        start = 1
    } else if _, _, _, _, k := parse_color_stop(parts[0]); !k {
        // O 1º argumento não é "to …", nem um ângulo válido, nem uma cor
        // válida: é um ângulo/unidade malformado (ex.: "0.25turns", "90degree",
        // "100gradian"), então o gradiente INTEIRO é inválido. (Sem isto, o
        // token era silenciosamente ignorado e sobrava um gradiente enganoso.)
        return g, false
    }
    // normaliza p/ [0,360); classifica axial (caminho rápido) vs diagonal.
    a := g.angle
    for a < 0    do a += 360
    for a >= 360 do a -= 360
    g.angle = a
    g.dir = dir_from_angle(a)
    EPS :: f32(0.5)
    axial := abs(a) < EPS || abs(a - 90) < EPS || abs(a - 180) < EPS || abs(a - 270) < EPS
    g.diagonal = !axial

    for i in start ..< len(parts) {
        if g.n >= GRAD_MAX_STOPS do break
        append_grad_part(&g, parts[i])
    }
    if g.n < 2 do return g, false
    g.active = true
    return g, true
}

// radial-gradient([<shape/size> | at <pos>]?, cor [pos%], …). O prelúdio (1º
// argumento) é descartado quando descreve a forma/posição — reconhecido pelas
// keywords circle/ellipse/closest-*/farthest-*/'at' ou por conter unidade sem
// ser cor. Renderizamos sempre como elipse centrada (aprox). Precisa de ≥2 cores.
@(private)
parse_radial_gradient :: proc(v, lo: string) -> (g: Gradient, ok: bool) {
    idx := strings.index(lo, "radial-gradient(")
    open := idx + len("radial-gradient(") - 1
    depth := 0; close := -1
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close < 0 do return g, false
    parts := split_commas_top(v[open + 1:close])
    if len(parts) < 1 do return g, false

    g.radial = true
    g.repeating = strings.contains(lo, "repeating-")
    start := 0
    // o 1º argumento é prelúdio (forma/tamanho/posição) se NÃO for uma cor válida
    first := strings.to_lower(strings.trim_space(parts[0]), context.temp_allocator)
    if _, _, _, _, k := parse_color_stop(parts[0]); !k {
        // não é cor → só aceita como prelúdio se parecer um (senão inválido)
        looks_prelude := strings.contains(first, "circle") || strings.contains(first, "ellipse") ||
            strings.contains(first, "closest") || strings.contains(first, "farthest") ||
            strings.has_prefix(first, "at ") || strings.contains(first, "%") ||
            strings.contains(first, "px") || strings.contains(first, "em")
        if !looks_prelude do return g, false
        parse_radial_prelude(&g, first)
        start = 1
    }

    for i in start ..< len(parts) {
        if g.n >= GRAD_MAX_STOPS do break
        append_grad_part(&g, parts[i])
    }
    if g.n < 2 do return g, false
    g.active = true
    return g, true
}

// Prelúdio do radial-gradient: `[<shape> || <size>] [at <position>]`, já em
// minúsculas. Tokens antes do `at` descrevem forma/tamanho; depois, o centro.
// Token não reconhecido é IGNORADO (o gradiente continua válido com o default,
// como o resto do parser faz) — a spec o invalidaria, mas cair no default é a
// degradação honesta aqui: melhor uma elipse centrada do que fundo nenhum.
@(private)
parse_radial_prelude :: proc(g: ^Gradient, first: string) {
    toks := fields_top(first)
    at := -1
    for t, i in toks do if t == "at" { at = i; break }
    shape := toks[:at >= 0 ? at : len(toks)]
    center := at >= 0 ? toks[at + 1:] : nil

    // forma/tamanho. Raios explícitos: 1 token = círculo, 2 = elipse (rx ry).
    radii := 0
    for t in shape {
        switch t {
        case "circle":          g.r_circle = true
        case "ellipse":         g.r_circle = false
        case "closest-side":    g.r_size = .Closest_Side
        case "closest-corner":  g.r_size = .Closest_Corner
        case "farthest-side":   g.r_size = .Farthest_Side
        case "farthest-corner": g.r_size = .Farthest_Corner
        case:
            if !grad_is_pos_token(t) do continue
            v, is_px := grad_pos_value(t)
            switch radii {
            case 0: g.r_rx = v; g.r_rx_pct = !is_px; g.r_ry = v; g.r_ry_pct = !is_px
            case 1: g.r_ry = v; g.r_ry_pct = !is_px
            case:   continue // >2 valores: ignora o excedente
            }
            radii += 1
            g.r_size = .Explicit
        }
    }
    // `circle 40px` dá UM raio (os dois eixos iguais, já feito no case 0);
    // `ellipse 80% 50%` dá dois.

    if len(center) > 0 {
        cx, cy, cx_pct, cy_pct, ok := parse_position_2(center)
        if ok {
            g.r_cx, g.r_cy = cx, cy
            g.r_cx_pct, g.r_cy_pct = cx_pct, cy_pct
            g.r_pos_set = true
        }
    }
}

// `<position>` de 1 ou 2 valores (keywords left/center/right/top/bottom ou
// px/%). Devolve (x, y, x_é_pct, y_é_pct, ok). Keywords viram fração; a ordem
// invertida (`top left`) é aceita porque cada keyword só cabe num eixo.
@(private)
parse_position_2 :: proc(toks: []string) -> (x, y: f32, x_pct, y_pct, ok: bool) {
    x, y = 0.5, 0.5
    x_pct, y_pct = true, true
    got_x, got_y := false, false
    for t in toks {
        switch t {
        case "left":   x = 0;   x_pct = true; got_x = true
        case "right":  x = 1;   x_pct = true; got_x = true
        case "top":    y = 0;   y_pct = true; got_y = true
        case "bottom": y = 1;   y_pct = true; got_y = true
        case "center": // preenche o eixo que ainda falta (ou o x, se ambos livres)
            if got_x && !got_y { y = 0.5; y_pct = true; got_y = true }
            else               { x = 0.5; x_pct = true; got_x = true }
        case:
            if !grad_is_pos_token(t) do return 0, 0, false, false, false
            v, is_px := grad_pos_value(t)
            if !got_x { x = v; x_pct = !is_px; got_x = true }
            else      { y = v; y_pct = !is_px; got_y = true }
        }
    }
    return x, y, x_pct, y_pct, got_x || got_y
}

// conic-gradient([from <angle>]? [at <pos>]?, cor [<angle>|<%>]?, …). O prelúdio
// ('from …'/'at …') é reconhecido e descartado (só guardamos o from-angle); os
// stops são angulares (deg/grad/rad/turn ou %, fração do giro completo). Renderiza
// variando a cor pelo ângulo ao redor do centro. Precisa de ≥2 cores.
@(private)
parse_conic_gradient :: proc(v, lo: string) -> (g: Gradient, ok: bool) {
    idx := strings.index(lo, "conic-gradient(")
    open := idx + len("conic-gradient(") - 1
    depth := 0; close := -1
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close < 0 do return g, false
    parts := split_commas_top(v[open + 1:close])
    if len(parts) < 1 do return g, false

    g.conic = true
    g.repeating = strings.contains(lo, "repeating-")
    start := 0
    first := strings.to_lower(strings.trim_space(parts[0]), context.temp_allocator)
    // prelúdio: começa com 'from' ou 'at' (não é color-stop). Tokeniza c/ fields_top
    // (respeita parênteses) p/ o ângulo do 'from' poder ser um calc(...) com espaços
    // internos. O 'at <pos>' do centro é reconhecido e DESCARTADO (centro sempre no meio).
    if strings.has_prefix(first, "from") || strings.has_prefix(first, "at ") {
        toks := fields_top(first)
        for i in 0 ..< len(toks) {
            if toks[i] == "from" && i + 1 < len(toks) {
                if deg, dok := angle_to_deg(toks[i + 1]); dok do g.angle = deg
                break
            }
        }
        start = 1
    }

    for i in start ..< len(parts) {
        if g.n >= GRAD_MAX_STOPS do break
        // "cor", "cor <ângulo|%>" ou "cor <p1> <p2>" (dupla posição = hard-stop:
        // emite DOIS stops da mesma cor). Conta os tokens angulares/% no fim.
        f := fields_top(strings.trim_space(parts[i]))
        if len(f) == 0 do continue
        // color hint = uma posição angular SOLITÁRIA (sem cor) entre dois stops
        if g.n >= 1 && len(f) == 1 {
            if hv, ok := conic_pos(f[0]); ok {
                g.hint_pos[g.n - 1] = hv; g.hint_set[g.n - 1] = true; g.hint_px[g.n - 1] = false
                continue
            }
        }
        pcount := 0
        for j := len(f) - 1; j >= 1; j -= 1 {
            if _, ok := conic_pos(f[j]); ok do pcount += 1
            else do break
        }
        color_str := pcount > 0 ? strings.join(f[:len(f) - pcount], " ", context.temp_allocator) : parts[i]
        c, k := parse_color(strings.trim_space(color_str))
        if !k do continue
        if pcount == 0 {
            g.cols[g.n] = c; g.pos[g.n] = 0; g.pos_set[g.n] = false; g.n += 1
        } else {
            for j in len(f) - pcount ..< len(f) {
                if g.n >= GRAD_MAX_STOPS do break
                p, _ := conic_pos(f[j])
                g.cols[g.n] = c; g.pos[g.n] = p; g.pos_set[g.n] = true; g.n += 1
            }
        }
    }
    if g.n < 2 do return g, false
    g.active = true
    return g, true
}

// Token de posição de conic → fração do giro (0..1). Aceita %, deg/grad/rad/turn
// e calc() misturando ângulo e % (ex.: calc(90deg + 25%) = 0.5 do giro).
@(private)
conic_pos :: proc(tok: string) -> (f32, bool) {
    lo := strings.to_lower(strings.trim_space(tok), context.temp_allocator)
    if lo == "0" do return 0, true // zero sem unidade = 0deg (válido p/ <angle>)
    if strings.has_prefix(lo, "calc(") && strings.has_suffix(lo, ")") {
        return eval_calc_turn(lo[5:len(lo) - 1])
    }
    if strings.has_suffix(lo, "%") do return num_prefix(lo) / 100, true
    if deg, ok := angle_to_deg(lo); ok do return deg / 360, true
    return 0, false
}

// "to <lado>"/"to <canto>" → ângulo CSS em graus (0=to top, 90=to right,
// 180=to bottom, 270=to left). Cantos são aproximados como 45° (independente da
// razão do box — a exatidão do canto dependeria de W/H, desconhecidos no parse).
@(private)
angle_from_keywords :: proc(kw: string) -> f32 {
    s := strings.trim_space(kw)
    has :: proc(s, sub: string) -> bool { return strings.contains(s, sub) }
    top, bot := has(s, "top"), has(s, "bottom")
    lft, rgt := has(s, "left"), has(s, "right")
    if top && rgt do return 45
    if bot && rgt do return 135
    if bot && lft do return 225
    if top && lft do return 315
    if top do return 0
    if rgt do return 90
    if bot do return 180
    if lft do return 270
    return 180
}

// Converte um token de ângulo CSS (já minúsculo) em graus. Suporta deg/grad/
// rad/turn e calc() (ângulo/%, ex.: `calc(180deg + 0.25turn)`). Devolve ok=false
// se não termina numa unidade de ângulo VÁLIDA — o que rejeita corretamente
// unidades malformadas ("0.25turns", "90degree", "100gradian"). ATENÇÃO à ordem:
// "grad" termina em "rad", então checa antes.
@(private)
angle_to_deg :: proc(s: string) -> (f32, bool) {
    if strings.has_prefix(s, "calc(") && strings.has_suffix(s, ")") {
        if turn, ok := eval_calc_turn(s[5:len(s) - 1]); ok do return turn * 360, true
        return 0, false
    }
    switch {
    case strings.has_suffix(s, "grad"): return num_prefix(s) * 0.9, true          // 400grad = 360deg
    case strings.has_suffix(s, "turn"): return num_prefix(s) * 360, true          // 1turn = 360deg
    case strings.has_suffix(s, "deg"):  return num_prefix(s), true
    case strings.has_suffix(s, "rad"):  return num_prefix(s) * (180 / math.PI), true
    }
    return 0, false
}

// Ângulo CSS (0=to top, 90=to right, 180=to bottom, 270=to left) → eixo mais próximo.
@(private)
dir_from_angle :: proc(deg: f32) -> Gradient_Dir {
    a := deg
    for a < 0    do a += 360
    for a >= 360 do a -= 360
    switch {
    case a >= 315 || a < 45: return .Top
    case a < 135:            return .Right
    case a < 225:            return .Bottom
    case:                    return .Left
    }
}

// Um token é uma posição de color-stop: N%, Npx, ou "0" (comprimento sem unidade
// só é válido no zero; aceito por Chrome).
@(private)
grad_is_pos_token :: proc(s: string) -> bool {
    return strings.has_suffix(s, "%") || strings.has_suffix(s, "px") || s == "0"
}

// Valor de um token de posição → (valor, é_px). % vira fração 0..1; px/"0" fica
// como VALOR em px (resolvido contra a linha do gradiente no paint).
@(private)
grad_pos_value :: proc(s: string) -> (f32, bool) {
    if strings.has_suffix(s, "%") do return num_prefix(s) / 100, false
    return num_prefix(s), true
}

// Extrai a cor de um segmento de color-stop ("cor [pos] [pos]"), descartando até
// 2 tokens de posição no fim. Devolve (cor, nº de posições, ok). `transparent` é
// um stop VÁLIDO (preto α≈0, 0x01000000) — é EXCLUÍDO de named_color de propósito
// (p/ background:transparent=sem cor), mas em gradiente/máscara é onipresente (fades).
@(private)
grad_stop_color :: proc(f: []string) -> (col: u32, npos: int, ok: bool) {
    if len(f) == 0 do return 0, 0, false
    np := 0
    for np < 2 && len(f) - 1 - np >= 1 && grad_is_pos_token(f[len(f) - 1 - np]) do np += 1
    if len(f) - np < 1 do return 0, 0, false
    color_str := strings.join(f[:len(f) - np], " ", context.temp_allocator)
    if strings.equal_fold(strings.trim_space(color_str), "transparent") {
        return 0x01000000, np, true
    }
    c, k := parse_color(color_str)
    if !k do return 0, 0, false
    return c, np, true
}

// Valida/lê um color-stop (uma posição). Usado só p/ decidir prelúdio vs. cor —
// a EMISSÃO de stops (incl. dupla posição = hard-stop) passa por append_grad_stop.
@(private)
parse_color_stop :: proc(part: string) -> (u32, f32, bool, bool, bool) {
    f := fields_top(strings.trim_space(part))
    c, np, ok := grad_stop_color(f)
    if !ok do return 0, 0, false, false, false
    if np >= 1 {
        v, is_px := grad_pos_value(f[len(f) - np])
        return c, v, true, is_px, true
    }
    return c, 0, false, false, true
}

// Acrescenta ao gradiente 1 ou 2 stops de um segmento "cor [pos] [pos]". Duas
// posições = hard-stop (a MESMA cor em ambas — sintaxe canônica das faixas em
// repeating-*-gradient, ex.: "#333 0 12px"). Ignora o segmento se a cor for inválida.
@(private)
append_grad_stop :: proc(g: ^Gradient, part: string) {
    f := fields_top(strings.trim_space(part))
    c, np, ok := grad_stop_color(f)
    if !ok do return
    if np == 0 {
        if g.n < GRAD_MAX_STOPS {
            g.cols[g.n] = c; g.pos[g.n] = 0; g.pos_set[g.n] = false; g.pos_px[g.n] = false; g.n += 1
        }
        return
    }
    for j in len(f) - np ..< len(f) {
        if g.n >= GRAD_MAX_STOPS do break
        v, is_px := grad_pos_value(f[j])
        g.cols[g.n] = c; g.pos[g.n] = v; g.pos_set[g.n] = true; g.pos_px[g.n] = is_px; g.n += 1
    }
}

// Um color hint (linear/radial) = uma posição de comprimento SOLITÁRIA (%, px ou
// "0"), sem cor. Devolve (valor, é_px, ok). ok=false se não for exatamente 1 token
// de posição (então é um color-stop normal, tratado por append_grad_stop).
@(private)
parse_len_hint :: proc(part: string) -> (f32, bool, bool) {
    f := fields_top(strings.trim_space(part))
    if len(f) != 1 do return 0, false, false
    if !grad_is_pos_token(f[0]) do return 0, false, false
    v, is_px := grad_pos_value(f[0])
    return v, is_px, true
}

// Processa um argumento de color-stop-list (linear/radial): se for um color hint
// (posição solitária entre dois stops) registra-o no segmento do stop anterior;
// senão emite o(s) stop(s). Um hint no início (sem stop antes) é ignorado.
@(private)
append_grad_part :: proc(g: ^Gradient, part: string) {
    if g.n >= 1 {
        if hv, hpx, ok := parse_len_hint(part); ok {
            g.hint_pos[g.n - 1] = hv; g.hint_px[g.n - 1] = hpx; g.hint_set[g.n - 1] = true
            return
        }
    }
    append_grad_stop(g, part)
}

// Split por ',' no nível superior (ignora vírgulas dentro de parênteses).
@(private)
split_commas_top :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',': if depth == 0 { append(&out, s[start:i]); start = i + 1 }
        }
    }
    append(&out, s[start:])
    return out[:]
}

// Split por espaços no nível superior (mantém rgb( … ) como um token só).
@(private)
fields_top :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, -1
    for i in 0 ..< len(s) {
        ch := s[i]
        if      ch == '(' do depth += 1
        else if ch == ')' do depth -= 1
        sep := depth == 0 && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        if sep {
            if start >= 0 { append(&out, s[start:i]); start = -1 }
        } else if start < 0 {
            start = i
        }
    }
    if start >= 0 do append(&out, s[start:])
    return out[:]
}

// hsl()/hsla() → 0xAARRGGBB (alpha no byte alto; 0 = opaco).
@(private)
parse_hsl :: proc(v: string) -> (u32, bool) {
    open := strings.index_byte(v, '(')
    close := strings.index_byte(v, ')')
    if open < 0 || close < 0 || close < open do return 0, false
    // normaliza separadores (vírgula e barra de alpha) em espaços
    inner := v[open + 1:close]
    buf := make([dynamic]u8, context.temp_allocator)
    for i in 0 ..< len(inner) {
        c := inner[i]
        if c == ',' || c == '/' do c = ' '
        append(&buf, c)
    }
    toks := strings.fields(string(buf[:]), context.temp_allocator)
    if len(toks) < 3 do return 0, false
    // matiz aceita <angle> (deg/grad/rad/turn) além de <number> em graus
    h: f32 = num_prefix(toks[0])
    if deg, ok := angle_to_deg(strings.to_lower(toks[0], context.temp_allocator)); ok do h = deg
    s := num_prefix(toks[1]) / 100
    l := num_prefix(toks[2]) / 100
    rgb := hsl_to_rgb(h, clamp(s, 0, 1), clamp(l, 0, 1))
    if len(toks) >= 4 do rgb |= parse_alpha(toks[3]) << 24
    return rgb, true
}

// Token de alpha CSS (0..1 ou 0%..100%) → byte 1..255. Nunca 0: o byte alto
// zero é reservado para "opaco" (retrocompat com cores 0xRRGGBB).
@(private)
parse_alpha :: proc(tok: string) -> u32 {
    a := num_prefix(tok)
    if strings.has_suffix(tok, "%") do a /= 100
    v := u32(clamp(a * 255 + 0.5, 0, 255))
    return v < 1 ? 1 : v
}

// Canal r/g/b de rgb(): inteiro 0..255 ou porcentagem.
@(private)
channel :: proc(tok: string) -> u32 {
    a := num_prefix(tok)
    if strings.has_suffix(tok, "%") do a = a / 100 * 255
    return u32(clamp(a + 0.5, 0, 255))
}

@(private)
num_prefix :: proc(s: string) -> f32 {
    end := 0
    for end < len(s) {
        c := s[end]
        if c == '.' || c == '-' || c == '+' || (c >= '0' && c <= '9') { end += 1; continue }
        // expoente científico (1.2e2): só consome 'e'/'E' se vier dígito ou sinal
        // logo após — assim NÃO come o 'e' de unidades como "3em".
        if (c == 'e' || c == 'E') && end + 1 < len(s) {
            nx := s[end + 1]
            if nx == '+' || nx == '-' || (nx >= '0' && nx <= '9') { end += 1; continue }
        }
        break
    }
    if end == 0 do return 0
    n, _ := strconv.parse_f64(s[:end])
    return f32(n)
}

@(private)
hsl_to_rgb :: proc(h_in, s, l: f32) -> u32 {
    h := h_in
    for h < 0    do h += 360
    for h >= 360 do h -= 360
    c := (1 - abs(2 * l - 1)) * s
    seg := h / 60
    k := seg - 2 * f32(int(seg / 2)) // seg mod 2
    x := c * (1 - abs(k - 1))
    m := l - c / 2
    r, g, b: f32
    switch {
    case h < 60:  r, g, b = c, x, 0
    case h < 120: r, g, b = x, c, 0
    case h < 180: r, g, b = 0, c, x
    case h < 240: r, g, b = 0, x, c
    case h < 300: r, g, b = x, 0, c
    case:         r, g, b = c, 0, x
    }
    R := u32(clamp((r + m) * 255 + 0.5, 0, 255)) // +0.5 = arredonda
    G := u32(clamp((g + m) * 255 + 0.5, 0, 255))
    B := u32(clamp((b + m) * 255 + 0.5, 0, 255))
    return R << 16 | G << 8 | B
}

@(private)
parse_hex :: proc(h: string) -> (u32, bool) {
    hex :: proc(c: u8) -> (int, bool) {
        switch {
        case c >= '0' && c <= '9': return int(c - '0'), true
        case c >= 'a' && c <= 'f': return int(c - 'a') + 10, true
        case c >= 'A' && c <= 'F': return int(c - 'A') + 10, true
        }
        return 0, false
    }
    r, g, b: int
    alpha := 0 // 0 = opaco (byte alto reservado)
    switch len(h) {
    case 3, 4: // #rgb / #rgba
        a0, o0 := hex(h[0]); a1, o1 := hex(h[1]); a2, o2 := hex(h[2])
        if !(o0 && o1 && o2) do return 0, false
        r = a0*16 + a0; g = a1*16 + a1; b = a2*16 + a2
        if len(h) == 4 {
            if a3, o3 := hex(h[3]); o3 {
                alpha = a3*16 + a3
                if alpha == 0 do alpha = 1
            }
        }
    case 6, 8: // #rrggbb / #rrggbbaa
        vals: [3]int
        for k in 0 ..< 3 {
            hi, ok1 := hex(h[k*2]); lo, ok2 := hex(h[k*2+1])
            if !(ok1 && ok2) do return 0, false
            vals[k] = hi*16 + lo
        }
        r = vals[0]; g = vals[1]; b = vals[2]
        if len(h) == 8 {
            if hi, ok1 := hex(h[6]); ok1 {
                if lo, ok2 := hex(h[7]); ok2 {
                    alpha = hi*16 + lo
                    if alpha == 0 do alpha = 1
                }
            }
        }
    case:
        return 0, false
    }
    return u32(alpha) << 24 | u32(r) << 16 | u32(g) << 8 | u32(b), true
}

// Tokens do interior de uma função de cor: normaliza ',' e '/' em espaços.
@(private)
func_tokens :: proc(v: string) -> ([]string, bool) {
    open := strings.index_byte(v, '(')
    close := strings.index_byte(v, ')')
    if open < 0 || close < 0 || close < open do return nil, false
    inner := v[open + 1:close]
    buf := make([dynamic]u8, context.temp_allocator)
    for i in 0 ..< len(inner) {
        c := inner[i]
        if c == ',' || c == '/' do c = ' '
        append(&buf, c)
    }
    return strings.fields(string(buf[:]), context.temp_allocator), true
}

// Componente de função de cor: número, % (100% → scale) ou "none" (= 0).
@(private)
comp_number :: proc(tok: string, scale: f32) -> f32 {
    if strings.has_suffix(tok, "%") do return num_prefix(tok) / 100 * scale
    return num_prefix(tok) // "none" não tem prefixo numérico → 0
}

// oklch(L C H [/ A]) → 0xAARRGGBB. L: 0..1 ou % (100% = 1); C: número ou %
// (100% = 0.4); H: graus. Usado pelas paletas do Tailwind v4.
@(private)
parse_oklch :: proc(v: string) -> (u32, bool) {
    toks, k := func_tokens(v)
    if !k || len(toks) < 3 do return 0, false
    l := comp_number(toks[0], 1)
    c := comp_number(toks[1], 0.4)
    h := num_prefix(toks[2])
    rgb := oklch_to_rgb(l, c, h)
    if len(toks) >= 4 do rgb |= parse_alpha(toks[3]) << 24
    return rgb, true
}

// oklab(L a b [/ A]) → 0xAARRGGBB. a/b em % mapeiam 100% → 0.4.
// Converte para LCH e delega (mesmo gamut mapping do oklch).
@(private)
parse_oklab :: proc(v: string) -> (u32, bool) {
    toks, k := func_tokens(v)
    if !k || len(toks) < 3 do return 0, false
    l := comp_number(toks[0], 1)
    a := comp_number(toks[1], 0.4)
    b := comp_number(toks[2], 0.4)
    c := math.sqrt(a*a + b*b)
    h := math.atan2(b, a) * 180 / math.PI
    rgb := oklch_to_rgb(l, c, h)
    if len(toks) >= 4 do rgb |= parse_alpha(toks[3]) << 24
    return rgb, true
}

// OKLCH → sRGB com gamut mapping do CSS Color 4 §13: bissecção do croma com
// critério deltaE OK — aceita o clip por canal quando ele está perceptualmente
// perto (< JND) da cor reduzida. Sem isto, cores fora do gamut (ex.: paleta do
// Tailwind v4) clampariam por canal e mudariam de matiz visivelmente.
@(private)
oklch_to_rgb :: proc(L, C, H_deg: f32) -> u32 {
    if L >= 1 do return 0xffffff
    if L <= 0 do return 0x000000
    h  := H_deg * math.PI / 180
    ca := math.cos(h)
    cb := math.sin(h)
    r, g, b, ok := oklab_linear(L, C*ca, C*cb)
    if ok do return encode_srgb(r, g, b)

    JND :: 0.02   // deltaE OK "just noticeable difference"
    EPS :: 0.0001
    lo, hi: f32 = 0, C
    lo_in_gamut := true
    cr := clamp(r, 0, 1); cg := clamp(g, 0, 1); cbl := clamp(b, 0, 1)
    for hi - lo > EPS {
        chroma := (lo + hi) / 2
        r, g, b, ok = oklab_linear(L, chroma*ca, chroma*cb)
        cr = clamp(r, 0, 1); cg = clamp(g, 0, 1); cbl = clamp(b, 0, 1)
        if lo_in_gamut && ok {
            lo = chroma
            continue
        }
        // fora do gamut: mede a distância perceptual do clip até o candidato
        pL, pA, pB := oklab_from_linear(cr, cg, cbl)
        dl := pL - L
        da := pA - chroma*ca
        db := pB - chroma*cb
        e := math.sqrt(dl*dl + da*da + db*db)
        if e < JND {
            if JND - e < EPS do break // clip aceitável — devolve já
            lo_in_gamut = false
            lo = chroma
        } else {
            hi = chroma
        }
    }
    return encode_srgb(cr, cg, cbl)
}

// OKLab → sRGB linear (matrizes de Björn Ottosson). ok = dentro do gamut.
@(private)
oklab_linear :: proc(L, a, b: f32) -> (r, g, bl: f32, in_gamut: bool) {
    l_ := L + 0.3963377774*a + 0.2158037573*b
    m_ := L - 0.1055613458*a - 0.0638541728*b
    s_ := L - 0.0894841775*a - 1.2914855480*b
    l := l_*l_*l_
    m := m_*m_*m_
    s := s_*s_*s_
    r  = +4.0767416621*l - 3.3077115913*m + 0.2309699292*s
    g  = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
    bl = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
    EPS :: 0.0001
    in_gamut = r >= -EPS && r <= 1+EPS && g >= -EPS && g <= 1+EPS && bl >= -EPS && bl <= 1+EPS
    return
}

// sRGB linear → OKLab (inversa de oklab_linear; p/ o deltaE do gamut mapping).
@(private)
oklab_from_linear :: proc(r, g, bl: f32) -> (L, a, b: f32) {
    cbrt :: proc(x: f32) -> f32 { return math.pow(max(x, 0), 1.0/3) }
    l := cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*bl)
    m := cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*bl)
    s := cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*bl)
    L = 0.2104542553*l + 0.7936177850*m - 0.0040720468*s
    a = 1.9779984951*l - 2.4285922050*m + 0.4505937099*s
    b = 0.0259040371*l + 0.7827717662*m - 0.8086757660*s
    return
}

// sRGB linear → gamma + empacota 0xRRGGBB.
@(private)
encode_srgb :: proc(r, g, b: f32) -> u32 {
    to_srgb :: proc(x: f32) -> u32 {
        c := clamp(x, 0, 1)
        v := c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1.0/2.4) - 0.055
        return u32(clamp(v*255 + 0.5, 0, 255))
    }
    return to_srgb(r) << 16 | to_srgb(g) << 8 | to_srgb(b)
}

// ── color() com espaços predefinidos (CSS Color 4 §10) ──────────────────────
// color(<espaço> c1 c2 c3 [/ alpha]). Converte o espaço p/ sRGB linear (via
// linearização própria + matriz p/ XYZ D65 + XYZ→sRGB linear) e delega o gamma
// a encode_srgb. Cobre srgb, srgb-linear, display-p3, a98-rgb, rec2020, xyz.
// Espaço desconhecido → ok=false (a cascata mantém a declaração anterior).

// Matrizes lineares → XYZ (D65) e XYZ (D65) → sRGB linear (colorjs.io / spec).
@(private) XYZ65_TO_LSRGB := [9]f32{
     3.2409699419045226,  -1.537383177570094,   -0.4986107602930034,
    -0.9692436362808796,   1.8759675015077202,   0.04155505740717559,
     0.05563007969699366, -0.20397695888897652,  1.0569715142428786,
}
@(private) LP3_TO_XYZ65 := [9]f32{
    0.4865709486482162,  0.26566769316909306, 0.19821728523436247,
    0.2289745640697488,  0.6917385218365064,  0.079286914093745,
    0.0,                 0.04511338185890264, 1.043944368900976,
}
@(private) LA98_TO_XYZ65 := [9]f32{
    0.5766690429101305,  0.1855582379065463,  0.1882286462349947,
    0.29734497525053605, 0.6273635662554661,  0.07529145849399788,
    0.02703136138641234, 0.07068885253582723, 0.9913375368376388,
}
@(private) LREC2020_TO_XYZ65 := [9]f32{
    0.6369580483012914, 0.14461690358620832,  0.16888097516417205,
    0.2627002120112671, 0.6779980715188708,   0.05930171646986196,
    0.0,                0.028072693049087428, 1.060985057710791,
}

@(private)
mat3_apply :: proc(m: [9]f32, x, y, z: f32) -> (f32, f32, f32) {
    return m[0]*x + m[1]*y + m[2]*z,
           m[3]*x + m[4]*y + m[5]*z,
           m[6]*x + m[7]*y + m[8]*z
}

@(private)
srgb_to_linear :: proc(c: f32) -> f32 {
    a := abs(c)
    lin := a <= 0.04045 ? a / 12.92 : math.pow((a + 0.055) / 1.055, 2.4)
    return c < 0 ? -lin : lin
}
@(private)
a98_to_linear :: proc(c: f32) -> f32 {
    return c < 0 ? -math.pow(-c, 563.0/256) : math.pow(c, 563.0/256)
}
@(private)
rec2020_to_linear :: proc(c: f32) -> f32 {
    A :: f32(1.09929682680944)
    B :: f32(0.018053968510807)
    a := abs(c)
    lin := a < B * 4.5 ? a / 4.5 : math.pow((a + A - 1) / A, 1/0.45)
    return c < 0 ? -lin : lin
}

@(private)
parse_color_function :: proc(v: string) -> (u32, bool) {
    toks, k := func_tokens(v)
    if !k || len(toks) < 4 do return 0, false
    space := strings.to_lower(toks[0], context.temp_allocator)
    c1 := comp_number(toks[1], 1)
    c2 := comp_number(toks[2], 1)
    c3 := comp_number(toks[3], 1)

    r, g, b: f32
    switch space {
    case "srgb":
        r, g, b = srgb_to_linear(c1), srgb_to_linear(c2), srgb_to_linear(c3)
    case "srgb-linear":
        r, g, b = c1, c2, c3
    case "display-p3":
        x, y, z := mat3_apply(LP3_TO_XYZ65, srgb_to_linear(c1), srgb_to_linear(c2), srgb_to_linear(c3))
        r, g, b = mat3_apply(XYZ65_TO_LSRGB, x, y, z)
    case "a98-rgb":
        x, y, z := mat3_apply(LA98_TO_XYZ65, a98_to_linear(c1), a98_to_linear(c2), a98_to_linear(c3))
        r, g, b = mat3_apply(XYZ65_TO_LSRGB, x, y, z)
    case "rec2020":
        x, y, z := mat3_apply(LREC2020_TO_XYZ65, rec2020_to_linear(c1), rec2020_to_linear(c2), rec2020_to_linear(c3))
        r, g, b = mat3_apply(XYZ65_TO_LSRGB, x, y, z)
    case "xyz", "xyz-d65":
        r, g, b = mat3_apply(XYZ65_TO_LSRGB, c1, c2, c3)
    case:
        return 0, false
    }
    out := encode_srgb(r, g, b)
    if len(toks) >= 5 do out |= parse_alpha(toks[4]) << 24
    return out, true
}

// ── lab()/lch() (CIELAB, CSS Color 4 §9) ────────────────────────────────────
// Adaptação de branco D50 (referência do CIELAB no CSS) → D65 (Bradford) e daí
// p/ sRGB linear via XYZ65_TO_LSRGB. lch delega em lab (a=C·cosH, b=C·senH).
@(private) D50_TO_D65 := [9]f32{
     0.9554734527042182,   -0.023098536874261423,  0.0632593086610217,
    -0.028369706963208136,  1.0099954580058226,    0.021041398966943008,
     0.012314001688319899, -0.020507696433477912,  1.3303659366080753,
}

@(private)
lab_to_rgb :: proc(L, a, b: f32) -> u32 {
    f3 :: proc(f: f32) -> f32 { return f*f*f }
    E :: f32(216.0/24389)   // ε
    K :: f32(24389.0/27)    // κ
    fy := (L + 16) / 116
    fx := fy + a/500
    fz := fy - b/200
    xr := f3(fx) > E ? f3(fx) : (116*fx - 16)/K
    yr := L > 8      ? f3(fy) : L/K            // κ·ε = 8
    zr := f3(fz) > E ? f3(fz) : (116*fz - 16)/K
    // branco D50 de referência do CSS
    Xn :: f32(0.9642956764295677)
    Zn :: f32(0.8251046025104602)
    x65, y65, z65 := mat3_apply(D50_TO_D65, xr*Xn, yr, zr*Zn)
    r, g, bl := mat3_apply(XYZ65_TO_LSRGB, x65, y65, z65)
    return encode_srgb(r, g, bl)
}

@(private)
parse_lab :: proc(v: string) -> (u32, bool) {
    toks, k := func_tokens(v)
    if !k || len(toks) < 3 do return 0, false
    L := comp_number(toks[0], 100)   // L: 0..100 (100% = 100)
    a := comp_number(toks[1], 125)   // a/b: número ou % (100% = 125)
    b := comp_number(toks[2], 125)
    rgb := lab_to_rgb(L, a, b)
    if len(toks) >= 4 do rgb |= parse_alpha(toks[3]) << 24
    return rgb, true
}

@(private)
parse_lch :: proc(v: string) -> (u32, bool) {
    toks, k := func_tokens(v)
    if !k || len(toks) < 3 do return 0, false
    L := comp_number(toks[0], 100)
    C := comp_number(toks[1], 150)   // croma: 100% = 150
    h := num_prefix(toks[2]) * math.PI / 180
    rgb := lab_to_rgb(L, C*math.cos(h), C*math.sin(h))
    if len(toks) >= 4 do rgb |= parse_alpha(toks[3]) << 24
    return rgb, true
}

// rgb()/rgba() → 0xAARRGGBB. Aceita vírgulas ou a sintaxe moderna "r g b / a".
@(private)
parse_rgb :: proc(v: string) -> (u32, bool) {
    open := strings.index_byte(v, '(')
    close := strings.index_byte(v, ')')
    if open < 0 || close < 0 || close < open do return 0, false
    inner := v[open + 1:close]
    buf := make([dynamic]u8, context.temp_allocator) // normaliza ',' e '/' em espaços
    for i in 0 ..< len(inner) {
        c := inner[i]
        if c == ',' || c == '/' do c = ' '
        append(&buf, c)
    }
    toks := strings.fields(string(buf[:]), context.temp_allocator)
    if len(toks) < 3 do return 0, false
    out := channel(toks[0]) << 16 | channel(toks[1]) << 8 | channel(toks[2])
    if len(toks) >= 4 do out |= parse_alpha(toks[3]) << 24
    return out, true
}

@(private)
named_color :: proc(name: string) -> (u32, bool) {
    switch name {
    case "transparent": return 0, false
    case "aliceblue": return 0xf0f8ff, true
    case "antiquewhite": return 0xfaebd7, true
    case "aqua", "cyan": return 0x00ffff, true
    case "aquamarine": return 0x7fffd4, true
    case "azure": return 0xf0ffff, true
    case "beige": return 0xf5f5dc, true
    case "bisque": return 0xffe4c4, true
    case "black": return 0x000000, true
    case "blanchedalmond": return 0xffebcd, true
    case "blue": return 0x0000ff, true
    case "blueviolet": return 0x8a2be2, true
    case "brown": return 0xa52a2a, true
    case "burlywood": return 0xdeb887, true
    case "cadetblue": return 0x5f9ea0, true
    case "chartreuse": return 0x7fff00, true
    case "chocolate": return 0xd2691e, true
    case "coral": return 0xff7f50, true
    case "cornflowerblue": return 0x6495ed, true
    case "cornsilk": return 0xfff8dc, true
    case "crimson": return 0xdc143c, true
    case "darkblue": return 0x00008b, true
    case "darkcyan": return 0x008b8b, true
    case "darkgoldenrod": return 0xb8860b, true
    case "darkgray", "darkgrey": return 0xa9a9a9, true
    case "darkgreen": return 0x006400, true
    case "darkkhaki": return 0xbdb76b, true
    case "darkmagenta": return 0x8b008b, true
    case "darkolivegreen": return 0x556b2f, true
    case "darkorange": return 0xff8c00, true
    case "darkorchid": return 0x9932cc, true
    case "darkred": return 0x8b0000, true
    case "darksalmon": return 0xe9967a, true
    case "darkseagreen": return 0x8fbc8f, true
    case "darkslateblue": return 0x483d8b, true
    case "darkslategray", "darkslategrey": return 0x2f4f4f, true
    case "darkturquoise": return 0x00ced1, true
    case "darkviolet": return 0x9400d3, true
    case "deeppink": return 0xff1493, true
    case "deepskyblue": return 0x00bfff, true
    case "dimgray", "dimgrey": return 0x696969, true
    case "dodgerblue": return 0x1e90ff, true
    case "firebrick": return 0xb22222, true
    case "floralwhite": return 0xfffaf0, true
    case "forestgreen": return 0x228b22, true
    case "fuchsia", "magenta": return 0xff00ff, true
    case "gainsboro": return 0xdcdcdc, true
    case "ghostwhite": return 0xf8f8ff, true
    case "gold": return 0xffd700, true
    case "goldenrod": return 0xdaa520, true
    case "gray", "grey": return 0x808080, true
    case "green": return 0x008000, true
    case "greenyellow": return 0xadff2f, true
    case "honeydew": return 0xf0fff0, true
    case "hotpink": return 0xff69b4, true
    case "indianred": return 0xcd5c5c, true
    case "indigo": return 0x4b0082, true
    case "ivory": return 0xfffff0, true
    case "khaki": return 0xf0e68c, true
    case "lavender": return 0xe6e6fa, true
    case "lavenderblush": return 0xfff0f5, true
    case "lawngreen": return 0x7cfc00, true
    case "lemonchiffon": return 0xfffacd, true
    case "lightblue": return 0xadd8e6, true
    case "lightcoral": return 0xf08080, true
    case "lightcyan": return 0xe0ffff, true
    case "lightgoldenrodyellow": return 0xfafad2, true
    case "lightgray", "lightgrey": return 0xd3d3d3, true
    case "lightgreen": return 0x90ee90, true
    case "lightpink": return 0xffb6c1, true
    case "lightsalmon": return 0xffa07a, true
    case "lightseagreen": return 0x20b2aa, true
    case "lightskyblue": return 0x87cefa, true
    case "lightslategray", "lightslategrey": return 0x778899, true
    case "lightsteelblue": return 0xb0c4de, true
    case "lightyellow": return 0xffffe0, true
    case "lime": return 0x00ff00, true
    case "limegreen": return 0x32cd32, true
    case "linen": return 0xfaf0e6, true
    case "maroon": return 0x800000, true
    case "mediumaquamarine": return 0x66cdaa, true
    case "mediumblue": return 0x0000cd, true
    case "mediumorchid": return 0xba55d3, true
    case "mediumpurple": return 0x9370db, true
    case "mediumseagreen": return 0x3cb371, true
    case "mediumslateblue": return 0x7b68ee, true
    case "mediumspringgreen": return 0x00fa9a, true
    case "mediumturquoise": return 0x48d1cc, true
    case "mediumvioletred": return 0xc71585, true
    case "midnightblue": return 0x191970, true
    case "mintcream": return 0xf5fffa, true
    case "mistyrose": return 0xffe4e1, true
    case "moccasin": return 0xffe4b5, true
    case "navajowhite": return 0xffdead, true
    case "navy": return 0x000080, true
    case "oldlace": return 0xfdf5e6, true
    case "olive": return 0x808000, true
    case "olivedrab": return 0x6b8e23, true
    case "orange": return 0xffa500, true
    case "orangered": return 0xff4500, true
    case "orchid": return 0xda70d6, true
    case "palegoldenrod": return 0xeee8aa, true
    case "palegreen": return 0x98fb98, true
    case "paleturquoise": return 0xafeeee, true
    case "palevioletred": return 0xdb7093, true
    case "papayawhip": return 0xffefd5, true
    case "peachpuff": return 0xffdab9, true
    case "peru": return 0xcd853f, true
    case "pink": return 0xffc0cb, true
    case "plum": return 0xdda0dd, true
    case "powderblue": return 0xb0e0e6, true
    case "purple": return 0x800080, true
    case "rebeccapurple": return 0x663399, true
    case "red": return 0xff0000, true
    case "rosybrown": return 0xbc8f8f, true
    case "royalblue": return 0x4169e1, true
    case "saddlebrown": return 0x8b4513, true
    case "salmon": return 0xfa8072, true
    case "sandybrown": return 0xf4a460, true
    case "seagreen": return 0x2e8b57, true
    case "seashell": return 0xfff5ee, true
    case "sienna": return 0xa0522d, true
    case "silver": return 0xc0c0c0, true
    case "skyblue": return 0x87ceeb, true
    case "slateblue": return 0x6a5acd, true
    case "slategray", "slategrey": return 0x708090, true
    case "snow": return 0xfffafa, true
    case "springgreen": return 0x00ff7f, true
    case "steelblue": return 0x4682b4, true
    case "tan": return 0xd2b48c, true
    case "teal": return 0x008080, true
    case "thistle": return 0xd8bfd8, true
    case "tomato": return 0xff6347, true
    case "turquoise": return 0x40e0d0, true
    case "violet": return 0xee82ee, true
    case "wheat": return 0xf5deb3, true
    case "white": return 0xffffff, true
    case "whitesmoke": return 0xf5f5f5, true
    case "yellow": return 0xffff00, true
    case "yellowgreen": return 0x9acd32, true
    }
    return 0, false
}

// ── Custom Properties ────────────────────────────────────────────────────────

// Coleta as custom properties (--name: value) de um mapa de declarações para
// um dict destino. Deve ser chamado para as regras :root e * antes de resolver.
collect_custom_props :: proc(decls: map[string]string, dest: ^map[string]string) {
    for k, v in decls {
        if strings.has_prefix(k, "--") {
            dest^[strings.clone(k)] = strings.clone(v)
        }
    }
}

// Substitui var(--name) e var(--name, fallback) no valor usando o dict de
// custom properties. Retorna a string resolvida (alocada em temp_allocator).
// Suporta aninhamento simples de var() e fallbacks literais (sem outro var()).
// Limite de 32 passagens para evitar ciclos.
resolve_vars :: proc(value: string, props: map[string]string) -> string {
    if !strings.contains(value, "var(") do return value
    cur := value
    for pass in 0 ..< 32 {
        idx := strings.index(cur, "var(")
        if idx < 0 do break
        // encontra o ')' balanceado
        start := idx + 4
        depth := 1
        j := start
        for j < len(cur) && depth > 0 {
            if cur[j] == '(' do depth += 1
            else if cur[j] == ')' do depth -= 1
            j += 1
        }
        if depth != 0 do break
        inner := cur[start : j - 1]
        // separa nome do fallback na primeira vírgula de profundidade 0
        name, fallback := inner, ""
        comma_d := 0
        for ci := 0; ci < len(inner); ci += 1 {
            switch inner[ci] {
            case '(': comma_d += 1
            case ')': comma_d -= 1
            case ',':
                if comma_d == 0 {
                    name     = strings.trim_space(inner[:ci])
                    fallback = strings.trim_space(inner[ci + 1:])
                    ci       = len(inner) // break
                }
            }
        }
        replacement: string
        if val, ok := props[name]; ok {
            replacement = val
        } else if fallback != "" {
            replacement = fallback
        } else {
            // variável desconhecida sem fallback — não substitui p/ não perder o context
            break
        }
        cur = strings.concatenate({cur[:idx], replacement, cur[j:]}, context.temp_allocator)
    }
    return cur
}

// ── Utilitários ─────────────────────────────────────────────────────────────

// ── Posse das strings de uma regra ──────────────────────────────────────────
// TODAS as strings de um Rule/Selector são OWNED (heap). Antes, `tag`, `id`,
// `Attr_Sel.name/.val` e `Rule.cq_name` eram FATIAS do `src` que o `parse`
// deixa na arena temp (strip_comments) — então as rules morriam no primeiro
// `free_all(context.temp_allocator)`. Era por isso que o `restyle_tab` tinha de
// RE-PARSEAR a folha inteira a cada mutação/zoom/tick em vez de cachear: os
// seletores danglavam. Agora as rules são autocontidas e podem sobreviver ao
// free_all (o que também tira uma classe inteira de use-after-free latente —
// ver o caso do Box.offset_path, que era exatamente esse padrão).
// `decls` (chave e valor) e `classes` já eram owned.
free_compound :: proc(p: ^Compound) {
    delete(p.tag)
    delete(p.id)
    for cl in p.classes do delete(cl) // strings OWNED (css_unescape clona)
    delete(p.classes)
    for a in p.attrs { delete(a.name); delete(a.val) }
    delete(p.attrs)
    for &ns in p.nots do free_selector(&ns)
    delete(p.nots)
    for &os in p.ors do free_selector(&os)
    delete(p.ors)
    for &h in p.has do free_selector(&h.sel)
    delete(p.has)
}

free_selector :: proc(s: ^Selector) {
    for &p in s.parts do free_compound(&p)
    delete(s.parts)
    delete(s.combs)
}

free_rules :: proc(rules: ^[dynamic]Rule) {
    for &r in rules {
        for &s in r.selectors do free_selector(&s)
        delete(r.selectors)
        for k, v in r.decls { delete(k); delete(v) }
        delete(r.decls)
        delete(r.cq_name)
    }
    delete(rules^)
}

free_keyframes :: proc(kf: ^[dynamic]Keyframe_Set) {
    for &set in kf {
        delete(set.name)
        for &st in set.stops {
            for k, v in st.decls { delete(k); delete(v) }
            delete(st.decls)
        }
        delete(set.stops)
    }
    delete(kf^)
}

// Parseia o corpo de um @keyframes: "<seletor>{decls} ..." em stops ordenados
// por pct. Seletor: from(=0%)/to(=100%)/N% (lista separada por vírgula).
@(private)
parse_keyframes :: proc(name, body: string, out: ^[dynamic]Keyframe_Set) {
    set := Keyframe_Set{ name = strings.clone(name) }
    i, n := 0, len(body)
    for i < n {
        for i < n && is_space(body[i]) do i += 1
        if i >= n do break
        sel_start := i
        for i < n && body[i] != '{' do i += 1
        if i >= n do break
        sel := body[sel_start:i]
        i += 1 // '{'
        decl_start := i
        for i < n && body[i] != '}' do i += 1
        decl_text := body[decl_start:i]
        if i < n do i += 1 // '}'
        for part in strings.split(sel, ",", context.temp_allocator) {
            p := strings.to_lower(strings.trim_space(part), context.temp_allocator)
            pct: f32 = -1
            if p == "from" do pct = 0
            else if p == "to" do pct = 1
            else if strings.has_suffix(p, "%") {
                if v, ok := strconv.parse_f64(p[:len(p) - 1]); ok do pct = f32(v) / 100.0
            }
            if pct < 0 do continue
            append(&set.stops, Keyframe{ pct = pct, decls = parse_decls(decl_text, context.allocator) })
        }
    }
    // ordena por pct (insertion sort — poucos stops)
    for a in 1 ..< len(set.stops) {
        key := set.stops[a]; b := a - 1
        for b >= 0 && set.stops[b].pct > key.pct { set.stops[b + 1] = set.stops[b]; b -= 1 }
        set.stops[b + 1] = key
    }
    if len(set.stops) > 0 do append(out, set)
    else                  do delete(set.name)
}

@(private)
is_space :: proc(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

@(private)
strip_comments :: proc(s: string, allocator := context.allocator) -> string {
    if !strings.contains(s, "/*") do return strings.clone(s, allocator)
    // Um comentário CSS é um LIMITE de token, não uma simples deleção: `120/**/75%`
    // são dois tokens (120 e 75%), não `12075%`. Ao pular o comentário, se o byte
    // anterior e o seguinte se fundiriam num só token (ambos "de palavra": alnum ou
    // %), insere um espaço. Chars não-palavra (`.`, `,`, `(`, `;`…) já separam, então
    // não recebem espaço — assim `.a/**/.b` continua `.a.b` (composto) e não vira
    // `.a .b` (descendente).
    is_word :: proc(c: u8) -> bool {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '%'
    }
    sb := strings.builder_make(allocator)
    i := 0
    n := len(s)
    prev: u8 = 0 // último byte escrito
    for i < n {
        if i + 1 < n && s[i] == '/' && s[i + 1] == '*' {
            end := strings.index(s[i:], "*/")
            if end < 0 do break
            i += end + 2
            if prev != 0 && i < n && is_word(prev) && is_word(s[i]) {
                strings.write_byte(&sb, ' ')
                prev = ' '
            }
        } else {
            strings.write_byte(&sb, s[i])
            prev = s[i]
            i += 1
        }
    }
    return strings.to_string(sb)
}
