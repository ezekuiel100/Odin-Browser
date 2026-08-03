package js

// Motor de expressões regulares (subconjunto do RegExp do JS) — M22.
//
// Backtracking VM ao estilo Russ Cox: o padrão é parseado numa AST e compilado
// para um programa de instruções (Char/Any/Class/Split/Jmp/Save/âncoras/Match).
// O casamento é recursivo com desfazimento (Save guarda/restaura no backtrack).
// Opera sobre RUNES (1 char = 1 code point); as capturas viram offsets de BYTE
// da string original para fatiar sem quebrar UTF-8.
//
// Suporta: literais, `.`, classes `[...]` (ranges, negação, \d\w\s e negados),
// âncoras `^ $`, `\b \B`, quantificadores `* + ? {n} {n,} {n,m}` (greedy e lazy),
// grupos `(...)`, `(?:...)` e nomeados `(?<nome>...)` (exec devolve .groups),
// lookahead `(?=...)`/`(?!...)`, lookbehind `(?<=...)`/`(?<!...)`, backreferences
// `\1`-`\99` e `\k<nome>`, alternância `|`, escapes (\uNNNN \xNN incl.).
// Flags: g i m s (dotAll) y (sticky). NÃO suporta: classes POSIX.

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

REGEX_STEP_LIMIT :: 2_000_000 // trava contra backtracking catastrófico

Re_Op :: enum u8 { Char, Any, Class, Split, Jmp, Save, Match, Begin, End, WordB, NWordB, Look, BackRef }

Re_Range :: struct { lo, hi: rune }

Re_Inst :: struct {
    op:     Re_Op,
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
    prog:      []Re_Inst,
    ngroups:   int,     // grupos capturantes (sem o grupo 0)
    last_index: int,    // usado por exec/test com a flag g
    gnames:    map[string]int, // grupos nomeados: nome (clonado) -> índice do grupo
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
Re_Prop_Kind :: enum u8 {
    Letter,      // L, Letter, Alphabetic, Alpha
    Upper,       // Lu, Uppercase_Letter, Uppercase
    Lower,       // Ll, Lowercase_Letter, Lowercase
    Title,       // Lt, Titlecase_Letter
    Number,      // N, Number
    Digit,       // Nd, Decimal_Number, digit
    Punct,       // P, Punctuation, punct
    Symbol,      // S, Symbol
    Space,       // Z, Zs, Separator, Space_Separator, White_Space, space
    Control,     // C, Cc, Control, Other
    Mark,        // M, Mark, Combining_Mark
    Mark_NS,     // Mn, Nonspacing_Mark
    Mark_SP,     // Mc, Spacing_Mark
    Mark_EN,     // Me, Enclosing_Mark
    Ascii,       // ASCII
    Any,         // Any
    Never,       // nome NÃO reconhecido (ex.: Script=Han): não casa nada. Ver re_parse_prop.
}

Re_Prop :: struct {
    kind:   Re_Prop_Kind,
    negate: bool, // veio de `\P{...}`
}

Re_Node :: struct {
    kind:   Re_Kind,
    ch:     rune,
    ranges: [dynamic]Re_Range, negate: bool,
    props:  [dynamic]Re_Prop, // Class: categorias de \p{...}/\P{...} (nil até a 1ª)
    behind: bool, // Look: é lookbehind?
    nranges: [dynamic]Re_Range, // Class: atalhos negados dentro da classe (ver Re_Inst)
    kids:   [dynamic]^Re_Node,
    greedy: bool,
    gmin, gmax: int, // Repeat: gmax = -1 => infinito
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
    free(n)
}

@(private="file")
Re_Parser :: struct {
    pat: []rune, pos: int, ngroup: int, ok: bool,
    names: map[string]int, // grupos nomeados vistos (chaves em temp; nil até o 1º)
    unicode: bool,         // flag `u`: habilita `\u{XXXXX}` (code point por extenso).
                           // SEM a flag, `\u{2}` é a spec dizendo "u repetido 2 vezes",
                           // então a forma com chaves só pode ser lida quando ela está
                           // presente — do contrário mudaríamos o sentido de padrões
                           // legítimos que hoje funcionam.
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
    alt := re_new(.Alt)
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
    con := re_new(.Concat)
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
    case '*': rp_next(p); wrap = re_new(.Star)
    case '+': rp_next(p); wrap = re_new(.Plus)
    case '?': rp_next(p); wrap = re_new(.Quest)
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
    rep := re_new(.Repeat)
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
                lk := re_new(.Look)
                lk.negate = nx == '!'
                inner := re_parse_alt(p)
                if rp_peek(p) == ')' do rp_next(p)
                append(&lk.kids, inner)
                return lk
            case '<':
                nx2 := p.pos+2 < len(p.pat) ? p.pat[p.pos+2] : -1
                if nx2 == '=' || nx2 == '!' { // lookBEHIND (?<=...)/(?<!...)
                    rp_next(p); rp_next(p); rp_next(p) // ? < = / ? < !
                    lb := re_new(.Look)
                    lb.negate = nx2 == '!'
                    lb.behind = true
                    inner := re_parse_alt(p)
                    if rp_peek(p) == ')' do rp_next(p)
                    append(&lb.kids, inner)
                    return lb
                }
                // grupo nomeado (?<nome>...)
                rp_next(p); rp_next(p) // ? <
                nb := strings.builder_make(context.temp_allocator)
                for !rp_eof(p) && rp_peek(p) != '>' do strings.write_rune(&nb, rp_next(p))
                if rp_peek(p) == '>' do rp_next(p)
                gname = strings.to_string(nb)
                if gname == "" do p.ok = false
            case:
                p.ok = false // (?X desconhecido → SyntaxError
            }
        }
        g := re_new(.Group)
        if capturing { p.ngroup += 1; g.group = p.ngroup } else { g.group = 0 }
        if gname != "" {
            if p.names == nil do p.names = make(map[string]int)
            p.names[gname] = g.group
        }
        inner := re_parse_alt(p)
        if rp_peek(p) == ')' do rp_next(p)
        append(&g.kids, inner)
        return g
    case '[':
        return re_parse_class(p)
    case '.':
        rp_next(p); return re_new(.Any)
    case '^':
        rp_next(p); return re_new(.Begin)
    case '$':
        rp_next(p); return re_new(.End)
    case '\\':
        rp_next(p)
        return re_parse_escape(p)
    case:
        rp_next(p)
        n := re_new(.Char); n.ch = c
        return n
    }
}

