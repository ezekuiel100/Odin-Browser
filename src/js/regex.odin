package js

// Motor de expressões regulares (subconjunto do RegExp do JS) — M22.
//
// Backtracking VM ao estilo Russ Cox: o padrão é parseado numa AST e compilado
// para um programa de instruções (Char/Any/Class/Split/Jmp/Save/âncoras/Match).
// O casamento é recursivo com desfazimento (Save guarda/restaura no backtrack).
// Opera sobre code units sem u/v e code points com u/v; capturas usam UTF-16.
//
// Suporta: literais, `.`, classes `[...]` (ranges, negação, \d\w\s e negados),
// âncoras `^ $`, `\b \B`, quantificadores `* + ? {n} {n,} {n,m}` (greedy e lazy),
// grupos `(...)`, `(?:...)` e nomeados `(?<nome>...)` (exec devolve .groups),
// lookahead `(?=...)`/`(?!...)`, lookbehind `(?<=...)`/`(?<!...)`, backreferences
// `\1`-`\99` e `\k<nome>`, alternância `|`, escapes (\uNNNN \xNN \cX incl.),
// modificadores `(?i:...)`/`(?-i:...)`/`(?ms-i:...)` (ES2025).
// Flags: d (hasIndices) g i m s (dotAll) u v (unicodeSets) y (sticky).
//
// As flags i/m/s NÃO são do casamento inteiro: cada instrução carrega as suas
// (`mods`), gravadas no PARSE a partir das flags e dos modificadores em volta —
// é isso que deixa `(?i:a)b` casar "Ab" e não "AB".
//
// Flag v: classe com operações de CONJUNTO (`[\p{L}--[a-z]]`, `[\w&&\d]`),
// classes aninhadas e strings `\q{abc|de}`. A classe vira uma árvore (Re_CSet)
// avaliada por code point; candidatos de strings são tentados do mais longo
// ao mais curto sem expandir milhares de instruções. Propriedades Unicode,
// inclusive RGI_Emoji, usam unicode_tables_gen.odin (Unicode versionado).

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "core:sort"

REGEX_STEP_LIMIT :: 2_000_000 // trava contra backtracking catastrófico

Re_Op :: enum u8 { Char, Any, Class, Split, Jmp, Save, Clear, Match, Begin, End, WordB, NWordB, Look, BackRef }

Re_Range :: struct { lo, hi: rune }

// Flags com escopo (i/m/s), por instrução — ver o cabeçalho.
Re_Mod :: enum u8 { I, M, S }
Re_Mods :: bit_set[Re_Mod; u8]

// Classe da flag v: árvore de operações de conjunto. Folha = ranges/props/nranges
// de um Re_Inst .Class (mesma semântica da classe comum) + as strings de `\q{}`
// com tamanho ≠ 1 (as de 1 char entram nos ranges).
Re_CSet_Op :: enum u8 { Leaf, Union, Inter, Sub }

Re_CSet :: struct {
    op:      Re_CSet_Op,
    negate:  bool,        // [^...] (só sem strings — a spec proíbe negar strings)
    leaf:    Re_Inst,     // .Leaf: ranges/nranges/props/negate
    strs:    [dynamic][]rune, // .Leaf: strings de \q{} com len ≠ 1
    kids:    [dynamic]^Re_CSet,
}

Re_Inst :: struct {
    op:     Re_Op,
    mods:   Re_Mods,      // i/m/s em vigor nesta instrução (Char/Class/BackRef/Any/Begin/End)
    set:    ^Re_CSet,     // Class da flag v (nil nas classes comuns); owned pela instrução
    strings: [][]rune,    // candidatos por tamanho; referenciam strings owned pelo set
    refs:   []int,       // Named backreference candidates (owned).
    ch:     rune,         // Char
    x, y:   int,          // Split (x,y) / Jmp (x) / Save (x = slot) / BackRef (x = grupo)
    ranges: []Re_Range,   // Class: conjuntos POSITIVOS (c casa se estiver em algum)
    props:  []Re_Prop,    // Class: categorias Unicode de \p{...} (c casa se satisfizer alguma)
    nranges: []Re_Range,  // Class: atalhos NEGADOS dentro da classe (\S \D \W) —
                          // c casa se NÃO estiver neles ([\s\S] = tudo)
    negate: bool,         // Class ([^...]) / Look ((?!...)): inverte o resultado
    behind: bool,         // Look: é lookBEHIND ((?<=...)/(?<!...))? (casa p/ trás)
    sub:    []Re_Inst,    // Look: subprograma do look (termina em Match)
}

Regex :: struct {
    source:    string, // padrão (owned pelo vm)
    flags:     string, // ex.: "gi" (owned)
    global:    bool,
    icase:     bool,
    multiline: bool,
    dotall:    bool,   // flag s: `.` casa também `\n`
    sticky:    bool,   // flag y: casamento ANCORADO em lastIndex (sem varredura)
    has_indices: bool, // flag d: exec devolve .indices ([início, fim] por grupo)
    unicode:   bool,   // flag u
    unicode_sets: bool, // flag v
    prog:      []Re_Inst,
    ngroups:   int,     // grupos capturantes (sem o grupo 0)
    last_index: int,    // usado por exec/test com a flag g
    gnames:    map[string][]int, // Owned name -> capture indices in source order.
    props:     map[string]Value, // expandos da instância (chave clonada); nil até a 1ª
}

// ── AST ─────────────────────────────────────────────────────────────────────

@(private="file")
Re_Kind :: enum {
    Char, Any, Class, Concat, Alt, Star, Plus, Quest, Repeat, Group,
    Begin, End, WordB, NWordB, Empty,
    Look,    // lookahead (?=...)/(?!...) — negate marca o negativo; kids[0] = sub
    BackRef, // \1..\99 / \k<nome> — group = índice do grupo referenciado
}

@(private="file")
// ── property escapes `\p{...}` / `\P{...}` ───────────────────────────────────
// Uma categoria Unicode não cabe em ranges (seriam milhares), então a classe
// carrega PREDICADOS ao lado dos ranges e o matcher os consulta. As tabelas vêm
// do `core:unicode` do Odin — geradas do UCD, não escritas à mão aqui.
Re_Prop :: struct {
    id: int,
    negate: bool,
    fold_before_negation: bool, // v complements the case-folded property; u folds its complement.
}

Re_Node :: struct {
    kind:   Re_Kind,
    ch:     rune,
    ranges: [dynamic]Re_Range, negate: bool,
    props:  [dynamic]Re_Prop, // Class: categorias de \p{...}/\P{...} (nil até a 1ª)
    behind: bool, // Look: é lookbehind?
    nranges: [dynamic]Re_Range, // Class: atalhos negados dentro da classe (ver Re_Inst)
    kids:   [dynamic]^Re_Node,
    mods:   Re_Mods,  // i/m/s em vigor onde o nó foi parseado
    set:    ^Re_CSet, // Class da flag v (owned pelo nó; a compilação CLONA)
    greedy: bool,
    gmin, gmax: int, // Repeat: gmax = -1 => infinito
    name:   string,  // Group name or unresolved named backreference (temp).
    refs:   []int,
    group:  int,     // Group: índice (>0 capturante; 0 não-capturante)
}

@(private="file")
re_new :: proc(k: Re_Kind) -> ^Re_Node {
    n := new(Re_Node)
    n.kind = k
    n.greedy = true
    return n
}

@(private="file")
re_free :: proc(n: ^Re_Node) {
    if n == nil do return
    for k in n.kids do re_free(k)
    delete(n.kids)
    delete(n.ranges)
    delete(n.nranges)
    delete(n.props)
    if n.set != nil do cset_free(n.set)
    free(n)
}

@(private="file")
cset_free :: proc(s: ^Re_CSet) {
    if s == nil do return
    for k in s.kids do cset_free(k)
    delete(s.kids)
    for st in s.strs do delete(st)
    delete(s.strs)
    delete(s.leaf.ranges); delete(s.leaf.nranges); delete(s.leaf.props)
    free(s)
}

@(private="file")
cset_clone :: proc(s: ^Re_CSet) -> ^Re_CSet {
    c := new(Re_CSet)
    c.op = s.op
    c.negate = s.negate
    c.leaf.negate = s.leaf.negate
    if len(s.leaf.ranges) > 0  { c.leaf.ranges = make([]Re_Range, len(s.leaf.ranges)); copy(c.leaf.ranges, s.leaf.ranges) }
    if len(s.leaf.nranges) > 0 { c.leaf.nranges = make([]Re_Range, len(s.leaf.nranges)); copy(c.leaf.nranges, s.leaf.nranges) }
    if len(s.leaf.props) > 0   { c.leaf.props = make([]Re_Prop, len(s.leaf.props)); copy(c.leaf.props, s.leaf.props) }
    for st in s.strs {
        d := make([]rune, len(st)); copy(d, st)
        append(&c.strs, d)
    }
    for k in s.kids do append(&c.kids, cset_clone(k))
    return c
}

@(private="file")
Re_Parser :: struct {
    pat: []rune, pos: int, ngroup: int, ok: bool,
    names: map[string][dynamic]int, // grupos nomeados vistos (chaves em temp; nil até o 1º)
    unicode: bool,         // flag `u`: habilita `\u{XXXXX}` (code point por extenso).
                           // SEM a flag, `\u{2}` é a spec dizendo "u repetido 2 vezes",
                           // então a forma com chaves só pode ser lida quando ela está
                           // presente — do contrário mudaríamos o sentido de padrões
                           // legítimos que hoje funcionam. A flag `v` também liga.
    vmode: bool,           // flag `v`: sintaxe de classe de CONJUNTO (re_parse_vclass)
    mods:  Re_Mods,        // i/m/s em vigor no ponto do parse (flags + modificadores)
    spec_err: bool,        // erro de uma gramática implementada À RISCA (modificadores,
                           // classe da v): pode virar early error do literal — ver
                           // regex_early_error. Os demais `ok = false` não marcam.
}

