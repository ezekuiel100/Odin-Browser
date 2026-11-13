package ui

// Per-phase profile of compute_styles (compile-gated: `-define:STYLEPROF=true`).
// Zero cost when off. Printed at the end of each compute_styles call so a
// restyle on a real site can be split into cascade phases.

import "core:fmt"
import "core:time"
import css "../css"

STYLEPROF :: #config(STYLEPROF, false)

Style_Prof_Phase :: enum {
    Index,     // build_rule_index
    Query,     // query_candidates
    Collect,   // collect_decls, normal pass
    Vars,      // custom property cloning
    Apply,     // apply_decls
    Post,      // inherit keywords, animation, svg css, grid fixups
    Pseudo,    // ::before/::after/::first-letter/::placeholder
    Hover,     // :hover pass
    Finger,    // style fingerprints
    Counters,  // resolve_counters
}

Style_Prof :: struct {
    ns:            [Style_Prof_Phase]i64,
    nodes:         int,
    elements:      int,
    candidates:    int,
    clones:        int,
    clone_entries: int,
    total_ns:      i64,
    cand_from:     [4]int, // universal, tag, id+class, attr
    coll_sub:      [4]i64, // collect_decls: candidatos | inline | rollback | aliases+lógicas+shorthands
}

style_prof_sub :: proc(i: int, t0: time.Tick) {
    when STYLEPROF { g_style_prof.coll_sub[i] += i64(time.tick_since(t0)) }
}

g_style_prof_tags: map[string]int

Rule_Cost :: struct { ns: i64, calls, hits: int, desc: string }
g_style_prof_rules: map[int]Rule_Cost

// Descrição legível (aproximada) do seletor p/ achar a regra cara no relatório.
style_prof_sel_desc :: proc(sel: css.Selector) -> string {
    b: [dynamic]u8
    for p, i in sel.parts {
        if i > 0 && i - 1 < len(sel.combs) {
            switch sel.combs[i - 1] {
            case .Descendant: append(&b, ' ')
            case .Child:      append(&b, " > ")
            case .Adjacent:   append(&b, " + ")
            case .Sibling:    append(&b, " ~ ")
            }
        }
        if p.tag != "" do append(&b, p.tag)
        if p.id != "" { append(&b, '#'); append(&b, p.id) }
        for c in p.classes { append(&b, '.'); append(&b, c) }
        for a in p.attrs { append(&b, '['); append(&b, a.name); append(&b, ']') }
        if len(p.nots) > 0 do append(&b, fmt.tprintf(":not(%d)", len(p.nots)))
        if len(p.ors) > 0 do append(&b, fmt.tprintf(":is(%d)", len(p.ors)))
        if len(p.has) > 0 {
            append(&b, ":has(")
            for h in p.has { append(&b, style_prof_sel_desc(h.sel)); append(&b, ",") }
            append(&b, ")")
        }
        if p.nth_kind != .None do append(&b, fmt.tprintf(":%v", p.nth_kind))
        if p.pseudo != .None do append(&b, fmt.tprintf("::%v", p.pseudo))
    }
    return string(b[:])
}

style_prof_rule :: proc(ri: int, sel: css.Selector, t0: time.Tick, hit: bool) {
    when STYLEPROF {
        if g_style_prof_rules == nil do g_style_prof_rules = make(map[int]Rule_Cost)
        rc := g_style_prof_rules[ri]
        rc.ns += i64(time.tick_since(t0))
        rc.calls += 1
        if hit do rc.hits += 1
        if rc.desc == "" do rc.desc = style_prof_sel_desc(sel)
        g_style_prof_rules[ri] = rc
    }
}

style_prof_tag :: proc(tag: string, n: int) {
    when STYLEPROF {
        if g_style_prof_tags == nil do g_style_prof_tags = make(map[string]int)
        g_style_prof_tags[tag] += n
    }
}

g_style_prof: Style_Prof

// What lands in the universal bucket of the rule index (the bucket every
// element pays for). Keyed by a short description of the key compound.
g_style_prof_uni: map[string]int

style_prof_classify_universal :: proc(rule: css.Rule, key: css.Compound) {
    when STYLEPROF {
        if g_style_prof_uni == nil do g_style_prof_uni = make(map[string]int)
        k: string
        switch {
        case rule.media_excluded:   k = "media_excluded"
        case key.never:             k = "never"
        case len(key.ors) > 0:      k = ":is/:where"
        case len(key.attrs) > 0:    k = fmt.aprintf("[%s]", key.attrs[0].name)
        case len(key.nots) > 0:     k = ":not só"
        case len(key.has) > 0:      k = ":has só"
        case key.pseudo != .None:   k = fmt.aprintf("::%v", key.pseudo)
        case key.state != .None:    k = fmt.aprintf(":%v", key.state)
        case key.nth_kind != .None: k = ":nth"
        case key.scope_req:         k = ":scope"
        case:                       k = "* puro"
        }
        g_style_prof_uni[k] += 1
    }
}