// Consome os dígitos de \uNNNN (4 hex), \u{XXXXX} (1-6 hex, só com flag `u`) ou
// \xNN (2 hex) e devolve a rune. Se os dígitos não estiverem completos, devolve o
// próprio 'u'/'x' (leniente, como tratamos escapes desconhecidos).
//
// A forma com CHAVES é a única que alcança code points acima de U+FFFF sem par
// surrogate — `/\u{1F600}/u`. O motor casa sobre []rune, então o astral vira uma
// rune só dos dois lados e a comparação é direta.
@(private="file")
rp_hex_escape :: proc(p: ^Re_Parser, kind: rune) -> rune {
    if kind == 'u' && p.unicode && p.pos < len(p.pat) && p.pat[p.pos] == '{' {
        j := p.pos + 1
        v := 0
        ndig := 0
        for j < len(p.pat) && p.pat[j] != '}' {
            d := rp_hex_digit(p.pat[j])
            if d < 0 do return kind // não-hex dentro das chaves: escape malformado
            v = v*16 + d
            ndig += 1
            if ndig > 6 do return kind
            j += 1
        }
        // precisa fechar, ter ao menos 1 dígito e caber no espaço de code points
        if j >= len(p.pat) || ndig == 0 || v > 0x10FFFF do return kind
        p.pos = j + 1 // consome o '}'
        return rune(v)
    }
    n := kind == 'u' ? 4 : 2
    if p.pos + n > len(p.pat) do return kind
    v := 0
    for k in 0 ..< n {
        d := rp_hex_digit(p.pat[p.pos + k])
        if d < 0 do return kind
        v = v * 16 + d
    }
    p.pos += n
    return rune(v)
}