// Nó novo carimbado com os modificadores em vigor (o compilador os copia para a
// instrução). Todo nó criado pelo PARSER passa por aqui.
@(private="file")
rp_new :: proc(p: ^Re_Parser, k: Re_Kind) -> ^Re_Node {
    n := re_new(k)
    n.mods = p.mods
    return n
}

@(private="file")
rp_peek :: proc(p: ^Re_Parser) -> rune { return p.pos < len(p.pat) ? p.pat[p.pos] : -1 }
@(private="file")
rp_next :: proc(p: ^Re_Parser) -> rune { c := p.pat[p.pos]; p.pos += 1; return c }
@(private="file")
rp_eof :: proc(p: ^Re_Parser) -> bool { return p.pos >= len(p.pat) }

// alt := concat ('|' concat)*
@(private="file")
re_parse_alt :: proc(p: ^Re_Parser) -> ^Re_Node {
    first := re_parse_concat(p)
    if rp_peek(p) != '|' do return first
    alt := rp_new(p, .Alt)
    append(&alt.kids, first)
    for rp_peek(p) == '|' {
        rp_next(p)
        append(&alt.kids, re_parse_concat(p))
    }
    return alt
}

// concat := quant*
@(private="file")
re_parse_concat :: proc(p: ^Re_Parser) -> ^Re_Node {
    con := rp_new(p, .Concat)
    for !rp_eof(p) && rp_peek(p) != '|' && rp_peek(p) != ')' {
        append(&con.kids, re_parse_quant(p))
    }
    if len(con.kids) == 0 { con.kind = .Empty }
    return con
}

// quant := atom ('*' | '+' | '?' | '{n,m}')? '?'?
@(private="file")
re_parse_quant :: proc(p: ^Re_Parser) -> ^Re_Node {
    atom := re_parse_atom(p)
    c := rp_peek(p)
    wrap: ^Re_Node
    switch c {
    case '*': rp_next(p); wrap = rp_new(p, .Star)
    case '+': rp_next(p); wrap = rp_new(p, .Plus)
    case '?': rp_next(p); wrap = rp_new(p, .Quest)
    case '{':
        if rep, ok := re_try_parse_repeat(p); ok {
            wrap = rep
        }
    }
    if wrap == nil do return atom
    append(&wrap.kids, atom)
    if rp_peek(p) == '?' { rp_next(p); wrap.greedy = false } // lazy
    return wrap
}

// {n} {n,} {n,m} — devolve nó Repeat ou (nil,false) se não for repetição válida
@(private="file")
re_try_parse_repeat :: proc(p: ^Re_Parser) -> (^Re_Node, bool) {
    save := p.pos
    rp_next(p) // {
    lo, has_lo := re_parse_int(p)
    if !has_lo { p.pos = save; return nil, false }
    hi := lo
    if rp_peek(p) == ',' {
        rp_next(p)
        if v, ok := re_parse_int(p); ok { hi = v } else { hi = -1 } // {n,} => infinito
    }
    if rp_peek(p) != '}' { p.pos = save; return nil, false }
    rp_next(p) // }
    rep := rp_new(p, .Repeat)
    rep.gmin = lo; rep.gmax = hi
    return rep, true
}

@(private="file")
re_parse_int :: proc(p: ^Re_Parser) -> (int, bool) {
    start := p.pos
    v := 0
    for !rp_eof(p) && p.pat[p.pos] >= '0' && p.pat[p.pos] <= '9' {
        v = v*10 + int(p.pat[p.pos] - '0'); p.pos += 1
    }
    return v, p.pos > start
}

@(private="file")
re_parse_atom :: proc(p: ^Re_Parser) -> ^Re_Node {
    c := rp_peek(p)
    switch c {
    case '(':
        rp_next(p)
        capturing := true
        gname := ""
        if rp_peek(p) == '?' {
            nx := p.pos+1 < len(p.pat) ? p.pat[p.pos+1] : -1
            switch nx {
            case ':':
                rp_next(p); rp_next(p) // ?:
                capturing = false
            case '=', '!':
                rp_next(p); rp_next(p) // ?= ou ?!
                lk := rp_new(p, .Look)
                lk.negate = nx == '!'
                inner := re_parse_alt(p)
                if rp_peek(p) == ')' do rp_next(p)
                append(&lk.kids, inner)
                return lk
            case '<':
                nx2 := p.pos+2 < len(p.pat) ? p.pat[p.pos+2] : -1
                if nx2 == '=' || nx2 == '!' { // lookBEHIND (?<=...)/(?<!...)
                    rp_next(p); rp_next(p); rp_next(p) // ? < = / ? < !
                    lb := rp_new(p, .Look)
                    lb.negate = nx2 == '!'
                    lb.behind = true
                    inner := re_parse_alt(p)
                    if rp_peek(p) == ')' do rp_next(p)
                    append(&lb.kids, inner)
                    return lb
                }
                // grupo nomeado (?<nome>...)
                rp_next(p); rp_next(p) // ? <
                gname = re_parse_group_name(p)
            case 'i', 'm', 's', '-':
                // modificadores (?ims-ims:...) — grupo NÃO capturante cujo corpo é
                // parseado com as flags ajustadas; fora dele valem as de antes.
                rp_next(p) // ?
                add, rem, ok := re_parse_modifiers(p)
                if !ok { p.ok = false; p.spec_err = true; return rp_new(p, .Empty) }
                saved := p.mods
                p.mods = (p.mods | add) - rem
                g := rp_new(p, .Group) // group = 0: não capturante
                inner := re_parse_alt(p)
                if rp_peek(p) == ')' do rp_next(p)
                append(&g.kids, inner)
                p.mods = saved
                return g
            case:
                // (?X desconhecido → SyntaxError em qualquer modo (nem a Annex B
                // aceita), então vale como early error do literal também
                p.ok = false
                p.spec_err = true
            }
        }
        g := rp_new(p, .Group)
        if capturing { p.ngroup += 1; g.group = p.ngroup } else { g.group = 0 }
        if gname != "" {
            g.name = gname
            if p.names == nil do p.names = make(map[string][dynamic]int)
            ids := p.names[gname]
            if ids == nil do ids = make([dynamic]int, context.temp_allocator)
            append(&ids, g.group)
            p.names[gname] = ids
        }
        inner := re_parse_alt(p)
        if rp_peek(p) == ')' do rp_next(p)
        append(&g.kids, inner)
        return g
    case '[':
        return re_parse_class(p)
    case '.':
        rp_next(p); return rp_new(p, .Any)
    case '^':
        rp_next(p); return rp_new(p, .Begin)
    case '$':
        rp_next(p); return rp_new(p, .End)
    case '\\':
        rp_next(p)
        return re_parse_escape(p)
    case:
        rp_next(p)
        n := rp_new(p, .Char); n.ch = c
        return n
    }
}

// Lê `ims-ims:` logo depois de `(?` (o `:` é consumido). Erros da spec (early
// errors de RegularExpressionModifiers): letra fora de i/m/s, letra repetida
// (inclusive entre os dois lados, `(?i-i:`), `(?-:` com os dois lados vazios, e a
// forma sem `:` (`(?i)` do PCRE não existe em JS).
@(private="file")
re_parse_modifiers :: proc(p: ^Re_Parser) -> (add, rem: Re_Mods, ok: bool) {
    seen: Re_Mods
    dash := false
    for !rp_eof(p) {
        c := rp_next(p)
        m: Re_Mod
        switch c {
        case ':':
            if dash && add == {} && rem == {} do return {}, {}, false
            return add, rem, true
        case '-':
            if dash do return {}, {}, false
            dash = true
            continue
        case 'i': m = .I
        case 'm': m = .M
        case 's': m = .S
        case: return {}, {}, false
        }
        if m in seen do return {}, {}, false
        seen += {m}
        if dash { rem += {m} } else { add += {m} }
    }
    return {}, {}, false
}

// Group names use Unicode escapes even without u/v. Decode before comparing.
@(private="file")
re_parse_group_name :: proc(p: ^Re_Parser) -> string {
    nb := strings.builder_make(context.temp_allocator)
    for !rp_eof(p) && rp_peek(p) != '>' {
        c := rp_next(p)
        if c == '\\' {
            if rp_peek(p) != 'u' { p.ok = false; p.spec_err = true; break }
            rp_next(p)
            saved := p.unicode
            p.unicode = true
            c = rp_hex_escape(p, 'u')
            p.unicode = saved
        }
        strings.write_rune(&nb, c)
    }
    name := strings.to_string(nb)
    if rp_peek(p) == '>' { rp_next(p) }
    else { p.ok = false; p.spec_err = true }
    if name == "" { p.ok = false; p.spec_err = true }
    return name
}

