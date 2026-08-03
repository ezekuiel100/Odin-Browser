package ui

// M223 — `transition-property`, `transition-timing-function` e `transition-delay`.
//
// ANTES: o motor lia do `transition` (ou do `transition-duration`) só a PRIMEIRA
// duração e jogava fora o resto. Um único `transition_dur: f32` por elemento
// governava TODOS os canais animáveis, a curva era `ease-in-out` hardcoded e o
// delay não existia. Consequências visíveis: `transition: opacity .3s` animava
// também a cor de fundo e o transform; `transition: transform .6s cubic-bezier(...)`
// saía com a curva errada; e todo efeito escalonado (`transition-delay` crescente
// numa lista) acontecia de uma vez só.
//
// ── O recorte honesto ───────────────────────────────────────────────────────
// O motor sabe interpolar CINCO canais (é o que existe no Trans_State): fundo,
// cor de borda, opacidade, transform (rot/scale) e cor de texto. `transition-property`
// passa a ser respeitado MAPEANDO cada nome para esses canais; um nome fora da
// lista (`width`, `box-shadow`, `filter`…) é parseado e IGNORADO — a mudança
// continua instantânea, como sempre foi. A degradação está nomeada em
// `trans_chans_for`, que é a lista do que dá para animar.
//
// ⚠️ `animation-timing-function` (de @keyframes) continua no `ease_inout`
// hardcoded: o avaliador `timing_eval` daqui serve, mas ligá-lo mexeria no
// render de @keyframes — feature separada, fora deste marco.

import "core:strings"
import "core:strconv"
import "core:math"

// Canal que o motor sabe interpolar. É deliberadamente pequeno: é o inventário
// do que existe em Trans_State, não a lista de props animáveis do CSS.
Trans_Chan :: enum u8 { Bg, Border, Opacity, Transform, Color }

Timing_Kind :: enum u8 { Linear, CubicBezier, Steps }

// Função de tempo. As palavras-chave viram cubic-bezier com os pontos da spec
// (css-easing-1 §2.1), então há UM avaliador só.
Timing :: struct {
    kind:           Timing_Kind,
    x1, y1, x2, y2: f32,
    steps:          int,
    jump_start:     bool,
}

Transition :: struct {
    dur, delay: f32,
    timing:     Timing,
    on:         bool, // dur > 0: só então há interpolação (senão, salto instantâneo)
}

// `ease` é o default da spec — e é diferente de ease-in-out.
TIMING_DEFAULT :: Timing{kind = .CubicBezier, x1 = 0.25, y1 = 0.1, x2 = 0.25, y2 = 1}

// ── avaliação ───────────────────────────────────────────────────────────────

// Progresso 0..1 → progresso "eased" 0..1.
timing_eval :: proc(tm: Timing, x0: f32) -> f32 {
    x := clamp(x0, 0, 1)
    switch tm.kind {
    case .Linear:
        return x
    case .Steps:
        n := tm.steps
        if n <= 0 do return x
        p := math.floor(x * f32(n))
        if tm.jump_start do p += 1
        return clamp(p / f32(n), 0, 1)
    case .CubicBezier:
        return cubic_bezier_y(tm, x)
    }
    return x
}

// Bézier cúbica com P0=(0,0) e P3=(1,1): acha o parâmetro t tal que X(t)=x e
// devolve Y(t). Newton a partir de t=x (converge em ~4 passos na prática) com
// bisseção de reserva para as curvas quase-verticais, onde a derivada some.
@(private = "file")
cubic_bezier_y :: proc(tm: Timing, x: f32) -> f32 {
    cx := 3 * tm.x1
    bx := 3 * (tm.x2 - tm.x1) - cx
    ax := 1 - cx - bx
    cy := 3 * tm.y1
    by := 3 * (tm.y2 - tm.y1) - cy
    ay := 1 - cy - by
    sample_x :: proc(t, a, b, c: f32) -> f32 { return ((a * t + b) * t + c) * t }

    t := x
    for _ in 0 ..< 8 {
        d := sample_x(t, ax, bx, cx) - x
        if abs(d) < 1e-5 do break
        deriv := (3 * ax * t + 2 * bx) * t + cx
        if abs(deriv) < 1e-6 do break
        t -= d / deriv
    }
    if abs(sample_x(t, ax, bx, cx) - x) > 1e-5 { // Newton não fechou: bisseção
        lo, hi := f32(0), f32(1)
        t = x
        for _ in 0 ..< 24 {
            v := sample_x(t, ax, bx, cx)
            if abs(v - x) < 1e-5 do break
            if v > x { hi = t } else { lo = t }
            t = (lo + hi) / 2
        }
    }
    return sample_x(clamp(t, 0, 1), ay, by, cy)
}