// Lê `{Nome}` logo depois de um `\p`/`\P` e devolve o predicado correspondente.
// `ok=false` quando não há chaves (aí o chamador trata o `\p` como literal, que é
// o que a spec manda SEM a flag `u` e o que este motor já fazia).
//
// Nome NÃO reconhecido (o caso típico é `Script=Han`, que exigiria tabelas de
// script que o core:unicode não expõe) vira .Never: a classe não casa NADA.
// É a degradação HONESTA — melhor que lançar SyntaxError (derruba o script
// inteiro por um regex de enfeite) e melhor que o comportamento antigo, em que
// `/\p{L}/` casava a string literal "p{L}".
@(private="file")
re_parse_prop :: proc(p: ^Re_Parser, negated: bool) -> (prop: Re_Prop, ok: bool) {
    if p.pos >= len(p.pat) || p.pat[p.pos] != '{' do return {}, false
    j := p.pos + 1
    start := j
    for j < len(p.pat) && p.pat[j] != '}' do j += 1
    if j >= len(p.pat) do return {}, false // sem fechar: trata como literal
    name := utf8.runes_to_string(p.pat[start:j], context.temp_allocator)
    p.pos = j + 1 // consome o '}'

    kind := Re_Prop_Kind.Never
    switch name {
    case "L", "Letter", "Alphabetic", "Alpha":              kind = .Letter
    case "Lu", "Uppercase_Letter", "Uppercase":             kind = .Upper
    case "Ll", "Lowercase_Letter", "Lowercase":             kind = .Lower
    case "Lt", "Titlecase_Letter":                          kind = .Title
    case "N", "Number":                                     kind = .Number
    case "Nd", "Decimal_Number", "digit":                   kind = .Digit
    case "P", "Punctuation", "punct":                       kind = .Punct
    case "S", "Symbol":                                     kind = .Symbol
    case "Z", "Zs", "Separator", "Space_Separator",
         "White_Space", "space":                            kind = .Space
    case "C", "Cc", "Control", "Other":                     kind = .Control
    case "M", "Mark", "Combining_Mark":                     kind = .Mark
    case "Mn", "Nonspacing_Mark":                           kind = .Mark_NS
    case "Mc", "Spacing_Mark":                              kind = .Mark_SP
    case "Me", "Enclosing_Mark":                            kind = .Mark_EN
    case "ASCII":                                           kind = .Ascii
    case "Any":                                             kind = .Any
    }
    return Re_Prop{kind = kind, negate = negated}, true
}