// Read hex escapes. Unicode mode rejects malformed escapes; legacy mode
// retains Annex B identity escapes. Braced code points range through U+10FFFF.
@(private="file")
rp_hex_escape :: proc(p: ^Re_Parser, kind: rune) -> rune {
    if kind == 'u' && p.unicode && p.pos < len(p.pat) && p.pat[p.pos] == '{' {
        j := p.pos + 1
        v := 0
        ndig := 0
        for j < len(p.pat) && p.pat[j] != '}' {
            d := rp_hex_digit(p.pat[j])
            // Bound before multiplication; leading zeroes have no length limit.
            if d < 0 || v > (0x10FFFF-d)/16 {
                p.ok = false; p.spec_err = true
                return kind
            }
            v = v*16 + d
            ndig += 1
            j += 1
        }
        // precisa fechar, ter ao menos 1 dígito e caber no espaço de code points
        if j >= len(p.pat) || ndig == 0 {
            p.ok = false; p.spec_err = true
            return kind
        }
        p.pos = j + 1 // consome o '}'
        return rune(v)
    }
    n := kind == 'u' ? 4 : 2
    if p.pos + n > len(p.pat) {
        if p.unicode { p.ok = false; p.spec_err = true }
        return kind
    }
    v := 0
    for k in 0 ..< n {
        d := rp_hex_digit(p.pat[p.pos + k])
        if d < 0 {
            if p.unicode { p.ok = false; p.spec_err = true }
            return kind
        }
        v = v * 16 + d
    }
    p.pos += n
    if kind == 'u' && p.unicode && v >= 0xD800 && v <= 0xDBFF &&
       p.pos+6 <= len(p.pat) && p.pat[p.pos] == '\\' && p.pat[p.pos+1] == 'u' {
        save := p.pos
        p.pos += 2
        lo := rp_hex_escape(p, 'u')
        if lo >= 0xDC00 && lo <= 0xDFFF { return rune(0x10000 + ((v-0xD800) << 10) + int(lo)-0xDC00) }
        p.pos = save
    }
    return rune(v)
}

// Property names and aliases are exact, case-sensitive ECMAScript spellings.
// Invalid properties are syntax errors, including in literals (before execution).
@(private="file")
re_parse_prop :: proc(p: ^Re_Parser, negated: bool) -> (prop: Re_Prop, ok: bool) {
    prop.id = -1
    if p.pos < len(p.pat) && p.pat[p.pos] == '{' {
        start := p.pos + 1
        j := start
        for j < len(p.pat) && p.pat[j] != '}' do j += 1
        if j < len(p.pat) {
            name := utf8.runes_to_string(p.pat[start:j], context.temp_allocator)
            p.pos = j+1
            id := re_unicode_lookup(name)
            if id >= 0 {
                data := RE_UNICODE_PROPERTIES[id]
                if !data.strings || (p.vmode && !negated) {
                    return Re_Prop{id = id, negate = negated, fold_before_negation = p.vmode}, true
                }
            }
        }
    }
    p.ok = false
    p.spec_err = true
    return prop, false
}

@(private="file")
re_prop_match :: proc(id: int, c: rune) -> bool {
    if id < 0 || c < 0 || c > 0x10FFFF do return false
    data := RE_UNICODE_PROPERTIES[id]
    lo, hi := data.start, data.start + data.count
    for lo < hi {
        mid := lo + (hi-lo)/2
        r := RE_UNICODE_RANGES[mid]
        if c < r.lo { hi = mid } else if c > r.hi { lo = mid+1 } else { return true }
    }
    return false
}

@(private="file")
re_property_set :: proc(pr: Re_Prop) -> ^Re_CSet {
    leaf := new(Re_CSet)
    leaf.op = .Leaf
    leaf.leaf.props = make([]Re_Prop, 1)
    leaf.leaf.props[0] = pr
    data := RE_UNICODE_PROPERTIES[pr.id]
    for str in RE_UNICODE_STRINGS[data.string_start:][:data.string_count] {
        chars := js_string_chars(str, true)
        copy_of_chars := make([]rune, len(chars))
        copy(copy_of_chars, chars)
        append(&leaf.strs, copy_of_chars)
    }
    return leaf
}

// Valor de um dígito hexadecimal, ou -1 se não for um.
@(private="file")
rp_hex_digit :: proc(c: rune) -> int {
    switch {
    case c >= '0' && c <= '9': return int(c - '0')
    case c >= 'a' && c <= 'f': return int(c - 'a') + 10
    case c >= 'A' && c <= 'F': return int(c - 'A') + 10
    }
    return -1
}

// Escape fora de classe: \d \w \s (e negados) viram Class; \b \B âncoras;
// \uNNNN/\xNN viram o char; resto literal.
@(private="file")
re_parse_escape :: proc(p: ^Re_Parser) -> ^Re_Node {
    if rp_eof(p) { n := rp_new(p, .Char); n.ch = '\\'; return n }
    c := rp_next(p)
    switch c {
    case 'd', 'D', 'w', 'W', 's', 'S':
        n := rp_new(p, .Class)
        re_add_class_shorthand(n, c)
        return n
    case 'b': return rp_new(p, .WordB)
    case 'B': return rp_new(p, .NWordB)
    case 'p', 'P':
        // property escape — só COM a flag `u` (sem ela, `\p` é o literal 'p', que
        // é o que a spec manda e o que este motor já fazia).
        if p.unicode {
            if pr, ok := re_parse_prop(p, c == 'P'); ok {
                n := rp_new(p, .Class)
                if RE_UNICODE_PROPERTIES[pr.id].strings { n.set = re_property_set(pr) }
                else { append(&n.props, pr) }
                return n
            }
        }
        n := rp_new(p, .Char); n.ch = c
        return n
    case 'u', 'x':
        n := rp_new(p, .Char); n.ch = rp_hex_escape(p, c)
        return n
    case 'c':
        // \cX: controle (letra % 32). Sem letra, a Annex B manda ler `\` literal e
        // deixar o `c` para o próximo átomo.
        n := rp_new(p, .Char)
        if pk := rp_peek(p); (pk >= 'a' && pk <= 'z') || (pk >= 'A' && pk <= 'Z') {
            n.ch = rp_next(p) % 32
        } else {
            p.pos -= 1
            n.ch = '\\'
        }
        return n
    case '1'..='9':
        // backreference \1..\99 (2º dígito só se o grupo existir até aqui)
        idx := int(c - '0')
        if !rp_eof(p) && rp_peek(p) >= '0' && rp_peek(p) <= '9' && idx*10 + int(rp_peek(p)-'0') <= p.ngroup {
            idx = idx*10 + int(rp_next(p) - '0')
        }
        n := rp_new(p, .BackRef); n.group = idx
        return n
    case 'k':
        // Named references are resolved after parsing, including forward references.
        if rp_peek(p) == '<' {
            rp_next(p)
            name := re_parse_group_name(p)
            n := rp_new(p, .BackRef)
            n.name = name
            return n
        }
        n := rp_new(p, .Char); n.ch = 'k'
        return n
    case:
        n := rp_new(p, .Char); n.ch = re_escape_char(c)
        return n
    }
}

// \n \t \r \0 \f \v; \uXXXX; \xHH; senão o próprio char (\. \/ \\ etc.)
@(private="file")
re_escape_char :: proc(c: rune) -> rune {
    switch c {
    case 'n': return '\n'
    case 't': return '\t'
    case 'r': return '\r'
    case 'f': return '\f'
    case 'v': return '\v'
    case '0': return 0
    }
    return c
}

// Adiciona os ranges de um atalho de classe (\d etc.) ao nó, marcando negate.
@(private="file")
re_add_class_shorthand :: proc(n: ^Re_Node, c: rune) {
    switch c {
    case 'd': append(&n.ranges, Re_Range{'0','9'})
    case 'D': append(&n.ranges, Re_Range{'0','9'}); n.negate = true
    case 'w':
        append(&n.ranges, Re_Range{'a','z'}, Re_Range{'A','Z'}, Re_Range{'0','9'}, Re_Range{'_','_'})
    case 'W':
        append(&n.ranges, Re_Range{'a','z'}, Re_Range{'A','Z'}, Re_Range{'0','9'}, Re_Range{'_','_'}); n.negate = true
    case 's':
        append(&n.ranges, Re_Range{' ',' '}, Re_Range{'\t','\t'}, Re_Range{'\n','\n'}, Re_Range{'\r','\r'}, Re_Range{'\f','\f'}, Re_Range{'\v','\v'})
    case 'S':
        append(&n.ranges, Re_Range{' ',' '}, Re_Range{'\t','\t'}, Re_Range{'\n','\n'}, Re_Range{'\r','\r'}, Re_Range{'\f','\f'}, Re_Range{'\v','\v'}); n.negate = true
    }
}

// [abc] [a-z] [^...] [\d\s-]  — os atalhos dentro de classe adicionam ranges.
@(private="file")
re_parse_class :: proc(p: ^Re_Parser) -> ^Re_Node {
    if p.vmode do return re_parse_vclass_node(p)
    rp_next(p) // [
    n := rp_new(p, .Class)
    if rp_peek(p) == '^' { rp_next(p); n.negate = true }
    for !rp_eof(p) && rp_peek(p) != ']' {
        lo := rp_next(p)
        if lo == '\\' && !rp_eof(p) {
            e := rp_next(p)
            switch e {
            case 'd','w','s':
                // atalho positivo dentro da classe: mescla os ranges
                tmp := rp_new(p, .Class); re_add_class_shorthand(tmp, e)
                for r in tmp.ranges do append(&n.ranges, r)
                re_free(tmp)
                continue
            case 'D','W','S':
                // atalho NEGADO dentro da classe: vai p/ nranges — o char casa
                // se NÃO estiver nesses ranges ([\s\S] = qualquer char, o idioma
                // clássico de "qualquer coisa inclusive \n" que minifiers usam)
                tmp := rp_new(p, .Class); re_add_class_shorthand(tmp, e + ('a' - 'A'))
                for r in tmp.ranges do append(&n.nranges, r)
                re_free(tmp)
                continue
            case 'p', 'P':
                // \p{...} DENTRO da classe: soma o predicado ao mesmo nó
                if p.unicode {
                    if pr, ok := re_parse_prop(p, e == 'P'); ok {
                        append(&n.props, pr)
                        continue
                    }
                }
                lo = e // sem flag `u` (ou sem chaves): literal 'p'/'P'
            case 'u', 'x':
                lo = rp_hex_escape(p, e)
            case 'b':
                lo = 0x08 // dentro de classe `\b` é BACKSPACE, não fronteira
            case 'c':
                // \cX; dentro de classe a Annex B aceita também dígito e `_`
                if pk := rp_peek(p); (pk >= 'a' && pk <= 'z') || (pk >= 'A' && pk <= 'Z') || (pk >= '0' && pk <= '9') || pk == '_' {
                    lo = rp_next(p) % 32
                } else {
                    p.pos -= 1
                    lo = '\\'
                }
            case: lo = re_escape_char(e)
            }
        }
        // range a-z (se houver '-' seguido de algo que não seja ']')
        if rp_peek(p) == '-' && p.pos+1 < len(p.pat) && p.pat[p.pos+1] != ']' {
            rp_next(p) // -
            hi := rp_next(p)
            if hi == '\\' && !rp_eof(p) {
                eh := rp_next(p)
                hi = (eh == 'u' || eh == 'x') ? rp_hex_escape(p, eh) : re_escape_char(eh)
            }
            append(&n.ranges, Re_Range{lo, hi})
        } else {
            append(&n.ranges, Re_Range{lo, lo})
        }
    }
    if rp_peek(p) == ']' do rp_next(p)
    return n
}

