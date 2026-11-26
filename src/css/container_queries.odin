package css

import "core:strings"

Container_Axis :: enum { Width, Height, Inline, Block }
Container_Axes :: bit_set[Container_Axis]
Container_Feature :: enum { Unknown, Width, Height, Inline, Block, Ratio, Orientation }
Container_Op :: enum { Unknown, Feature, Not, And, Or }
Container_Compare :: enum { Lt, Le, Eq, Ge, Gt, Boolean }
Container_Node :: struct {
    op: Container_Op,
    left, right: int,
    feature: Container_Feature,
    cmp, cmp2: Container_Compare,
    value, value2: string,
}
Container_Query :: struct {
    name: string,
    nodes: []Container_Node,
    root: int,
    axes: Container_Axes,
    valid: bool,
    or_previous: bool, // another alternative in the same @container rule
}

container_name_valid :: proc(name: string) -> bool {
    if name == "" do return false
    l := Tokenizer{source = name}
    t := next_token(&l)
    if t.kind != .Name || t.end != len(name) do return false
    if name[0] >= '0' && name[0] <= '9' do return false
    if name[0] == '-' && (len(name) == 1 || (name[1] >= '0' && name[1] <= '9')) do return false
    switch strings.to_lower(name, context.temp_allocator) {
    case "none", "and", "or", "not", "default", "initial", "inherit", "unset", "revert", "revert-layer": return false
    }
    return true
}

@(private="file")
CQ_Parser :: struct { nodes: [dynamic]Container_Node, axes: Container_Axes, valid: bool }

@(private="file")
cq_emit :: proc(p: ^CQ_Parser, n: Container_Node) -> int {
    append(&p.nodes, n)
    return len(p.nodes)-1
}

@(private="file")
cq_feature :: proc(raw: string) -> Container_Feature {
    switch strings.to_lower(strings.trim_space(raw), context.temp_allocator) {
    case "width": return .Width
    case "height": return .Height
    case "inline-size": return .Inline
    case "block-size": return .Block
    case "aspect-ratio": return .Ratio
    case "orientation": return .Orientation
    }
    return .Unknown
}

@(private="file")
cq_flip :: proc(c: Container_Compare) -> Container_Compare {
    switch c { case .Lt: return .Gt; case .Le: return .Ge; case .Gt: return .Lt; case .Ge: return .Le; case .Eq, .Boolean: return c }
    return c
}

@(private="file")
cq_atom :: proc(p: ^CQ_Parser, s: string) -> int {
    n := Container_Node{op = .Feature, cmp = .Boolean}
    if colon := token_index_top(s, ':'); colon >= 0 {
        name := strings.to_lower(strings.trim_space(s[:colon]), context.temp_allocator)
        n.cmp = .Eq
        if strings.has_prefix(name, "min-") { name = name[4:]; n.cmp = .Ge }
        else if strings.has_prefix(name, "max-") { name = name[4:]; n.cmp = .Le }
        n.feature = cq_feature(name)
        n.value = strings.trim_space(s[colon+1:])
        if n.value == "" do n.feature = .Unknown
        if n.feature == .Orientation && n.cmp != .Eq do n.feature = .Unknown
    } else {
        pieces := make([dynamic]string, context.temp_allocator)
        comparisons := make([dynamic]Container_Compare, context.temp_allocator)
        l := Tokenizer{source = s}
        start := 0
        for {
            t := next_token(&l)
            if t.kind == .EOF do break
            if t.kind != .Delim do continue
            if token_close(t.delim) != 0 {
                end := token_group_end(s, t.start)
                if end < 0 { p.valid = false; break }
                l.pos = end+1; continue
            }
            if t.delim != '<' && t.delim != '>' && t.delim != '=' do continue
            append(&pieces, strings.trim_space(s[start:t.start]))
            cmp := t.delim == '<' ? Container_Compare.Lt : (t.delim == '>' ? Container_Compare.Gt : Container_Compare.Eq)
            if t.delim != '=' && l.pos < len(s) && s[l.pos] == '=' {
                cmp = cmp == .Lt ? .Le : .Ge
                l.pos += 1
            }
            append(&comparisons, cmp); start = l.pos
        }
        append(&pieces, strings.trim_space(s[start:]))
        switch len(comparisons) {
        case 0: n.feature = cq_feature(s)
        case 1:
            n.feature = cq_feature(pieces[0]); n.cmp = comparisons[0]; n.value = pieces[1]
            if n.feature == .Unknown {
                n.feature = cq_feature(pieces[1]); n.cmp = cq_flip(comparisons[0]); n.value = pieces[0]
            }
        case 2:
            n.feature = cq_feature(pieces[1]); n.cmp = cq_flip(comparisons[0]); n.value = pieces[0]
            n.cmp2 = comparisons[1]; n.value2 = pieces[2]
            a, b := comparisons[0], comparisons[1]
            if !(((a == .Lt || a == .Le) && (b == .Lt || b == .Le)) || ((a == .Gt || a == .Ge) && (b == .Gt || b == .Ge))) do n.feature = .Unknown
        case: n.feature = .Unknown
        }
        if len(comparisons) > 0 && (n.value == "" || n.feature == .Orientation) do n.feature = .Unknown
    }
    switch n.feature {
    case .Width: p.axes += {.Width}
    case .Height: p.axes += {.Height}
    case .Inline: p.axes += {.Inline}
    case .Block: p.axes += {.Block}
    case .Ratio, .Orientation: p.axes += {.Width, .Height}
    case .Unknown: n.op = .Unknown
    }
    return cq_emit(p, n)
}