style_prof_now :: #force_inline proc() -> time.Tick {
    when STYLEPROF { return time.tick_now() } else { return {} }
}

style_prof_add :: #force_inline proc(p: Style_Prof_Phase, t0: time.Tick) {
    when STYLEPROF { g_style_prof.ns[p] += i64(time.tick_since(t0)) }
}

time_since_ns :: proc(t0: time.Tick) -> i64 { return i64(time.tick_since(t0)) }

style_prof_report :: proc() {
    when STYLEPROF {
        p := g_style_prof
        ms :: proc(ns: i64) -> f64 { return f64(ns) / 1e6 }
        fmt.eprintfln("[styleprof] compute_styles %.1f ms | %d nós (%d elementos) | %d candidatos (%.1f/elem) | %d clones de vars (%d entradas, %.0f/clone)",
            ms(p.total_ns), p.nodes, p.elements, p.candidates, f64(p.candidates) / max(f64(p.elements), 1),
            p.clones, p.clone_entries, f64(p.clone_entries) / max(f64(p.clones), 1))
        accounted: i64
        for ph in Style_Prof_Phase {
            accounted += p.ns[ph]
            fmt.eprintfln("   %-9v %8.1f ms  %5.1f%%", ph, ms(p.ns[ph]), 100 * f64(p.ns[ph]) / max(f64(p.total_ns), 1))
        }
        rest := p.total_ns - accounted
        fmt.eprintfln("   %-9s %8.1f ms  %5.1f%%  (cópias de Computed, resets, recursão)", "resto", ms(rest), 100 * f64(rest) / max(f64(p.total_ns), 1))
        Kv :: struct { k: string, v: int }
        top := make([dynamic]Kv, context.temp_allocator)
        tot := 0
        for k, v in g_style_prof_uni { append(&top, Kv{k, v}); tot += v }
        for i in 1 ..< len(top) {
            for j := i; j > 0 && top[j].v > top[j - 1].v; j -= 1 do top[j], top[j - 1] = top[j - 1], top[j]
        }
        fmt.eprintf("   balde universal (%d regras):", tot)
        for kv, i in top { if i >= 12 do break; fmt.eprintf(" %s=%d", kv.k, kv.v) }
        fmt.eprintfln("")
        fmt.eprintfln("   collect_decls por dentro (todos os passes): candidatos %.1f ms | inline %.1f ms | rollback %.1f ms | aliases+lógicas+shorthands %.1f ms",
            ms(p.coll_sub[0]), ms(p.coll_sub[1]), ms(p.coll_sub[2]), ms(p.coll_sub[3]))
        fmt.eprintfln("   candidatos por balde: universal %d | tag %d | id+classe %d | atributo %d",
            p.cand_from[0], p.cand_from[1], p.cand_from[2], p.cand_from[3])
        clear(&top)
        for k, v in g_style_prof_tags do append(&top, Kv{k, v})
        for i in 1 ..< len(top) {
            for j := i; j > 0 && top[j].v > top[j - 1].v; j -= 1 do top[j], top[j - 1] = top[j - 1], top[j]
        }
        fmt.eprintf("   candidatos de tag por tag:")
        for kv, i in top { if i >= 10 do break; fmt.eprintf(" %s=%d", kv.k, kv.v) }
        fmt.eprintfln("")
        clear(&g_style_prof_tags)
        Rk :: struct { ri: int, rc: Rule_Cost }
        rk := make([dynamic]Rk, context.temp_allocator)
        for ri, rc in g_style_prof_rules do append(&rk, Rk{ri, rc})
        for i in 1 ..< len(rk) {
            for j := i; j > 0 && rk[j].rc.ns > rk[j - 1].rc.ns; j -= 1 do rk[j], rk[j - 1] = rk[j - 1], rk[j]
        }
        fmt.eprintfln("   regras mais caras de casar:")
        for x, i in rk {
            if i >= 8 do break
            fmt.eprintfln("     %7.1f ms  %6d chamadas  %5d acertos  %.2f µs/chamada  %s",
                ms(x.rc.ns), x.rc.calls, x.rc.hits, f64(x.rc.ns) / 1e3 / max(f64(x.rc.calls), 1), x.rc.desc)
        }
        clear(&g_style_prof_rules)
        clear(&g_style_prof_uni)
        g_style_prof = {}
    }
}