// ── classe da flag v (ClassSetExpression) ───────────────────────────────────
//
// Gramática (spec 22.2.1): dentro de `[...]` vem UMA destas formas, sem misturar:
//   união        `[ab\d[x-z]]`        operandos e ranges lado a lado
//   interseção   `[A&&B&&C]`          operandos sem range
//   subtração    `[A--B--C]`          idem
// Operando = char, `[...]` aninhada, `\q{a|bc}`, `\d \w \s` (e negados), `\p{}`.
// Na v, `( ) [ ] { } / - |` soltos e pontuação DOBRADA (`&& !! ## ...` fora da
// posição de operador) são SyntaxError — é o que libera esses símbolos para
// virarem operadores no futuro, e o que a spec manda rejeitar.

@(private="file")
re_parse_vclass_node :: proc(p: ^Re_Parser) -> ^Re_Node {
    n := rp_new(p, .Class)
    was := p.ok
    n.set = re_parse_vclass(p)
    if was && !p.ok do p.spec_err = true
    return n
}

// `[` ... `]` (consome os dois). Nunca devolve nil; erro marca p.ok = false.
@(private="file")
re_parse_vclass :: proc(p: ^Re_Parser) -> ^Re_CSet {
    rp_next(p) // [
    root := new(Re_CSet)
    root.op = .Union
    if rp_peek(p) == '^' { rp_next(p); root.negate = true }
    nops := 0
    last_range := false
    for p.ok {
        if rp_eof(p) { p.ok = false; break }
        if rp_peek(p) == ']' { rp_next(p); break }
        nx := p.pos+1 < len(p.pat) ? p.pat[p.pos+1] : -1
        c := rp_peek(p)
        if (c == '&' && nx == '&') || (c == '-' && nx == '-') {
            this_op: Re_CSet_Op = c == '&' ? .Inter : .Sub
            // operador precisa de UM operando sem range à esquerda (`[ab&&c]` e
            // `[a-z--b]` misturam formas) e não pode trocar de operador no meio
            if nops == 0 || last_range { p.ok = false; break }
            if root.op == .Union {
                if nops != 1 { p.ok = false; break }
                root.op = this_op
            } else if root.op != this_op { p.ok = false; break }
            p.pos += 2
            if this_op == .Inter && rp_peek(p) == '&' { p.ok = false; break } // `&&&`
            k, is_range := re_parse_vclass_operand(p, false)
            append(&root.kids, k)
            if is_range { p.ok = false; break }
            nops += 1
            continue
        }
        // depois de `A&&B` só cabe outro operador ou o `]`
        if root.op != .Union { p.ok = false; break }
        k, is_range := re_parse_vclass_operand(p, true)
        append(&root.kids, k)
        nops += 1
        last_range = is_range
    }
    // classe negada não pode conter strings (spec: MayContainStrings → SyntaxError)
    if root.negate && cset_may_contain_strings(root) do p.ok = false
    return root
}

// Um operando. `allow_range`: na união, `a-z` vale; na interseção/subtração não.
@(private="file")
re_parse_vclass_operand :: proc(p: ^Re_Parser, allow_range: bool) -> (^Re_CSet, bool) {
    leaf := new(Re_CSet)
    leaf.op = .Leaf
    if rp_eof(p) { p.ok = false; return leaf, false }
    c := rp_peek(p)
    if c == '[' {
        free(leaf)
        return re_parse_vclass(p), false
    }
    if c == '\\' && p.pos+1 < len(p.pat) {
        e := p.pat[p.pos+1]
        switch e {
        case 'd', 'D', 'w', 'W', 's', 'S':
            p.pos += 2
            tmp := re_new(.Class)
            re_add_class_shorthand(tmp, e)
            leaf.leaf.ranges = make([]Re_Range, len(tmp.ranges))
            copy(leaf.leaf.ranges, tmp.ranges[:])
            leaf.leaf.negate = tmp.negate
            re_free(tmp)
            return leaf, false
        case 'p', 'P':
            p.pos += 2
            pr, ok := re_parse_prop(p, e == 'P')
            if !ok { p.ok = false; return leaf, false } // na v, `\p` sem `{}` é erro
            free(leaf)
            return re_property_set(pr), false
        case 'q':
            p.pos += 2
            re_parse_class_strings(p, leaf)
            return leaf, false
        }
    }
    lo, ok := re_vclass_char(p)
    if !ok do return leaf, false
    hi := lo
    is_range := false
    if allow_range && rp_peek(p) == '-' && !(p.pos+1 < len(p.pat) && p.pat[p.pos+1] == '-') {
        rp_next(p) // -
        hi, ok = re_vclass_char(p)
        if !ok do return leaf, false
        if hi < lo { p.ok = false; return leaf, false } // `[z-a]`: fora de ordem
        is_range = true
    }
    leaf.leaf.ranges = make([]Re_Range, 1)
    leaf.leaf.ranges[0] = Re_Range{lo, hi}
    return leaf, is_range
}

// `\q{abc|d|}` (o `\q` já consumido): cada alternativa é uma string; as de 1 char
// entram como char comum, as outras (inclusive a vazia) vão para `strs`.
@(private="file")
re_parse_class_strings :: proc(p: ^Re_Parser, leaf: ^Re_CSet) {
    if rp_peek(p) != '{' { p.ok = false; return }
    rp_next(p)
    singles := make([dynamic]Re_Range)
    cur := make([dynamic]rune, context.temp_allocator)
    flush :: proc(leaf: ^Re_CSet, singles: ^[dynamic]Re_Range, cur: ^[dynamic]rune) {
        if len(cur) == 1 {
            append(singles, Re_Range{cur[0], cur[0]})
        } else {
            s := make([]rune, len(cur)); copy(s, cur[:])
            append(&leaf.strs, s)
        }
        clear(cur)
    }
    for p.ok {
        if rp_eof(p) { p.ok = false; break }
        c := rp_peek(p)
        if c == '}' { rp_next(p); flush(leaf, &singles, &cur); break }
        if c == '|' { rp_next(p); flush(leaf, &singles, &cur); continue }
        ch, ok := re_vclass_char(p)
        if !ok do break
        append(&cur, ch)
    }
    leaf.leaf.ranges = singles[:]
}

// Um ClassSetCharacter (char solto ou escape de 1 char), consumido. Erros da spec
// marcam p.ok = false.
@(private="file")
re_vclass_char :: proc(p: ^Re_Parser) -> (rune, bool) {
    if rp_eof(p) { p.ok = false; return 0, false }
    c := rp_next(p)
    if c == '\\' {
        if rp_eof(p) { p.ok = false; return 0, false }
        e := rp_next(p)
        switch e {
        case 'u', 'x': return rp_hex_escape(p, e), true
        case 'b': return 0x08, true
        case 'n', 't', 'r', 'f', 'v': return re_escape_char(e), true
        case 'c':
            if pk := rp_peek(p); (pk >= 'a' && pk <= 'z') || (pk >= 'A' && pk <= 'Z') do return rp_next(p) % 32, true
        case '0':
            if pk := rp_peek(p); !(pk >= '0' && pk <= '9') do return 0, true
        case:
            // IdentityEscape da v: SyntaxCharacter, `/` e ClassSetReservedPunctuator
            if strings.contains_rune("^$\\.*+?()[]{}|/&-!#%,:;<=>@`~", e) do return e, true
        }
        p.ok = false
        return 0, false
    }
    switch c {
    case '(', ')', '[', ']', '{', '}', '/', '-', '|':
        p.ok = false
        return 0, false
    }
    // ClassSetReservedDoublePunctuator: `!!`, `##`, `$$`, ... são reservados
    if strings.contains_rune("&!#$%*+,.:;<=>?@^`~", c) && rp_peek(p) == c {
        p.ok = false
        return 0, false
    }
    return c, true
}

// MayContainStrings da spec (sintático): união = algum, interseção = todos,
// subtração = o primeiro operando.
@(private="file")
cset_may_contain_strings :: proc(s: ^Re_CSet) -> bool {
    switch s.op {
    case .Leaf: return len(s.strs) > 0
    case .Union:
        for k in s.kids do if cset_may_contain_strings(k) do return true
        return false
    case .Inter:
        if len(s.kids) == 0 do return false
        for k in s.kids do if !cset_may_contain_strings(k) do return false
        return true
    case .Sub:
        return len(s.kids) > 0 && cset_may_contain_strings(s.kids[0])
    }
    return false
}