@(private="file")
cq_primary :: proc(p: ^CQ_Parser, raw: string, depth: int) -> int {
    s := strings.trim_space(raw)
    if depth > 64 || s == "" { p.valid = false; return cq_emit(p, {}) }
    if s[0] == '(' {
        end := token_group_end(s, 0)
        if end != len(s)-1 { p.valid = false; return cq_emit(p, {}) }
        inner := strings.trim_space(s[1:end])
        if inner == "" { p.valid = false; return cq_emit(p, {}) }
        if inner[0] == '(' || token_find_top_keyword(inner, "not") == 0 || token_find_top_keyword(inner, "and") >= 0 || token_find_top_keyword(inner, "or") >= 0 {
            return cq_condition(p, inner, depth+1)
        }
        return cq_atom(p, inner)
    }
    // Unsupported query functions remain unknown under negation as well.
    open := strings.index_byte(s, '(')
    if open <= 0 || token_group_end(s, open) != len(s)-1 do p.valid = false
    return cq_emit(p, {})
}

@(private="file")
cq_condition :: proc(p: ^CQ_Parser, raw: string, depth: int) -> int {
    s := strings.trim_space(raw)
    if depth > 64 { p.valid = false; return cq_emit(p, {}) }
    ai, oi := token_find_top_keyword(s, "and"), token_find_top_keyword(s, "or")
    if ai >= 0 && oi >= 0 { p.valid = false; return cq_emit(p, {}) }
    if token_find_top_keyword(s, "not") == 0 {
        if ai >= 0 || oi >= 0 { p.valid = false; return cq_emit(p, {}) }
        child := cq_primary(p, s[3:], depth+1)
        return cq_emit(p, Container_Node{op = .Not, left = child})
    }
    if ai < 0 && oi < 0 do return cq_primary(p, s, depth+1)
    keyword := ai >= 0 ? "and" : "or"
    rest, result := s, -1
    for {
        at := token_find_top_keyword(rest, keyword)
        part := at < 0 ? rest : rest[:at]
        child := cq_primary(p, part, depth+1)
        if result < 0 { result = child }
        else { result = cq_emit(p, Container_Node{op = ai >= 0 ? .And : .Or, left = result, right = child}) }
        if at < 0 do break
        rest = rest[at+len(keyword):]
    }
    return result
}

// Temporary parsed form. Rules clone every string and the node array before
// retaining it; nested @container rules append, rather than replace, queries.
container_query_parse :: proc(raw: string) -> Container_Query {
    s := strings.trim_space(declaration_text(raw))
    name := ""
    l := Tokenizer{source = s}
    t := next_token(&l)
    if t.kind == .Name && (t.end == len(s) || s[t.end] != '(') && !strings.equal_fold(s[t.start:t.end], "not") {
        name = s[t.start:t.end]
        if !container_name_valid(name) do return Container_Query{}
        s = strings.trim_space(s[t.end:])
    }
    p := CQ_Parser{nodes = make([dynamic]Container_Node, context.temp_allocator), valid = tokens_balanced(s)}
    root := cq_condition(&p, s, 0)
    return Container_Query{name = name, nodes = p.nodes[:], root = root, axes = p.axes, valid = p.valid}
}

append_container_query :: proc(parent: Container_Q, prelude: string) -> Container_Q {
    alternatives := make([dynamic]Container_Query, context.temp_allocator)
    rest := declaration_text(prelude)
    valid := true
    for {
        at := token_index_top(rest, ',')
        part := at < 0 ? rest : rest[:at]
        q := container_query_parse(part)
        q.or_previous = len(alternatives) > 0
        append(&alternatives, q)
        valid = valid && q.valid
        if at < 0 do break
        rest = rest[at+1:]
    }
    if !valid do for &q in alternatives do q.valid = false
    list := make([]Container_Query, len(parent.queries)+len(alternatives), context.temp_allocator)
    copy(list, parent.queries); copy(list[len(parent.queries):], alternatives[:])
    // Preserve legacy metadata for diagnostics; matching uses the full tree.
    legacy := parse_container_query(prelude)
    return Container_Q{active = true, name = alternatives[0].name, min = legacy.min, max = legacy.max, queries = list}
}

clone_container_queries :: proc(queries: []Container_Query) -> []Container_Query {
    if len(queries) == 0 do return nil
    result := make([]Container_Query, len(queries))
    for q, i in queries {
        result[i] = q
        result[i].name = strings.clone(q.name)
        result[i].nodes = make([]Container_Node, len(q.nodes))
        copy(result[i].nodes, q.nodes)
        for &node in result[i].nodes {
            node.value = strings.clone(node.value); node.value2 = strings.clone(node.value2)
        }
    }
    return result
}

free_container_queries :: proc(queries: []Container_Query) {
    for q in queries {
        delete(q.name)
        for n in q.nodes { delete(n.value); delete(n.value2) }
        delete(q.nodes)
    }
    delete(queries)
}