// ── parsing ─────────────────────────────────────────────────────────────────

// Nome de propriedade → canais que ele governa NESTE motor. Vazio = reconhecido
// mas não animável aqui (a mudança fica instantânea).
@(private = "file")
trans_chans_for :: proc(name: string) -> bit_set[Trans_Chan] {
    switch name {
    case "all":
        return {.Bg, .Border, .Opacity, .Transform, .Color}
    case "background", "background-color":
        return {.Bg}
    case "border", "border-color", "border-top-color", "border-right-color",
         "border-bottom-color", "border-left-color", "border-block-color", "border-inline-color":
        return {.Border}
    case "opacity":
        return {.Opacity}
    case "transform", "rotate", "scale", "translate":
        return {.Transform}
    case "color":
        return {.Color}
    }
    return {}
}

// Palavra-chave/função de timing → Timing. ok=false se o token não for timing.
@(private = "file")
parse_timing :: proc(tok: string) -> (Timing, bool) {
    t := strings.trim_space(tok)
    switch t {
    case "linear":      return Timing{kind = .Linear}, true
    case "ease":        return TIMING_DEFAULT, true
    case "ease-in":     return Timing{kind = .CubicBezier, x1 = 0.42, y1 = 0,    x2 = 1,    y2 = 1}, true
    case "ease-out":    return Timing{kind = .CubicBezier, x1 = 0,    y1 = 0,    x2 = 0.58, y2 = 1}, true
    case "ease-in-out": return Timing{kind = .CubicBezier, x1 = 0.42, y1 = 0,    x2 = 0.58, y2 = 1}, true
    case "step-start":  return Timing{kind = .Steps, steps = 1, jump_start = true}, true
    case "step-end":    return Timing{kind = .Steps, steps = 1}, true
    }
    if strings.has_prefix(t, "cubic-bezier(") && strings.has_suffix(t, ")") {
        args := strings.split(t[len("cubic-bezier(") : len(t) - 1], ",", context.temp_allocator)
        if len(args) != 4 do return {}, false
        v: [4]f32
        for a, i in args {
            n, ok := strconv.parse_f64(strings.trim_space(a))
            if !ok do return {}, false
            v[i] = f32(n)
        }
        // x1/x2 fora de [0,1] tornam a curva não-funcional (a spec invalida)
        if v[0] < 0 || v[0] > 1 || v[2] < 0 || v[2] > 1 do return {}, false
        return Timing{kind = .CubicBezier, x1 = v[0], y1 = v[1], x2 = v[2], y2 = v[3]}, true
    }
    if strings.has_prefix(t, "steps(") && strings.has_suffix(t, ")") {
        inner := t[len("steps(") : len(t) - 1]
        parts := strings.split(inner, ",", context.temp_allocator)
        n, ok := strconv.parse_int(strings.trim_space(parts[0]))
        if !ok || n < 1 do return {}, false
        js := false
        if len(parts) > 1 {
            switch strings.trim_space(parts[1]) {
            case "start", "jump-start", "jump-both": js = true
            }
        }
        return Timing{kind = .Steps, steps = n, jump_start = js}, true
    }
    return {}, false
}

// Divide por vírgulas de TOPO (as de dentro de `cubic-bezier(...)`/`steps(...)`
// não separam itens da lista).
@(private = "file")
split_commas_top :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',':
            if depth == 0 {
                append(&out, strings.trim_space(s[start:i]))
                start = i + 1
            }
        }
    }
    append(&out, strings.trim_space(s[start:]))
    return out[:]
}

// Tokens separados por espaço, mantendo `f(a, b)` inteiro.
@(private = "file")
fields_paren_aware :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, -1
    for i in 0 ..< len(s) {
        c := s[i]
        if      c == '(' do depth += 1
        else if c == ')' do depth -= 1
        if depth == 0 && (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if start >= 0 { append(&out, s[start:i]); start = -1 }
        } else if start < 0 {
            start = i
        }
    }
    if start >= 0 do append(&out, s[start:])
    return out[:]
}