// O code point `c` está no conjunto? A folha usa a MESMA checagem da classe comum
// (com o case folding por candidato — ver re_class_match), o que dá a semântica
// da spec para `i` com subtração: `[\p{L}--[a-z]]` com i NÃO casa "A".
@(private="file")
cset_has_char :: proc(s: ^Re_CSet, c: rune, icase, uni: bool) -> bool {
    r := false
    switch s.op {
    case .Leaf:
        r = re_class_match(s.leaf, c, icase, uni)
    case .Union:
        for k in s.kids do if cset_has_char(k, c, icase, uni) { r = true; break }
    case .Inter:
        r = len(s.kids) > 0
        for k in s.kids do if !cset_has_char(k, c, icase, uni) { r = false; break }
    case .Sub:
        r = len(s.kids) > 0 && cset_has_char(s.kids[0], c, icase, uni)
        if r do for k in s.kids[1:] do if cset_has_char(k, c, icase, uni) { r = false; break }
    }
    return r != s.negate
}

// A string `str` (len ≠ 1) está no conjunto? Só folhas com `\q{}` contribuem.
@(private="file")
cset_has_str :: proc(s: ^Re_CSet, str: []rune, icase, uni: bool) -> bool {
    if s.negate do return false
    switch s.op {
    case .Leaf:
        for st in s.strs do if re_runes_eq(st, str, icase, uni) do return true
        return false
    case .Union:
        for k in s.kids do if cset_has_str(k, str, icase, uni) do return true
        return false
    case .Inter:
        if len(s.kids) == 0 do return false
        for k in s.kids do if !cset_has_str(k, str, icase, uni) do return false
        return true
    case .Sub:
        if len(s.kids) == 0 || !cset_has_str(s.kids[0], str, icase, uni) do return false
        for k in s.kids[1:] do if cset_has_str(k, str, icase, uni) do return false
        return true
    }
    return false
}

@(private="file")
re_runes_eq :: proc(a, b: []rune, icase, uni: bool) -> bool {
    if len(a) != len(b) do return false
    for i in 0 ..< len(a) {
        if a[i] == b[i] do continue
        if !icase || re_canon(a[i], uni) != re_canon(b[i], uni) do return false
    }
    return true
}

@(private="file")
cset_collect_strs :: proc(s: ^Re_CSet, out: ^[dynamic][]rune) {
    for st in s.strs do append(out, st)
    for k in s.kids do cset_collect_strs(k, out)
}

// ── compilação AST -> programa ──────────────────────────────────────────────

@(private="file")
re_emit :: proc(prog: ^[dynamic]Re_Inst, inst: Re_Inst) -> int {
    append(prog, inst)
    return len(prog) - 1
}

// Names may overlap only across different branches of the same disjunction.
@(private="file")
re_validate_names :: proc(n: ^Re_Node, p: ^Re_Parser) -> map[string]bool {
    seen := make(map[string]bool, context.temp_allocator)
    if n.kind == .Group && n.name != "" do seen[n.name] = true
    if n.kind == .BackRef && n.name != "" {
        if ids, found := p.names[n.name]; found { n.refs = ids[:] }
        else { p.ok = false; p.spec_err = true }
    }
    for k in n.kids {
        child := re_validate_names(k, p)
        for name in child {
            if seen[name] && n.kind != .Alt { p.ok = false; p.spec_err = true }
            seen[name] = true
        }
    }
    return seen
}

// Clear each nested capture on entry to an iteration. Clear unwinds like Save.
@(private="file")
re_compile_iteration :: proc(n: ^Re_Node, prog: ^[dynamic]Re_Inst) {
    re_compile_clear(n, prog)
    re_compile_node(n, prog)
}

@(private="file")
re_compile_clear :: proc(n: ^Re_Node, prog: ^[dynamic]Re_Inst) {
    if n.kind == .Group && n.group > 0 {
        re_emit(prog, Re_Inst{op = .Clear, x = 2*n.group})
        re_emit(prog, Re_Inst{op = .Clear, x = 2*n.group+1})
    }
    for k in n.kids do re_compile_clear(k, prog)
}

@(private="file")
re_compile_node :: proc(n: ^Re_Node, prog: ^[dynamic]Re_Inst) {
    switch n.kind {
    case .Empty:
        // nada
    case .Char:
        re_emit(prog, Re_Inst{op = .Char, ch = n.ch, mods = n.mods})
    case .Any:
        re_emit(prog, Re_Inst{op = .Any, mods = n.mods})
    case .Class:
        if n.set != nil {
            re_compile_vclass(n, prog)
            break
        }
        rr := make([]Re_Range, len(n.ranges))
        copy(rr, n.ranges[:])
        nr: []Re_Range
        if len(n.nranges) > 0 {
            nr = make([]Re_Range, len(n.nranges))
            copy(nr, n.nranges[:])
        }
        pp: []Re_Prop
        if len(n.props) > 0 {
            pp = make([]Re_Prop, len(n.props))
            copy(pp, n.props[:])
        }
        re_emit(prog, Re_Inst{op = .Class, ranges = rr, nranges = nr, props = pp, negate = n.negate, mods = n.mods})
    case .Begin:  re_emit(prog, Re_Inst{op = .Begin, mods = n.mods})
    case .End:    re_emit(prog, Re_Inst{op = .End, mods = n.mods})
    case .WordB:  re_emit(prog, Re_Inst{op = .WordB, mods = n.mods})
    case .NWordB: re_emit(prog, Re_Inst{op = .NWordB, mods = n.mods})
    case .Concat:
        for k in n.kids do re_compile_node(k, prog)
    case .Alt:
        // Split e1, (Split e2, (Split e3, e4)...); cada ramo salta p/ o fim
        jmps := make([dynamic]int, context.temp_allocator)
        for k, i in n.kids {
            last := i == len(n.kids) - 1
            sp := -1
            if !last do sp = re_emit(prog, Re_Inst{op = .Split})
            body := len(prog)
            re_compile_node(k, prog)
            if !last {
                append(&jmps, re_emit(prog, Re_Inst{op = .Jmp}))
                prog[sp].x = body
                prog[sp].y = len(prog) // próximo ramo
            }
        }
        end := len(prog)
        for j in jmps do prog[j].x = end
    case .Star:
        l1 := re_emit(prog, Re_Inst{op = .Split})
        body := len(prog)
        re_compile_iteration(n.kids[0], prog)
        re_emit(prog, Re_Inst{op = .Jmp, x = l1})
        end := len(prog)
        prog[l1].x = n.greedy ? body : end
        prog[l1].y = n.greedy ? end : body
    case .Plus:
        body := len(prog)
        re_compile_iteration(n.kids[0], prog)
        s := re_emit(prog, Re_Inst{op = .Split})
        end := len(prog)
        prog[s].x = n.greedy ? body : end
        prog[s].y = n.greedy ? end : body
    case .Quest:
        s := re_emit(prog, Re_Inst{op = .Split})
        body := len(prog)
        re_compile_iteration(n.kids[0], prog)
        end := len(prog)
        prog[s].x = n.greedy ? body : end
        prog[s].y = n.greedy ? end : body
    case .Repeat:
        // min cópias obrigatórias
        for _ in 0 ..< n.gmin do re_compile_iteration(n.kids[0], prog)
        if n.gmax < 0 {
            // {n,} => Star do átomo depois das obrigatórias
            star := re_new(.Star); star.greedy = n.greedy
            append(&star.kids, n.kids[0])
            re_compile_node(star, prog)
            clear(&star.kids); re_free(star) // não liberar o kid compartilhado
        } else {
            // (max-min) cópias opcionais aninhadas via Quest
            extra := n.gmax - n.gmin
            for _ in 0 ..< extra {
                q := re_new(.Quest); q.greedy = n.greedy
                append(&q.kids, n.kids[0])
                re_compile_node(q, prog)
                clear(&q.kids); re_free(q)
            }
        }
    case .Group:
        if n.group > 0 {
            re_emit(prog, Re_Inst{op = .Save, x = 2*n.group})
            re_compile_node(n.kids[0], prog)
            re_emit(prog, Re_Inst{op = .Save, x = 2*n.group + 1})
        } else {
            re_compile_node(n.kids[0], prog)
        }
    case .Look:
        sub := make([dynamic]Re_Inst)
        re_compile_node(n.kids[0], &sub)
        re_emit(&sub, Re_Inst{op = .Match})
        re_emit(prog, Re_Inst{op = .Look, sub = sub[:], negate = n.negate, behind = n.behind})
    case .BackRef:
        refs := make([]int, len(n.refs))
        copy(refs, n.refs)
        re_emit(prog, Re_Inst{op = .BackRef, x = n.group, refs = refs, mods = n.mods})
    }
}

// Keep string-set alternatives in one instruction. Expanding thousands of
// RGI emoji sequences into nested Split instructions exhausts the native stack.
@(private="file")
re_compile_vclass :: proc(n: ^Re_Node, prog: ^[dynamic]Re_Inst) {
    set := cset_clone(n.set)
    candidates: [dynamic][]rune
    cset_collect_strs(set, &candidates)
    sort.quick_sort_proc(candidates[:], proc(a, b: []rune) -> int { return len(b) - len(a) })
    re_emit(prog, Re_Inst{op = .Class, set = set, strings = candidates[:], mods = n.mods})
}