// O predicado em si. As tabelas são as do core:unicode (geradas do UCD).
@(private="file")
re_prop_match :: proc(k: Re_Prop_Kind, c: rune) -> bool {
    switch k {
    case .Letter:  return unicode.is_letter(c)
    case .Upper:   return unicode.is_upper(c)
    case .Lower:   return unicode.is_lower(c)
    case .Title:   return unicode.is_title(c)
    case .Number:  return unicode.is_number(c)
    case .Digit:   return unicode.is_digit(c)
    case .Punct:   return unicode.is_punct(c)
    case .Symbol:  return unicode.is_symbol(c)
    case .Space:   return unicode.is_space(c)
    case .Control: return unicode.is_control(c)
    case .Mark:    return unicode.is_combining(c)
    case .Mark_NS: return unicode.is_nonspacing_mark(c)
    case .Mark_SP: return unicode.is_spacing_mark(c)
    case .Mark_EN: return unicode.is_enclosing_mark(c)
    case .Ascii:   return c <= 0x7F
    case .Any:     return true
    case .Never:   return false
    }
    return false
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
    if rp_eof(p) { n := re_new(.Char); n.ch = '\\'; return n }
    c := rp_next(p)
    switch c {
    case 'd', 'D', 'w', 'W', 's', 'S':
        n := re_new(.Class)
        re_add_class_shorthand(n, c)
        return n
    case 'b': return re_new(.WordB)
    case 'B': return re_new(.NWordB)
    case 'p', 'P':
        // property escape — só COM a flag `u` (sem ela, `\p` é o literal 'p', que
        // é o que a spec manda e o que este motor já fazia).
        if p.unicode {
            if pr, ok := re_parse_prop(p, c == 'P'); ok {
                n := re_new(.Class)
                append(&n.props, pr)
                return n
            }
        }
        n := re_new(.Char); n.ch = c
        return n
    case 'u', 'x':
        n := re_new(.Char); n.ch = rp_hex_escape(p, c)
        return n
    case '1'..='9':
        // backreference \1..\99 (2º dígito só se o grupo existir até aqui)
        idx := int(c - '0')
        if !rp_eof(p) && rp_peek(p) >= '0' && rp_peek(p) <= '9' && idx*10 + int(rp_peek(p)-'0') <= p.ngroup {
            idx = idx*10 + int(rp_next(p) - '0')
        }
        n := re_new(.BackRef); n.group = idx
        return n
    case 'k':
        // \k<nome>: backreference a grupo nomeado (o nome precisa já ter aparecido)
        if rp_peek(p) == '<' {
            rp_next(p)
            nb := strings.builder_make(context.temp_allocator)
            for !rp_eof(p) && rp_peek(p) != '>' do strings.write_rune(&nb, rp_next(p))
            if rp_peek(p) == '>' do rp_next(p)
            if idx, found := p.names[strings.to_string(nb)]; found {
                n := re_new(.BackRef); n.group = idx
                return n
            }
            p.ok = false // nome desconhecido (refs adiantadas não suportadas)
            return re_new(.Empty)
        }
        n := re_new(.Char); n.ch = 'k'
        return n
    case:
        n := re_new(.Char); n.ch = re_escape_char(c)
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
    rp_next(p) // [
    n := re_new(.Class)
    if rp_peek(p) == '^' { rp_next(p); n.negate = true }
    for !rp_eof(p) && rp_peek(p) != ']' {
        lo := rp_next(p)
        if lo == '\\' && !rp_eof(p) {
            e := rp_next(p)
            switch e {
            case 'd','w','s':
                // atalho positivo dentro da classe: mescla os ranges
                tmp := re_new(.Class); re_add_class_shorthand(tmp, e)
                for r in tmp.ranges do append(&n.ranges, r)
                re_free(tmp)
                continue
            case 'D','W','S':
                // atalho NEGADO dentro da classe: vai p/ nranges — o char casa
                // se NÃO estiver nesses ranges ([\s\S] = qualquer char, o idioma
                // clássico de "qualquer coisa inclusive \n" que minifiers usam)
                tmp := re_new(.Class); re_add_class_shorthand(tmp, e + ('a' - 'A'))
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

// ── compilação AST -> programa ──────────────────────────────────────────────

@(private="file")
re_emit :: proc(prog: ^[dynamic]Re_Inst, inst: Re_Inst) -> int {
    append(prog, inst)
    return len(prog) - 1
}

@(private="file")
re_compile_node :: proc(n: ^Re_Node, prog: ^[dynamic]Re_Inst) {
    switch n.kind {
    case .Empty:
        // nada
    case .Char:
        re_emit(prog, Re_Inst{op = .Char, ch = n.ch})
    case .Any:
        re_emit(prog, Re_Inst{op = .Any})
    case .Class:
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
        re_emit(prog, Re_Inst{op = .Class, ranges = rr, nranges = nr, props = pp, negate = n.negate})
    case .Begin:  re_emit(prog, Re_Inst{op = .Begin})
    case .End:    re_emit(prog, Re_Inst{op = .End})
    case .WordB:  re_emit(prog, Re_Inst{op = .WordB})
    case .NWordB: re_emit(prog, Re_Inst{op = .NWordB})
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
        re_compile_node(n.kids[0], prog)
        re_emit(prog, Re_Inst{op = .Jmp, x = l1})
        end := len(prog)
        prog[l1].x = n.greedy ? body : end
        prog[l1].y = n.greedy ? end : body
    case .Plus:
        body := len(prog)
        re_compile_node(n.kids[0], prog)
        s := re_emit(prog, Re_Inst{op = .Split})
        end := len(prog)
        prog[s].x = n.greedy ? body : end
        prog[s].y = n.greedy ? end : body
    case .Quest:
        s := re_emit(prog, Re_Inst{op = .Split})
        body := len(prog)
        re_compile_node(n.kids[0], prog)
        end := len(prog)
        prog[s].x = n.greedy ? body : end
        prog[s].y = n.greedy ? end : body
    case .Repeat:
        // min cópias obrigatórias
        for _ in 0 ..< n.gmin do re_compile_node(n.kids[0], prog)
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
        re_emit(prog, Re_Inst{op = .BackRef, x = n.group})
    }
}

// Compila `pattern` (+flags) num ^Regex tracked no vm. ok=false em erro de sintaxe.
regex_compile :: proc(vm: ^Interp, pattern, flags: string) -> (^Regex, bool) {
    pat_runes := utf8.string_to_runes(pattern, context.temp_allocator)
    p := Re_Parser{pat = pat_runes, ok = true, unicode = strings.contains(flags, "u")}
    root := re_parse_alt(&p)
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
        re.gnames = make(map[string]int)
        for name, idx in p.names do re.gnames[strings.clone(name)] = idx
    }
    for f in flags {
        switch f {
        case 'g': re.global = true
        case 'i': re.icase = true
        case 'm': re.multiline = true
        case 's': re.dotall = true
        case 'y': re.sticky = true
        }
    }
    append(&vm.all_regexes, re)
    return re, true
}

// ── execução (backtracking) ─────────────────────────────────────────────────

@(private="file")
Re_Ctx :: struct {
    s:      []rune,
    icase:  bool,
    ml:     bool,
    dotall: bool, // flag s: `.` casa qualquer char, inclusive `\n`
    caps:   []int, // índices de RUNE por slot; -1 = não capturado
    steps:  int,
    lb_target: int, // posição em que o sub de um lookbehind deve TERMINAR (-1 = fora)
}

@(private="file")
re_lower :: proc(c: rune) -> rune {
    if c >= 'A' && c <= 'Z' do return c + 32
    return c
}

@(private="file")
re_is_word :: proc(c: rune) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private="file")
re_class_match :: proc(inst: Re_Inst, c: rune, icase: bool) -> bool {
    hit := false
    for r in inst.ranges {
        if c >= r.lo && c <= r.hi { hit = true; break }
        if icase {
            lc := re_lower(c)
            if lc >= re_lower(r.lo) && lc <= re_lower(r.hi) { hit = true; break }
        }
    }
    // categorias Unicode de \p{...}: casa se satisfizer ALGUMA (\P{...} inverte só
    // a sua). Consultadas depois dos ranges — em `[a-z\p{L}]` qualquer um serve.
    if !hit {
        for pr in inst.props {
            m := re_prop_match(pr.kind, c)
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
    return hit != inst.negate
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
            eq := ctx.icase ? re_lower(a) == re_lower(b) : a == b
            if eq do return re_backtrack(prog, pc+1, sp+1, ctx)
        }
        return false
    case .Any:
        if sp < n && (ctx.dotall || ctx.s[sp] != '\n') do return re_backtrack(prog, pc+1, sp+1, ctx)
        return false
    case .Class:
        if sp < n && re_class_match(inst, ctx.s[sp], ctx.icase) do return re_backtrack(prog, pc+1, sp+1, ctx)
        return false
    case .Split:
        if re_backtrack(prog, inst.x, sp, ctx) do return true
        return re_backtrack(prog, inst.y, sp, ctx)
    case .Jmp:
        return re_backtrack(prog, inst.x, sp, ctx)
    case .Save:
        old := ctx.caps[inst.x]
        ctx.caps[inst.x] = sp
        if re_backtrack(prog, pc+1, sp, ctx) do return true
        ctx.caps[inst.x] = old
        return false
    case .Begin:
        if sp == 0 || (ctx.ml && ctx.s[sp-1] == '\n') do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .End:
        if sp == n || (ctx.ml && ctx.s[sp] == '\n') do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .WordB:
        before := sp > 0 && re_is_word(ctx.s[sp-1])
        after  := sp < n && re_is_word(ctx.s[sp])
        if before != after do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .NWordB:
        before := sp > 0 && re_is_word(ctx.s[sp-1])
        after  := sp < n && re_is_word(ctx.s[sp])
        if before == after do return re_backtrack(prog, pc+1, sp, ctx)
        return false
    case .Match:
        // dentro do sub de um lookbehind: só casa se TERMINOU na posição-alvo
        // (o sub deve consumir exatamente s[j..lb_target]).
        if ctx.lb_target >= 0 do return sp == ctx.lb_target
        return true
    case .Look:
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
        if hit == inst.negate do return false
        return re_backtrack(prog, pc+1, sp, ctx)
    case .BackRef:
        g := inst.x
        if 2*g+1 >= len(ctx.caps) do return re_backtrack(prog, pc+1, sp, ctx) // grupo inexistente: vazio
        gs, ge := ctx.caps[2*g], ctx.caps[2*g+1]
        if gs < 0 || ge < 0 || ge < gs do return re_backtrack(prog, pc+1, sp, ctx) // não capturado: vazio
        l := ge - gs
        if sp + l > n do return false
        for k in 0 ..< l {
            a := ctx.s[sp+k]; b := ctx.s[gs+k]
            if ctx.icase { a = re_lower(a); b = re_lower(b) }
            if a != b do return false
        }
        return re_backtrack(prog, pc+1, sp+l, ctx)
    }
    return false
}

// Resultado de um casamento: offsets de BYTE na string original. groups[0..1] é o
// casamento inteiro; grupos i em [2i, 2i+1]. -1 = grupo não capturado.
Re_Match :: struct { ok: bool, groups: []int }

// Procura o padrão em `subject` a partir do byte `start`. O chamador deve liberar
// m.groups (context.allocator). Índices de byte; use com subject[a:b].
// `anchored` (flag y): tenta casar SÓ na posição inicial, sem varrer adiante.
regex_run :: proc(re: ^Regex, subject: string, start: int, anchored := false) -> Re_Match {
    // decodifica em runes + offsets de byte (boff[i] = byte da rune i; boff[n]=len)
    runes := make([dynamic]rune, context.temp_allocator)
    boff  := make([dynamic]int, context.temp_allocator)
    i := 0
    for i < len(subject) {
        r, w := utf8.decode_rune(subject[i:])
        append(&runes, r); append(&boff, i)
        i += w
    }
    append(&boff, len(subject))
    n := len(runes)

    // índice de rune inicial correspondente ao byte `start`
    start_ri := n
    for k in 0 ..< n do if boff[k] >= start { start_ri = k; break }
    if start <= 0 do start_ri = 0

    nslots := 2 * (re.ngroups + 1)
    ctx := Re_Ctx{s = runes[:], icase = re.icase, ml = re.multiline, dotall = re.dotall, lb_target = -1, caps = make([]int, nslots, context.temp_allocator)}

    for sp := start_ri; sp <= n; sp += 1 {
        for j in 0 ..< nslots do ctx.caps[j] = -1
        ctx.steps = 0
        if re_backtrack(re.prog, 0, sp, &ctx) {
            g := make([]int, nslots) // byte offsets; caller libera
            for j in 0 ..< nslots {
                g[j] = ctx.caps[j] < 0 ? -1 : boff[ctx.caps[j]]
            }
            return Re_Match{ok = true, groups = g}
        }
        if anchored do break // flag y: só a posição inicial
    }
    return Re_Match{ok = false}
}

// Libera o programa e as strings de um Regex (chamado por vm_destroy).
regex_destroy :: proc(re: ^Regex) {
    re_free_prog(re.prog)
    delete(re.source)
    delete(re.flags)
    if re.gnames != nil {
        for name in re.gnames do delete(name)
        delete(re.gnames)
    }
    free(re)
}

// Libera um programa compilado, recursando nos subprogramas de lookahead.
@(private="file")
re_free_prog :: proc(prog: []Re_Inst) {
    for inst in prog {
        if inst.op == .Class { delete(inst.ranges); delete(inst.nranges); delete(inst.props) }
        if inst.op == .Look do re_free_prog(inst.sub)
    }
    delete(prog)
}

// ── integração com o runtime JS ─────────────────────────────────────────────

install_regex :: proc(vm: ^Interp) {
    vm.regex_test_fn = mk_native(vm, regex_test_native)
    vm.regex_exec_fn = mk_native(vm, regex_exec_native)
    rctor := mk_native(vm, regexp_ctor_native)
    rctor.props = make(map[string]Value)
    rproto := new_object(vm)                       // RegExp.prototype (test/exec genéricos)
    rproto.props["test"]        = vm.regex_test_fn
    rproto.props["exec"]        = vm.regex_exec_fn
    rproto.props["constructor"] = rctor
    rctor.props["prototype"] = rproto
    rctor.name = "RegExp"
    env_define(vm.global, "RegExp", rctor)
}

// new RegExp(padrão, flags) / RegExp(re) — devolve ^Regex. Erro de sintaxe lança.
@(private="file")
regexp_ctor_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // RegExp(regexExistente) devolve/copia a fonte
    pat := ""
    flags := ""
    if r, ok := arg(args, 0).(^Regex); ok {
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
// lastIndex é mantido em RUNES (a unidade dos índices do JS); converte p/ byte
// na hora de rodar. Casamento vazio avança 1 RUNE (não 1 byte).
regex_test_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    re, ok := this.(^Regex)
    if !ok do return false
    s := to_string_value(vm, arg(args, 0))
    stateful := re.global || re.sticky // ambos usam/atualizam lastIndex
    start := stateful ? re.last_index : 0
    if start > str_rlen(s) { re.last_index = 0; return false }
    m := regex_run(re, s, str_rbyte(s, start), re.sticky)
    if !m.ok {
        if stateful do re.last_index = 0
        return false
    }
    defer delete(m.groups)
    if stateful {
        re.last_index = str_rindex(s, m.groups[1])
        if m.groups[1] == m.groups[0] do re.last_index += 1 // casamento vazio: avança
    }
    return true
}

// re.exec(str) -> [casamento, grupo1, ...] ou null. Com g, usa/atualiza lastIndex.
@(private="file")
regex_exec_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    re, ok := this.(^Regex)
    if !ok do return JS_Null{}
    s := to_string_value(vm, arg(args, 0))
    stateful := re.global || re.sticky
    start := stateful ? re.last_index : 0 // em RUNES (ver test)
    if start > str_rlen(s) { re.last_index = 0; return JS_Null{} }
    m := regex_run(re, s, str_rbyte(s, start), re.sticky)
    if !m.ok {
        if stateful do re.last_index = 0
        return JS_Null{}
    }
    defer delete(m.groups)
    if stateful {
        re.last_index = str_rindex(s, m.groups[1])
        if m.groups[1] == m.groups[0] do re.last_index += 1
    }
    return regex_result_array(vm, re, s, m)
}

// Monta o array [casamento inteiro, grupo1, grupo2, ...] (grupo ausente =
// undefined), com .index (offset do casamento, em BYTES como o resto do motor)
// e .input (a string inteira) — usado por exec e str_match sem /g, como na spec.
regex_result_array :: proc(vm: ^Interp, re: ^Regex, s: string, m: Re_Match) -> Value {
    arr := new_array(vm)
    for g in 0 ..= re.ngroups {
        gs := m.groups[2*g]; ge := m.groups[2*g + 1]
        if gs < 0 {
            append(&arr.items, nil) // grupo não capturado => undefined
        } else {
            append(&arr.items, own_str(vm, s[gs:ge]))
        }
    }
    arr.props = make(map[string]Value)
    arr.props["index"] = f64(str_rindex(s, m.groups[0])) // em RUNES (consistente com slice etc.)
    arr.props["input"] = own_str(vm, s)
    if len(re.gnames) > 0 { // grupos nomeados: m.groups.nome
        gobj := new_object(vm)
        for name, gi in re.gnames {
            v: Value = nil
            if gi >= 0 && gi < len(arr.items) do v = arr.items[gi]
            set_member(vm, gobj, own_str(vm, name).(string), v)
        }
        arr.props["groups"] = gobj
    }
    return arr
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