TRANS_MAX :: 8

@(private = "file")
Trans_Item :: struct {
    prop:    string,
    dur:     f32,
    delay:   f32,
    timing:  Timing,
    invalid: bool, // token de FUNÇÃO que não parseou ⇒ o item inteiro cai (spec)
}

// Preenche `out` (a tabela por canal do Computed) a partir das declarações.
// Chamado do apply_decls; `out` já vem zerado pelo reset das não-herdadas.
parse_transitions :: proc(out: ^[Trans_Chan]Transition, shorthand, p_prop, p_dur, p_timing, p_delay: string) {
    items: [TRANS_MAX]Trans_Item
    n := 0

    // 1) shorthand: cada item da lista traz nome/duração/timing/atraso em ordem
    //    LIVRE — o que decide é o tipo do token, exceto entre os dois tempos, em
    //    que o 1º é a duração e o 2º o atraso (spec).
    if strings.trim_space(shorthand) != "" {
        for part in split_commas_top(strings.to_lower(shorthand, context.temp_allocator)) {
            if n >= TRANS_MAX do break
            it := Trans_Item{prop = "all", timing = TIMING_DEFAULT}
            times := 0
            for tok in fields_paren_aware(part) {
                if v, ok := parse_time_token(tok); ok {
                    if times == 0 { it.dur = v } else if times == 1 { it.delay = v }
                    times += 1
                    continue
                }
                if tm, ok := parse_timing(tok); ok { it.timing = tm; continue }
                // Token de FUNÇÃO que não é timing válida (`cubic-bezier(2,0,…)`
                // com x fora de [0,1], `steps(0)`) invalida o item — não pode
                // virar "nome de propriedade" por descuido.
                if strings.contains(tok, "(") { it.invalid = true; continue }
                it.prop = tok // sobra: é o nome da propriedade
            }
            items[n] = it; n += 1
        }
    }

    // 2) longhands sobrepõem campo a campo. A contagem de transições é a da
    //    lista de `transition-property` (spec); as outras listas REPETEM
    //    ciclicamente quando são mais curtas.
    set_list :: proc(items: ^[TRANS_MAX]Trans_Item, n: ^int, raw: string, field: int) {
        if strings.trim_space(raw) == "" do return
        vals := split_commas_top(strings.to_lower(raw, context.temp_allocator))
        if len(vals) == 0 do return
        if field == 0 { // transition-property define QUANTAS transições existem
            n^ = min(len(vals), TRANS_MAX)
            for i in 0 ..< n^ {
                if items[i] == {} do items[i] = Trans_Item{prop = "all", timing = TIMING_DEFAULT}
                items[i].prop = vals[i]
            }
            return
        }
        if n^ == 0 { // longhand sem property nem shorthand: assume `all`
            n^ = 1
            items[0] = Trans_Item{prop = "all", timing = TIMING_DEFAULT}
        }
        for i in 0 ..< n^ {
            v := vals[i % len(vals)]
            switch field {
            case 1: if t, ok := parse_time_token(v); ok do items[i].dur = t
            case 2: if tm, ok := parse_timing(v); ok do items[i].timing = tm
            case 3: if t, ok := parse_time_token(v); ok do items[i].delay = t
            }
        }
    }
    set_list(&items, &n, p_prop, 0)
    set_list(&items, &n, p_dur, 1)
    set_list(&items, &n, p_timing, 2)
    set_list(&items, &n, p_delay, 3)

    // 3) espalha nos canais. Item posterior na lista vence (é a ordem da spec p/
    //    a mesma propriedade declarada duas vezes).
    for i in 0 ..< n {
        it := items[i]
        if it.invalid || it.prop == "none" do continue
        for ch in trans_chans_for(it.prop) {
            out[ch] = Transition{dur = it.dur, delay = it.delay, timing = it.timing, on = it.dur > 0}
        }
    }
}

// Algum canal com transição ativa?
trans_any :: proc(tr: [Trans_Chan]Transition) -> bool {
    for ch in Trans_Chan do if tr[ch].on do return true
    return false
}