// Flags válidas: d g i m s u v y, sem repetir, `u` e `v` exclusivas. Devolve a
// forma CANÔNICA (a ordem do getter `flags` da spec: "dgimsuvy").
regex_canonical_flags :: proc(flags: string) -> (string, bool) {
    ORDER := "dgimsuvy"
    seen: [8]bool
    for f in flags {
        i := strings.index_rune(ORDER, f)
        if i < 0 || seen[i] do return "", false
        seen[i] = true
    }
    if seen[5] && seen[6] do return "", false // u + v
    buf: [8]u8
    n := 0
    for i in 0 ..< 8 do if seen[i] { buf[n] = ORDER[i]; n += 1 }
    return strings.clone(string(buf[:n]), context.temp_allocator), true
}

// Literal errors must be detected before executing the containing script.
// Limit this to the grammar checks implemented strictly: modifiers, named groups,
// Unicode escapes/properties and v classes. Other unsupported syntax stays lenient.
regex_early_error :: proc(pattern, flags: string) -> bool {
    vmode := strings.contains(flags, "v")
    has_property := strings.contains(flags, "u") && (strings.contains(pattern, "\\p") || strings.contains(pattern, "\\P"))
    if !vmode && !has_property && !strings.contains(flags, "u") && !strings.contains(pattern, "(?") do return false
    p := Re_Parser{pat = js_string_chars(pattern, vmode || strings.contains(flags, "u")), ok = true,
                   unicode = vmode || strings.contains(flags, "u"), vmode = vmode}
    root := re_parse_alt(&p)
    re_validate_names(root, &p)
    re_free(root)
    if p.names != nil do delete(p.names)
    return p.spec_err
}

// Compila `pattern` (+flags) num ^Regex tracked no vm. ok=false em erro de sintaxe
// (padrão OU flags — `new RegExp("a", "gg")` é SyntaxError).
regex_compile :: proc(vm: ^Interp, pattern, flags_in: string) -> (^Regex, bool) {
    flags, fok := regex_canonical_flags(flags_in)
    if !fok do return nil, false
    vmode := strings.contains(flags, "v")
    pat_runes := js_string_chars(pattern, vmode || strings.contains(flags, "u"))
    p := Re_Parser{pat = pat_runes, ok = true, unicode = vmode || strings.contains(flags, "u"), vmode = vmode}
    if strings.contains(flags, "i") do p.mods += {.I}
    if strings.contains(flags, "m") do p.mods += {.M}
    if strings.contains(flags, "s") do p.mods += {.S}
    root := re_parse_alt(&p)
    re_validate_names(root, &p)
    defer re_free(root)
    defer if p.names != nil do delete(p.names) // chaves em temp; só o map é nosso
    if !p.ok || !rp_eof(&p) { return nil, false } // sintaxe não suportada / ')' solto

    prog := make([dynamic]Re_Inst)
    re_emit(&prog, Re_Inst{op = .Save, x = 0}) // grupo 0: início
    re_compile_node(root, &prog)
    re_emit(&prog, Re_Inst{op = .Save, x = 1}) // grupo 0: fim
    re_emit(&prog, Re_Inst{op = .Match})

    re := new(Regex)
    re.source = strings.clone(pattern)
    re.flags = strings.clone(flags)
    re.prog = prog[:]
    re.ngroups = p.ngroup
    if p.names != nil {
        re.gnames = make(map[string][]int)
        for name, ids in p.names {
            owned := make([]int, len(ids))
            copy(owned, ids[:])
            re.gnames[strings.clone(name)] = owned
        }
    }
    for f in flags {
        switch f {
        case 'g': re.global = true
        case 'i': re.icase = true
        case 'm': re.multiline = true
        case 's': re.dotall = true
        case 'y': re.sticky = true
        case 'd': re.has_indices = true
        case 'u': re.unicode = true
        case 'v': re.unicode_sets = true
        }
    }
    append(&vm.all_regexes, re)
    return re, true
}

// ── execução (backtracking) ─────────────────────────────────────────────────

@(private="file")
Re_Ctx :: struct {
    s:      []rune,
    uni:    bool,  // flag u/v: case folding Unicode (re_canon); i/m/s vêm de cada Re_Inst
    caps:   []int, // índices de RUNE por slot; -1 = não capturado
    steps:  int,
    lb_target: int, // posição em que o sub de um lookbehind deve TERMINAR (-1 = fora)
}

// Canonicalize da spec (22.2.2.7.3) para a flag i: dois chars casam se têm o
// mesmo canônico. Sem u/v é o toUppercase, mas um não-ASCII nunca vira ASCII
// (`ſ` não casa `s`, o Kelvin não casa `k`); com u/v é o simple case folding,
// aproximado por lower(upper(c)) — que acerta `ſ`→s e Kelvin→k.
// Antes era só ASCII: `/ção/i` não casava "ÇÃO".
@(private="file")
re_canon :: proc(c: rune, uni: bool) -> rune {
    if c < 128 {
        if uni {
            if c >= 'A' && c <= 'Z' do return c + 32
        } else {
            if c >= 'a' && c <= 'z' do return c - 32
        }
        return c
    }
    if uni {
        lo, hi := 0, len(RE_UNICODE_FOLDS)
        for lo < hi {
            mid := lo + (hi-lo)/2
            pair := RE_UNICODE_FOLDS[mid]
            if c < pair[0] { hi = mid } else if c > pair[0] { lo = mid+1 } else { return pair[1] }
        }
        return c
    }
    u := unicode.to_upper(c)
    if u < 128 do return c
    return u
}

@(private="file")
re_is_word :: proc(c: rune) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// IsWordChar da spec para \b/\B: com i + u/v, WordCharacters inclui quem tem
// canônico ASCII de palavra (`ſ` → s, Kelvin → k).
@(private="file")
re_is_word_m :: proc(c: rune, mods: Re_Mods, uni: bool) -> bool {
    if re_is_word(c) do return true
    return c >= 128 && uni && .I in mods && re_is_word(re_canon(c, true))
}

// Com a flag i, a classe casa `c` se algum membro tem o mesmo canônico. Testar
// as variantes de caixa de `c` (lower/upper, filtradas pelo canônico) contra o
// conjunto cru dá isso sem expandir a classe — e vale igual para \p{...}.
// (Antes: `lower(c)` contra [lower(lo), lower(hi)], que errava ranges que cruzam
// letras e não-letras — `[0-Z]` com i casava `_`.)
@(private="file")
re_class_match :: proc(inst: Re_Inst, c: rune, icase, uni: bool) -> bool {
    hit := re_class_raw(inst, c, icase, uni)
    if !hit && icase {
        k := re_canon(c, uni)
        if uni {
            hit = re_class_raw(inst, k, icase, uni)
            i := re_fold_inverse_start(k)
            for !hit && i < len(RE_UNICODE_FOLD_INVERSE) && RE_UNICODE_FOLD_INVERSE[i][0] == k {
                hit = re_class_raw(inst, RE_UNICODE_FOLD_INVERSE[i][1], icase, uni)
                i += 1
            }
            return hit != inst.negate
        }
        lo := c < 128 ? ((c >= 'A' && c <= 'Z') ? c + 32 : c) : unicode.to_lower(c)
        up := c < 128 ? ((c >= 'a' && c <= 'z') ? c - 32 : c) : unicode.to_upper(c)
        if lo != c && re_canon(lo, uni) == k && re_class_raw(inst, lo, icase, uni) {
            hit = true
        } else if up != c && re_canon(up, uni) == k && re_class_raw(inst, up, icase, uni) {
            hit = true
        } else if k != c && k != lo && k != up && re_class_raw(inst, k, icase, uni) {
            hit = true // o próprio canônico (Kelvin → k, que o to_lower não dá)
        }
    }
    return hit != inst.negate
}

// Instrução Class: classe comum ou árvore da flag v, com o `i` da instrução.
@(private="file")
re_inst_class_match :: proc(inst: Re_Inst, c: rune, uni: bool) -> bool {
    if inst.set != nil do return cset_has_char(inst.set, c, .I in inst.mods, uni)
    return re_class_match(inst, c, .I in inst.mods, uni)
}

// LineTerminator da spec: `.` não casa nenhum deles e `^`/`$` com m param em
// todos (antes só `\n` — `\r\n` deixava o `\r` no fim da linha com /m).
@(private="file")
re_is_lt :: proc(c: rune) -> bool {
    return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029
}

// A classe contém `c` (sem a negação da classe e sem case folding)?
@(private="file")
re_class_raw :: proc(inst: Re_Inst, c: rune, icase, uni: bool) -> bool {
    hit := false
    for r in inst.ranges {
        if c >= r.lo && c <= r.hi { hit = true; break }
    }
    // categorias Unicode de \p{...}: casa se satisfizer ALGUMA (\P{...} inverte só
    // a sua). Consultadas depois dos ranges — em `[a-z\p{L}]` qualquer um serve.
    if !hit {
        for pr in inst.props {
            m := re_prop_match(pr.id, c)
            if !m && pr.negate && pr.fold_before_negation && icase && uni {
                k := re_canon(c, true)
                m = re_prop_match(pr.id, k)
                i := re_fold_inverse_start(k)
                for !m && i < len(RE_UNICODE_FOLD_INVERSE) && RE_UNICODE_FOLD_INVERSE[i][0] == k {
                    m = re_prop_match(pr.id, RE_UNICODE_FOLD_INVERSE[i][1])
                    i += 1
                }
            }
            if pr.negate do m = !m
            if m { hit = true; break }
        }
    }
    // atalhos negados dentro da classe (\S \D \W): casa se NÃO estiver neles.
    // (APROXIMAÇÃO: atalhos negados DISTINTOS na mesma classe são mesclados
    // num conjunto só — [\s\S]/[\S]/[\w\W] corretos; [\S\D] não, raríssimo.)
    if !hit && len(inst.nranges) > 0 {
        in_neg := false
        for r in inst.nranges {
            if c >= r.lo && c <= r.hi { in_neg = true; break }
        }
        hit = !in_neg
    }
    return hit
}

@(private="file")
re_fold_inverse_start :: proc(c: rune) -> int {
    lo, hi := 0, len(RE_UNICODE_FOLD_INVERSE)
    for lo < hi {
        mid := lo + (hi-lo)/2
        if RE_UNICODE_FOLD_INVERSE[mid][0] < c { lo = mid+1 } else { hi = mid }
    }
    return lo
}

@(private="file")
re_backtrack :: proc(prog: []Re_Inst, pc, sp: int, ctx: ^Re_Ctx) -> bool {
    ctx.steps += 1
    if ctx.steps > REGEX_STEP_LIMIT do return false
    inst := prog[pc]
    n := len(ctx.s)
    switch inst.op {
    case .Char:
        if sp < n {
            a := ctx.s[sp]; b := inst.ch
            eq := a == b || (.I in inst.mods && re_canon(a, ctx.uni) == re_canon(b, ctx.uni))
            if eq do return re_backtrack(prog, pc+1, sp+1, ctx)
        }
        return false
    case .Any:
        if sp < n && (.S in inst.mods || !re_is_lt(ctx.s[sp])) do return re_backtrack(prog, pc+1, sp+1, ctx)
        return false
    case .Class:
        if inst.set != nil {
            for str in inst.strings {
                if len(str) == 0 || sp+len(str) > n do continue
                if re_runes_eq(str, ctx.s[sp:sp+len(str)], .I in inst.mods, ctx.uni) &&
                   cset_has_str(inst.set, str, .I in inst.mods, ctx.uni) {
                    if re_backtrack(prog, pc+1, sp+len(str), ctx) do return true
                }
            }
        }
        if sp < n && re_inst_class_match(inst, ctx.s[sp], ctx.uni) {
            if re_backtrack(prog, pc+1, sp+1, ctx) do return true
        }
        if inst.set != nil do for str in inst.strings {
            if len(str) == 0 && cset_has_str(inst.set, str, .I in inst.mods, ctx.uni) do return re_backtrack(prog, pc+1, sp, ctx)
        }
        return false
    case .Split:
        if re_backtrack(prog, inst.x, sp, ctx) do return true
        return re_backtrack(prog, inst.y, sp, ctx)
    case .Jmp:
        return re_backtrack(prog, inst.x, sp, ctx)
    case .Save, .Clear:
        old := ctx.caps[inst.x]
        ctx.caps[inst.x] = -1 if inst.op == .Clear else sp
        if re_backtrack(prog, pc+1, sp, ctx) do return true
        ctx.caps[inst.x] = old
        return false
    case .Begin:
        if sp == 0 || (.M in inst.mods && re_is_lt(ctx.s[sp-1])) do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .End:
        if sp == n || (.M in inst.mods && re_is_lt(ctx.s[sp])) do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .WordB:
        before := sp > 0 && re_is_word_m(ctx.s[sp-1], inst.mods, ctx.uni)
        after  := sp < n && re_is_word_m(ctx.s[sp], inst.mods, ctx.uni)
        if before != after do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .NWordB:
        before := sp > 0 && re_is_word_m(ctx.s[sp-1], inst.mods, ctx.uni)
        after  := sp < n && re_is_word_m(ctx.s[sp], inst.mods, ctx.uni)
        if before == after do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .Match:
        // dentro do sub de um lookbehind: só casa se TERMINOU na posição-alvo
        // (o sub deve consumir exatamente s[j..lb_target]).
        if ctx.lb_target >= 0 do return sp == ctx.lb_target
        return true
    case .Look:
        saved_caps := make([]int, len(ctx.caps))
        defer delete(saved_caps)
        copy(saved_caps, ctx.caps)
        // zero-width: roda o subprograma sem consumir. Falha do sub restaura as
        // capturas dele (Save desfaz no unwinding); look POSITIVO que casa mantém
        // as capturas (spec-ish). lb_target é salvo/restaurado p/ o Match do sub
        // se comportar certo (lookahead → -1; lookbehind → posição-alvo) e p/ o
        // aninhamento (um look dentro de outro) não confundir os terminais.
        saved_target := ctx.lb_target
        hit: bool
        if inst.behind {
            // lookbehind: acha j <= sp tal que o sub case exatamente s[j..sp].
            ctx.lb_target = sp
            for j := sp; j >= 0; j -= 1 {
                if re_backtrack(inst.sub, 0, j, ctx) { hit = true; break }
            }
        } else {
            ctx.lb_target = -1 // lookahead: o Match do sub sucede em qualquer posição
            hit = re_backtrack(inst.sub, 0, sp, ctx)
        }
        ctx.lb_target = saved_target
        if hit != inst.negate {
            if inst.negate do copy(ctx.caps, saved_caps)
            if re_backtrack(prog, pc+1, sp, ctx) do return true
        }
        copy(ctx.caps, saved_caps)
        return false
    case .BackRef:
        g := inst.x
        for candidate in inst.refs {
            g = candidate
            if ctx.caps[2*g] >= 0 && ctx.caps[2*g+1] >= 0 do break
        }
        if 2*g+1 >= len(ctx.caps) do return re_backtrack(prog, pc+1, sp, ctx) // grupo inexistente: vazio
        gs, ge := ctx.caps[2*g], ctx.caps[2*g+1]
        if gs < 0 || ge < 0 || ge < gs do return re_backtrack(prog, pc+1, sp, ctx) // não capturado: vazio
        l := ge - gs
        if sp + l > n do return false
        for k in 0 ..< l {
            a := ctx.s[sp+k]; b := ctx.s[gs+k]
            if .I in inst.mods { a = re_canon(a, ctx.uni); b = re_canon(b, ctx.uni) }
            if a != b do return false
        }
        return re_backtrack(prog, pc+1, sp+l, ctx)
    }
    return false
}

// Captures and start positions are UTF-16 code-unit indices, like JS APIs.
Re_Match :: struct { ok: bool, groups: []int }

regex_run :: proc(re: ^Regex, subject: string, start: int, anchored := false) -> Re_Match {
    points := re.unicode || re.unicode_sets
    runes := js_string_chars(subject, points)
    offsets := make([]int, len(runes)+1, context.temp_allocator)
    for r, i in runes do offsets[i+1] = offsets[i] + (2 if r > 0xFFFF else 1)
    if start > offsets[len(runes)] do return Re_Match{}
    start_ri := 0
    for start_ri < len(runes) && offsets[start_ri+1] <= start do start_ri += 1
    nslots := 2 * (re.ngroups + 1)
    ctx := Re_Ctx{s = runes, uni = points, lb_target = -1, caps = make([]int, nslots, context.temp_allocator)}
    for sp := start_ri; sp <= len(runes); sp += 1 {
        for j in 0 ..< nslots do ctx.caps[j] = -1
        ctx.steps = 0
        if re_backtrack(re.prog, 0, sp, &ctx) {
            groups := make([]int, nslots)
            for j in 0 ..< nslots do groups[j] = -1 if ctx.caps[j] < 0 else offsets[ctx.caps[j]]
            return Re_Match{ok = true, groups = groups}
        }
        if anchored do break
    }
    return Re_Match{}
}

// Libera o programa e as strings de um Regex (chamado por vm_destroy).
regex_destroy :: proc(re: ^Regex) {
    re_free_prog(re.prog)
    delete(re.source)
    delete(re.flags)
    if re.gnames != nil {
        for name, ids in re.gnames { delete(name); delete(ids) }
        delete(re.gnames)
    }
    if re.props != nil {
        for k in re.props do delete(k)
        delete(re.props)
    }
    free(re)
}

// Libera um programa compilado, recursando nos subprogramas de lookahead.
@(private="file")
re_free_prog :: proc(prog: []Re_Inst) {
    for inst in prog {
        if inst.op == .Class {
            delete(inst.strings)
            delete(inst.ranges); delete(inst.nranges); delete(inst.props)
            if inst.set != nil do cset_free(inst.set)
        }
        if inst.op == .Look do re_free_prog(inst.sub)
        if inst.op == .BackRef do delete(inst.refs)
    }
    delete(prog)
}

// ── integração com o runtime JS ─────────────────────────────────────────────

// `source` como a spec o mostra (EscapeRegExpPattern): vazio vira `(?:)` e `/`
// fora de classe e quebras de linha saem escapados — `new RegExp("a/b")` tem de
// virar `/a\/b/` no toString, senão o texto não é um literal válido. Sem nada a
// escapar devolve a própria fonte (sem alocar); senão uma string do vm.
regex_source_text :: proc(vm: ^Interp, re: ^Regex) -> string {
    src := re.source
    if src == "" do return "(?:)"
    needs := false
    {
        esc, cls := false, false
        for c in src {
            if esc { esc = false; if c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029 do needs = true; continue }
            switch c {
            case '\\': esc = true
            case '[': cls = true
            case ']': cls = false
            case '/': if !cls do needs = true
            case '\n', '\r', 0x2028, 0x2029: needs = true
            }
        }
    }
    if !needs do return src
    sb := strings.builder_make(context.temp_allocator)
    regex_write_source(&sb, src)
    return own_str_raw(vm, strings.to_string(sb))
}

// Escreve a fonte já escapada (ver regex_source_text) — usada também pelo to_text.
regex_write_source :: proc(sb: ^strings.Builder, src: string) {
    if src == "" { strings.write_string(sb, "(?:)"); return }
    esc, cls := false, false
    for c in src {
        lt := ""
        switch c {
        case '\n': lt = "n"
        case '\r': lt = "r"
        case 0x2028: lt = "u2028"
        case 0x2029: lt = "u2029"
        }
        if esc {
            esc = false
            if lt != "" { strings.write_string(sb, lt) } else { strings.write_rune(sb, c) }
            continue
        }
        if lt != "" { strings.write_byte(sb, '\\'); strings.write_string(sb, lt); continue }
        switch c {
        case '\\': esc = true
        case '[': cls = true
        case ']': cls = false
        case '/': if !cls do strings.write_byte(sb, '\\')
        }
        strings.write_rune(sb, c)
    }
}

// RegExp.prototype.toString: "/" + source + "/" + flags.
@(private="file")
regex_tostring_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    re, ok := this.(^Regex)
    if !ok {
        throw_type_error(vm, "RegExp.prototype.toString requires that 'this' be a RegExp")
        return nil
    }
    return own_str(vm, strings.concatenate({"/", regex_source_text(vm, re), "/", re.flags}, context.temp_allocator))
}

install_regex :: proc(vm: ^Interp) {
    vm.regex_test_fn = mk_native(vm, regex_test_native)
    vm.regex_exec_fn = mk_native(vm, regex_exec_native)
    vm.regex_tostring_fn = mk_native(vm, regex_tostring_native)
    rctor := mk_native(vm, regexp_ctor_native)
    rctor.props = make(map[string]Value)
    rproto := new_object(vm)                       // RegExp.prototype (test/exec genéricos)
    rproto.props["test"]        = vm.regex_test_fn
    rproto.props["exec"]        = vm.regex_exec_fn
    rproto.props["toString"]    = vm.regex_tostring_fn
    rproto.props["constructor"] = rctor
    install_regex_symbol_methods(vm, rproto, rctor) // @@métodos, getters de flags, RegExp[@@species]
    vm.regex_proto = rproto
    rctor.props["prototype"] = rproto
    rctor.name = "RegExp"
    env_define(vm.global, "RegExp", rctor)
}

// new RegExp(padrão, flags) / RegExp(re) — devolve ^Regex. Erro de sintaxe lança.
@(private="file")
regexp_ctor_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // RegExp(regexExistente) devolve/copia a fonte
    // A regex-fonte pode ser a instância de uma SUBCLASSE (^Object com a ^Regex no
    // `prim`) — é assim que o @@split/@@matchAll genéricos constroem o splitter:
    // `new C(rx, flags)`. Antes ela caía no padrão vazio.
    pat := ""
    flags := ""
    if r := regex_of(arg(args, 0)); r != nil {
        pat = r.source; flags = r.flags
    } else if s, ok := arg(args, 0).(string); ok {
        pat = s
    }
    if f, ok := arg(args, 1).(string); ok do flags = f
    re, ok := regex_compile(vm, pat, flags)
    if !ok {
        vm.thrown = mk_error(vm, "SyntaxError", "expressão regular inválida")
        vm.throwing = true
        return nil
    }
    return re
}

// re.test(str) -> bool. Com flag g, avança lastIndex a cada chamada.
@(private="file")
// lastIndex usa unidades UTF-16. exec/test não avançam um casamento vazio;
// os consumidores globais usam AdvanceStringIndex conforme as flags u/v.
regex_test_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := to_string_value(vm, arg(args, 0))
    // exec sobrescrito / subclasse / objeto qualquer: test = RegExpExec(...) !== null
    re := regex_fast(vm, this)
    if vm.throwing do return nil
    if re == nil do return regex_test_generic(vm, this, s)
    stateful := re.global || re.sticky // ambos usam/atualizam lastIndex
    start := stateful ? re.last_index : 0
    if start > str_rlen(s) { re.last_index = 0; return false }
    m := regex_run(re, s, start, re.sticky)
    if !m.ok {
        if stateful do re.last_index = 0
        return false
    }
    defer delete(m.groups)
    if stateful {
        re.last_index = m.groups[1]
    }
    return true
}

// re.exec(str) -> [casamento, grupo1, ...] ou null. Com g, usa/atualiza lastIndex.
@(private="file")
regex_exec_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // RegExpBuiltinExec exige [[RegExpMatcher]]: `this` que não é regex é TypeError
    // (spec 22.2.6.2). Antes devolvia null em silêncio, e então
    // `Object.create(RegExp.prototype).test("a")` dava false em vez de lançar.
    re, ok := this.(^Regex)
    if !ok {
        throw_type_error(vm, "RegExp.prototype.exec called on an incompatible receiver")
        return nil
    }
    s := to_string_value(vm, arg(args, 0))
    stateful := re.global || re.sticky
    start := stateful ? re.last_index : 0 // em unidades UTF-16
    if start > str_rlen(s) { re.last_index = 0; return JS_Null{} }
    m := regex_run(re, s, start, re.sticky)
    if !m.ok {
        if stateful do re.last_index = 0
        return JS_Null{}
    }
    defer delete(m.groups)
    if stateful {
        re.last_index = m.groups[1]
    }
    return regex_result_array(vm, re, s, m)
}

// Monta o array [casamento inteiro, grupo1, grupo2, ...] (grupo ausente =
// undefined), com .index em unidades UTF-16
// e .input (a string inteira) — usado por exec e str_match sem /g, como na spec.
regex_result_array :: proc(vm: ^Interp, re: ^Regex, s: string, m: Re_Match) -> Value {
    arr := new_array(vm)
    for g in 0 ..= re.ngroups {
        gs := m.groups[2*g]; ge := m.groups[2*g + 1]
        if gs < 0 {
            append(&arr.items, nil) // grupo não capturado => undefined
        } else {
            append(&arr.items, own_str(vm, str_rslice(s, gs, ge)))
        }
    }
    arr.props = make(map[string]Value)
    arr.props["index"] = f64(m.groups[0]) // em unidades UTF-16
    arr.props["input"] = own_str(vm, s)
    if len(re.gnames) > 0 do arr.props["groups"] = regex_groups_object(vm, re, s, m) // m.groups.nome
    if re.has_indices do arr.props["indices"] = regex_indices_array(vm, re, s, m)
    return arr
}

// Flag d: `indices[i] = [início, fim]` de cada grupo (undefined se não participou),
// em code units como `.index`, e `indices.groups` com os nomeados (undefined se o
// padrão não tem nomes — como o `groups` do próprio resultado).
@(private="file")
regex_indices_array :: proc(vm: ^Interp, re: ^Regex, s: string, m: Re_Match) -> ^Array {
    pair :: proc(vm: ^Interp, s: string, m: Re_Match, g: int) -> Value {
        if 2*g+1 >= len(m.groups) do return nil
        gs, ge := m.groups[2*g], m.groups[2*g+1]
        if gs < 0 do return nil
        a := new_array(vm)
        append(&a.items, f64(gs), f64(ge))
        return a
    }
    ind := new_array(vm)
    for g in 0 ..= re.ngroups do append(&ind.items, pair(vm, s, m, g))
    ind.props = make(map[string]Value)
    if len(re.gnames) > 0 {
        Pair :: struct { name: string, gi: int }
        pairs := make([dynamic]Pair, 0, len(re.gnames), context.temp_allocator)
        for name, ids in re.gnames do append(&pairs, Pair{name, ids[0]})
        for i := 1; i < len(pairs); i += 1 {
            for j := i; j > 0 && pairs[j].gi < pairs[j-1].gi; j -= 1 do pairs[j], pairs[j-1] = pairs[j-1], pairs[j]
        }
        gobj := new_object(vm)
        gobj.proto = nil
        for p in pairs do oput(gobj, own_str_raw(vm, p.name), pair(vm, s, m, regex_named_group(re, p.name, m)))
        ind.props["groups"] = gobj
    } else {
        ind.props["groups"] = nil
    }
    return ind
}

regex_named_group :: proc(re: ^Regex, name: string, m: Re_Match) -> int {
    ids := re.gnames[name]
    for gi in ids do if m.groups[2*gi] >= 0 do return gi
    return ids[0]
}

// O objeto `groups` de um casamento (exec/match e o último argumento do callback do
// replace): nome → texto capturado, undefined se o grupo não participou. Chaves na
// ORDEM dos grupos no padrão — antes saíam na ordem do map do Odin (aleatória entre
// execuções). Protótipo nulo, como na spec (`groups.toString` não existe).
regex_groups_object :: proc(vm: ^Interp, re: ^Regex, s: string, m: Re_Match) -> ^Object {
    Pair :: struct { name: string, gi: int }
    pairs := make([dynamic]Pair, 0, len(re.gnames), context.temp_allocator)
    for name, ids in re.gnames do append(&pairs, Pair{name, ids[0]})
    for i := 1; i < len(pairs); i += 1 { // insertion sort: quase sempre 1–3 grupos
        for j := i; j > 0 && pairs[j].gi < pairs[j-1].gi; j -= 1 do pairs[j], pairs[j-1] = pairs[j-1], pairs[j]
    }
    gobj := new_object(vm)
    gobj.proto = nil
    for p in pairs {
        v: Value = nil
        gi := regex_named_group(re, p.name, m)
        if 2 * gi + 1 < len(m.groups) {
            gs, ge := m.groups[2 * gi], m.groups[2 * gi + 1]
            if gs >= 0 do v = own_str(vm, str_rslice(s, gs, ge))
        }
        oput(gobj, own_str_raw(vm, p.name), v)
    }
    return gobj
}

// Converte um Value em string (nil/undefined -> ""), sem alocar quando já é string.
@(private="file")
to_string_value :: proc(vm: ^Interp, v: Value) -> string {
    if s, ok := v.(string); ok do return s
    if v == nil do return ""
    sb: strings.Builder
    strings.builder_init(&sb)
    to_text(&sb, v)
    c := strings.clone(strings.to_string(sb))
    strings.builder_destroy(&sb)
    append(&vm.owned_strings, c) // posse -> vm
    return c
}
