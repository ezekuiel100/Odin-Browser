package js

// Lexer (tokenizador): código-fonte -> sequência de tokens.
//
// M2 cobre o necessário para statements: números, strings, identificadores,
// operadores aritméticos/comparação e pontuação. Palavras-chave (var, if,
// while, true, ...) saem como Ident e são interpretadas pelo parser.

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Token_Kind :: enum {
    Number,
    Str,        // literal de string
    Regex,      // literal /padrão/flags (text=padrão, flags=flags)
    Ident,      // identificador OU palavra-chave (parser decide)

    Plus,       // +
    Minus,      // -
    Star,       // *
    Slash,      // /
    Percent,    // %

    PlusPlus,   // ++
    MinusMinus, // --
    PlusEq,     // +=
    MinusEq,    // -=
    StarEq,     // *=
    SlashEq,    // /=
    PercentEq,  // %=
    StarStar,   // ** (exponenciação)
    StarStarEq, // **=

    Amp,        // &
    Pipe,       // |
    Caret,      // ^
    Tilde,      // ~
    Shl,        // <<
    Shr,        // >>  (aritmético, preserva sinal)
    UShr,       // >>> (lógico, zero-fill)
    AmpEq,      // &=
    PipeEq,     // |=
    CaretEq,    // ^=
    ShlEq,      // <<=
    ShrEq,      // >>=
    UShrEq,     // >>>=

    Assign,     // =
    EqEq,       // ==
    NotEq,      // !=
    EqEqEq,     // ===
    NotEqEq,    // !==
    Lt,         // <
    Gt,         // >
    LtEq,       // <=
    GtEq,       // >=
    Instanceof, // instanceof (op sintético: o lexer emite Ident, o parser converte)
    In,         // in (op sintético: idem; `"k" in obj`)
    Bang,       // !
    AmpAmp,     // &&
    PipePipe,   // ||
    QQuestion,  // ?? (nullish coalescing)
    AmpAmpEq,   // &&=
    PipePipeEq, // ||=
    QQuestionEq,// ??=
    QDot,       // ?. (optional chaining)
    Question,   // ?
    Arrow,      // =>

    LParen,     // (
    RParen,     // )
    LBrace,     // {
    RBrace,     // }
    LBracket,   // [
    RBracket,   // ]
    Semicolon,  // ;
    Comma,      // ,
    Dot,        // .
    DotDotDot,  // ... (spread/rest)
    Colon,      // :

    // template literal ESTRUTURAL (o parser decide: template normal vira nó
    // .Template; após uma expressão vira tagged template .Tagged). Fluxo:
    //   TplStart Str (TplExprStart <expr> TplExprEnd Str)* TplEnd
    // — os chunks .Str aparecem SEMPRE (vazios inclusive), alternando com as
    // interpolações; o parser conta com essa forma.
    TplStart,     // `
    TplEnd,       // ` de fechamento
    TplExprStart, // ${
    TplExprEnd,   // } que fecha a interpolação

    EOF,
}

Token :: struct {
    kind:      Token_Kind,
    num:       f64,    // válido quando kind == .Number
    text:      string, // Number/Str/Ident/Regex(padrão): fatia do source (não aloca)
    flags:     string, // Regex: flags (g/i/m); fatia do source.
                       // .Str de TEMPLATE: o mesmo trecho SEM escapes decodificados
                       // (`text` é o cozido) — um tagged template precisa dos dois,
                       // e é o que separa String.raw`a\nb` de "a" + quebra + "b".
                       // Reusa este campo em vez de somar um: um `raw` próprio pesava
                       // 16 B em TODO token (medido: +5% de pico no parse de 1 MB de
                       // JS) para servir só aos chunks de template.
    nl_before: bool,   // havia newline entre o token anterior e este (ASI: return/break/continue/throw e ++/-- pós-fixo têm produção restrita)
    is_big:    bool,   // Number com sufixo `n` (BigInt: 123n); text = dígitos SEM o `n`
    // Number: literal legado `010`/`08`; Str: escape octal legado (`\1`, `\08`)
    // ou `\8`/`\9`. Válidos em código sloppy, SyntaxError em strict — quem decide é
    // o parser, que sabe a diretiva. Template: escape inválido p/ template NÃO
    // marcado (octal, `\x` ou `\u` malformado) — erro só se não for tagged.
    legacy_octal: bool,
    bad_escape:   bool, // Str: `\x`/`\u` malformado (template: idem; ver acima)
    off:       i32,    // offset em BYTES do início do token no fonte (mensagem de erro).
                       // Cabe no padding depois dos bools: o Token não cresce.
}

// Primeiro erro LÉXICO do fonte. O lexer não para (o parser precisa de um fluxo
// terminado em EOF), mas o fonte inteiro é SyntaxError: o vm_exec não executa
// nada. msg "" = sem erro. Mensagens no formato que os sites esperam do V8.
Lex_Error :: struct {
    off: int,
    msg: string, // sempre literal estático (não aloca)
}

// Espaço em branco e terminadores de linha FORA do ASCII. Antes todo byte >= 0x80
// era parte de identificador, então um BOM no início do arquivo, um NBSP entre
// tokens ou um U+2028 viravam um identificador fantasma (`<BOM>var`).
// Pula um comentário de linha a partir de `i` até o terminador (exclusive):
// LF, CR, U+2028 ou U+2029.
@(private = "file")
skip_line_comment :: proc(src: string, i: int) -> int {
    j := i
    for j < len(src) && src[j] != '\n' && src[j] != '\r' {
        if src[j] == 0xE2 && j + 2 < len(src) && src[j + 1] == 0x80 && (src[j + 2] == 0xA8 || src[j + 2] == 0xA9) do break
        j += 1
    }
    return j
}

// A `{` que vem agora abre um literal de OBJETO (true) ou um bloco (false)? Decide
// pelo token anterior, como o regex_allowed: se ali cabe uma expressão, é objeto.
@(private = "file")
brace_opens_object :: proc(toks: []Token) -> bool {
    if len(toks) == 0 do return false
    t := toks[len(toks) - 1]
    #partial switch t.kind {
    case .Semicolon, .LBrace, .RBrace, .RParen, .Arrow, .EOF:
        return false
    case .Ident:
        switch t.text {
        case "return", "typeof", "instanceof", "in", "of", "new", "delete",
             "void", "throw", "case", "yield", "await":
            return true
        }
        return false // else/do/try/finally/nome de classe: bloco
    case .Number, .Str, .Regex, .RBracket, .TplEnd:
        return false
    }
    return true // operadores, (, [, ,, =, :, ?, ${
}

@(private = "file")
unicode_space_size :: proc(src: string, i: int) -> int {
    sz, _ := unicode_space_at(src, i)
    return sz
}

@(private = "file")
unicode_space_at :: proc(src: string, i: int) -> (size: int, is_nl: bool) {
    if src[i] < 0x80 do return 0, false
    r, sz := utf8.decode_rune_in_string(src[i:])
    switch r {
    case 0x2028, 0x2029:
        return sz, true
    case 0x00A0, 0xFEFF, 0x1680, 0x2000 ..= 0x200A, 0x202F, 0x205F, 0x3000:
        return sz, false
    }
    return 0, false
}

@(private = "file")
is_ident_start :: proc(c: u8) -> bool {
    // bytes >= 0x80 (continuação/líder UTF-8): identificadores unicode (π, café).
    // Agrupar byte a byte mantém a sequência UTF-8 inteira dentro do lexema.
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80
}

@(private = "file")
is_ident_part :: proc(c: u8) -> bool {
    return is_ident_start(c) || (c >= '0' && c <= '9')
}

// ── identificador com ESCAPE (`ɵinject`) ───────────────────────────────
// A spec aceita `\` UnicodeEscapeSequence em IdentifierStart E IdentifierPart.
// Identificador unicode LITERAL (π, café, ɵ) já funcionava — is_ident_start aceita
// byte >= 0x80; o que faltava era a forma ESCAPADA, e é a que o Angular usa: os
// nomes Ivy são compilados como `ɵɵinject` (= `ɵɵinject`). Sem isto a
// '\' caía no "caractere desconhecido" e UM nome virava DOIS Idents (`u0275` +
// `u0275inject`) — 31 recuperações de parse só no angular.dev.
//
// ⚠️ desvio conhecido: palavra-chave escapada (`if` = `if`) aqui vira a
// palavra-chave; a spec manda que NÃO seja tratada como tal. Ninguém escreve isso
// fora de teste de conformidade, e o caminho antigo (descartar a barra) era pior.
@(private = "file")
ident_escape_at :: proc(src: string, i: int) -> bool {
    return i + 1 < len(src) && src[i] == '\\' && src[i + 1] == 'u'
}

// O caractere de um escape em identificador tem de ser ele mesmo de identificador:
// `\u007B` (`{`), `\u000A` (quebra de linha), `\u0023` (`#`) NÃO viram pontuação —
// são SyntaxError. (Dígito é aceito aqui; no INÍCIO do nome o chamador recusa.)
@(private = "file")
escaped_ident_char :: proc(r: rune) -> bool {
    if r >= 0x80 do return r != 0x2028 && r != 0x2029 && r != 0xFEFF && r != 0xA0
    c := u8(r)
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$'
}

// Lê o escape em `i` (que aponta para a '\'), juntando par surrogate como o
// decode_escapes das strings. ok=false se malformado (aí não é identificador).
@(private = "file")
read_ident_escape :: proc(src: string, i: int) -> (r: rune, next: int, ok: bool) {
    if !ident_escape_at(src, i) do return 0, i, false
    if i + 2 < len(src) && src[i + 2] == '{' { // \u{1F600}
        if v, n, k := read_hex(src, i + 3, 6); k && i + 3 + n < len(src) && src[i + 3 + n] == '}' && v <= 0x10FFFF {
            if !escaped_ident_char(rune(v)) do return 0, i, false
            return rune(v), i + 4 + n, true
        }
        return 0, i, false
    }
    v, n, k := read_hex(src, i + 2, 4)
    if !k || n != 4 do return 0, i, false
    if !escaped_ident_char(rune(v)) do return 0, i, false
    j := i + 6
    if v >= 0xD800 && v <= 0xDBFF && j + 1 < len(src) && src[j] == '\\' && src[j + 1] == 'u' {
        if lo, n2, k2 := read_hex(src, j + 2, 4); k2 && n2 == 4 && lo >= 0xDC00 && lo <= 0xDFFF {
            return rune(0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)), j + 6, true
        }
    }
    return rune(v), j, true
}

// Varre um identificador a partir de `start_i` (num IdentifierStart OU num escape).
// SEM escape devolve a FATIA CRUA do fonte (caminho comum, zero alocação); COM
// escape devolve o nome DECODIFICADO, registrado em `owned` — tem de ser o
// decodificado, senão `ɵx` e `ɵx` seriam variáveis DIFERENTES.
// `next == start_i` significa escape malformado: o chamador não deve tratar como
// identificador (e precisa avançar por conta, senão trava o lexer).
@(private = "file")
lex_ident_run :: proc(src: string, start_i: int, owned: ^[dynamic]string) -> (text: string, next: int, escaped: bool) {
    i := start_i
    for i < len(src) {
        if ident_escape_at(src, i) {
            if r, nx, ok := read_ident_escape(src, i); ok {
                if i == start_i && r >= '0' && r <= '9' do break // `\u0031x`: dígito não inicia nome
                escaped = true
                i = nx
                continue
            }
            break
        }
        if !is_ident_part(src[i]) do break
        if sz, _ := unicode_space_at(src, i); sz > 0 do break // NBSP/BOM/LS não são parte do nome
        i += 1
    }
    if !escaped do return src[start_i:i], i, false
    sb := strings.builder_make()
    j := start_i
    for j < i {
        if ident_escape_at(src, j) {
            if r, nx, ok := read_ident_escape(src, j); ok {
                strings.write_rune(&sb, r)
                j = nx
                continue
            }
        }
        strings.write_byte(&sb, src[j])
        j += 1
    }
    out := strings.to_string(sb)
    append(owned, out)
    return out, i, true
}

// Decide se um `/` inicia um literal de regex (true) ou é divisão (false), pelo
// token ANTERIOR: regex é permitida quando o que veio antes espera uma expressão
// (operadores, `(`, `[`, `,`, `=`, palavras-chave como return/typeof, ou nada).
// `after_ctl_rparen`: o último `)` fechou um cabeçalho de if/while/for/switch —
// aí um `/` inicia REGEX (`if (ok) /re/.test(s)`), não divisão.
@(private = "file")
regex_allowed :: proc(toks: []Token, after_ctl_rparen: bool, after_obj_rbrace := false) -> bool {
    if len(toks) == 0 do return true
    t := toks[len(toks) - 1]
    #partial switch t.kind {
    case .RParen:
        return after_ctl_rparen
    case .RBrace:
        // `}` que fechou um LITERAL de objeto termina uma expressão (`{...} / 2` é
        // divisão); o que fechou um bloco não (`}` + quebra + `/re/.test(s)` é regex)
        return !after_obj_rbrace
    case .Number, .Str, .Regex, .RBracket, .PlusPlus, .MinusMinus, .TplEnd:
        return false // esses TERMINAM uma expressão => `/` é divisão
    case .Ident:
        // palavra-chave que precede expressão => regex; variável/this/true/... => divisão
        switch t.text {
        // (`of` NÃO entra: fora do cabeçalho de for é identificador comum — `a/of/g`)
        case "return", "typeof", "instanceof", "in", "new", "delete",
             "void", "throw", "do", "else", "case", "yield", "await":
            return true
        }
        return false
    }
    return true // operadores, (, [, {, ,, ;, =, :, ?, => etc.
}

// Escaneia um literal /padrão/flags a partir de src[i]=='/'. O `/` não fecha
// dentro de uma classe [...]; `\` escapa o próximo char. Emite Token .Regex.
@(private = "file")
lex_regex :: proc(toks: ^[dynamic]Token, src: string, i: int) -> (next: int, closed: bool) {
    j := i + 1
    in_class := false
    for j < len(src) {
        ch := src[j]
        if ch == '\\' {                       // char escapado (pula o próximo)
            if j + 1 < len(src) && (src[j + 1] == '\n' || src[j + 1] == '\r') do break
            j += 2; continue
        }
        if ch == '\n' || ch == '\r' { break } // não terminado
        if ch == 0xE2 && j + 2 < len(src) && src[j + 1] == 0x80 && (src[j + 2] == 0xA8 || src[j + 2] == 0xA9) { break }
        if ch == '[' { in_class = true }
        else if ch == ']' { in_class = false }
        else if ch == '/' && !in_class { break }
        j += 1
    }
    pattern := src[i + 1:min(j, len(src))]
    k := j
    if k < len(src) && src[k] == '/' { k += 1; closed = true } // fecha
    fstart := k
    for k < len(src) && is_ident_part(src[k]) && src[k] < 0x80 do k += 1
    append(toks, Token{kind = .Regex, text = pattern, flags = src[fstart:k]})
    return k, closed
}

// '_' é separador de dígitos (1_000_000) quando está ENTRE dois dígitos —
// senão pertence a um identificador vizinho e o scan para.
@(private = "file")
is_digit_sep :: proc(src: string, i: int) -> bool {
    if src[i] != '_' do return false
    if i == 0 || i + 1 >= len(src) do return false
    prev := src[i - 1]
    next := src[i + 1]
    prev_ok := (prev >= '0' && prev <= '9') || is_base_digit(prev)
    next_ok := (next >= '0' && next <= '9') || is_base_digit(next)
    return prev_ok && next_ok
}

// Separador em literal DECIMAL: `_` entre dois dígitos 0-9 (`1_000`; `0_e` não).
@(private = "file")
dec_sep :: proc(src: string, i: int) -> bool {
    if src[i] != '_' || i == 0 || i + 1 >= len(src) do return false
    p, n := src[i - 1], src[i + 1]
    return p >= '0' && p <= '9' && n >= '0' && n <= '9'
}

// Remove os '_' de um lexema numérico p/ o strconv (só aloca se houver algum).
@(private = "file")
strip_seps :: proc(lexeme: string, buf: []u8) -> string {
    n := 0
    for k := 0; k < len(lexeme); k += 1 {
        if lexeme[k] == '_' do continue
        if n >= len(buf) do break
        buf[n] = lexeme[k]
        n += 1
    }
    return string(buf[:n])
}

@(private = "file")
lex_number :: proc(toks: ^[dynamic]Token, src: string, start: int) -> (next: int, ok: bool) {
    i := start
    has_sep := false
    ok = true
    // bases: 0x / 0b / 0o (parse_int com base 0 detecta o prefixo)
    if src[i] == '0' && i + 1 < len(src) {
        c := src[i + 1]
        if c == 'x' || c == 'X' || c == 'b' || c == 'B' || c == 'o' || c == 'O' {
            base := 16
            if c == 'b' || c == 'B' do base = 2
            if c == 'o' || c == 'O' do base = 8
            i += 2
            nd := 0
            for i < len(src) && (is_base_digit(src[i]) || is_digit_sep(src, i)) {
                if src[i] == '_' {
                    has_sep = true
                } else {
                    if digit_value(src[i]) >= base do ok = false // 0b2 / 0o8
                    nd += 1
                }
                i += 1
            }
            if nd == 0 do ok = false // `0x` sem dígito
            if i < len(src) && src[i] == '_' do ok = false // `0x1_` / `0b1__0`
            lexeme := src[start:i]
            parse_src := lexeme
            buf: [96]u8
            if has_sep do parse_src = strip_seps(lexeme, buf[:])
            v: f64
            if ok { // acumula em f64: hex de 20 dígitos não cabe em i64 (parse_int saturava)
                for ch in parse_src[2:] do v = v * f64(base) + f64(digit_value(u8(ch)))
            }
            i2, big := eat_bigint_n(src, i)
            if i2 < len(src) && (is_ident_start(src[i2]) || (src[i2] >= '0' && src[i2] <= '9')) do ok = false // 0x1g / 3in
            append(toks, Token{kind = .Number, num = v, text = lexeme, is_big = big})
            return i2, ok
        }
        if c == '_' do ok = false // `0_1`: separador logo após o 0 inicial
        // octal LEGADO (`010` = 8) e decimal com zero à esquerda (`08` = 8): só sloppy.
        if c >= '0' && c <= '9' {
            j := i + 1
            octal := true
            for j < len(src) && src[j] >= '0' && src[j] <= '9' {
                if src[j] >= '8' do octal = false
                j += 1
            }
            if octal {
                v: f64
                for k in i + 1 ..< j do v = v * 8 + f64(src[k] - '0')
                if j < len(src) && (is_ident_start(src[j]) || src[j] == '_' || src[j] == '.') do ok = false // 01n / 07.5 / 01_0
                append(toks, Token{kind = .Number, num = v, text = src[start:j], legacy_octal = true})
                return j, ok
            }
            // NonOctalDecimalIntegerLiteral (`089`): decimal, mas legado (strict proíbe)
            nxt, nok := lex_decimal(toks, src, start)
            toks[len(toks) - 1].legacy_octal = true
            if toks[len(toks) - 1].is_big do nok = false // 08n
            if strings.index_byte(toks[len(toks) - 1].text, '_') >= 0 do nok = false // 08_0
            return nxt, nok
        }
    }
    return lex_decimal(toks, src, start)
}

@(private = "file")
digit_value :: proc(c: u8) -> int {
    switch {
    case c >= '0' && c <= '9': return int(c - '0')
    case c >= 'a' && c <= 'f': return int(c - 'a') + 10
    case c >= 'A' && c <= 'F': return int(c - 'A') + 10
    }
    return 99
}

@(private = "file")
lex_decimal :: proc(toks: ^[dynamic]Token, src: string, start: int) -> (next: int, ok: bool) {
    i := start
    has_sep := false
    ok = true
    // decimal: dígitos, NO MÁXIMO um ponto, expoente científico (1e3, 1.5e-10)
    // e separadores 1_000_000. O segundo '.' pertence ao acesso a membro:
    // `100..toString(2)` é (100.).toString.
    seen_dot := false
    has_exp := false
    for i < len(src) && ((src[i] >= '0' && src[i] <= '9') || (src[i] == '.' && !seen_dot) || dec_sep(src, i)) {
        if src[i] == '.' {
            seen_dot = true
            if i + 1 < len(src) && src[i + 1] == '_' do ok = false // 1._5
        }
        if src[i] == '_' do has_sep = true
        i += 1
    }
    if i < len(src) && (src[i] == 'e' || src[i] == 'E') {
        j := i + 1
        if j < len(src) && (src[j] == '+' || src[j] == '-') do j += 1
        if j < len(src) && src[j] >= '0' && src[j] <= '9' { // só é expoente se houver dígito
            i = j
            has_exp = true
            for i < len(src) && ((src[i] >= '0' && src[i] <= '9') || dec_sep(src, i)) {
                if src[i] == '_' do has_sep = true
                i += 1
            }
        }
    }
    if i < len(src) && src[i] == '_' do ok = false // `1_` / `1__0` / `1_.5` / `1_e2`
    lexeme := src[start:i]
    parse_src := lexeme
    sep_buf: [dynamic]u8
    defer delete(sep_buf)
    if has_sep {
        for k in 0 ..< len(lexeme) do if lexeme[k] != '_' do append(&sep_buf, lexeme[k])
        parse_src = string(sep_buf[:])
    }
    val, pok := strconv.parse_f64(parse_src)
    if !pok && len(parse_src) > 1 && parse_src[len(parse_src) - 1] == '.' {
        val, _ = strconv.parse_f64(parse_src[:len(parse_src) - 1]) // "100." → 100
    }
    i2, big := eat_bigint_n(src, i)
    if big && (seen_dot || has_exp) do ok = false // 1.5n / 1e3n
    // literal numérico colado em identificador ou dígito: `3in`, `1e`, `1_`, `5..`? não
    // (o `.` extra é membro), mas `3x` é SyntaxError (spec: o caractere seguinte a um
    // NumericLiteral não pode ser IdentifierStart nem DecimalDigit).
    if i2 < len(src) && (is_ident_start(src[i2]) || src[i2] == '\\') {
        if sz, _ := unicode_space_at(src, i2); sz == 0 do ok = false
    }
    append(toks, Token{kind = .Number, num = val, text = lexeme, is_big = big})
    return i2, ok
}

// Sufixo `n` de BigInt (10n, 0xFFn): consome o `n` e sinaliza is_big=true. O
// `text` do token fica com os dígitos SEM o `n` (parseados exato em bigint.odin).
@(private = "file")
eat_bigint_n :: proc(src: string, i: int) -> (int, bool) {
    if i < len(src) && src[i] == 'n' && (i + 1 >= len(src) || !is_ident_part(src[i + 1])) {
        return i + 1, true
    }
    return i, false
}

// Dígito de qualquer base numérica (hex/bin/octal/dec) — usado só para varrer o
// lexema; a validação real fica com strconv.parse_int.
@(private = "file")
is_base_digit :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// Lê até `max_digits` dígitos hex a partir de s[i]. Devolve o valor, quantos
// dígitos consumiu e se leu pelo menos um.
@(private = "file")
read_hex :: proc(s: string, i: int, max_digits: int) -> (val: int, n: int, ok: bool) {
    for n < max_digits && i + n < len(s) {
        c := s[i + n]
        d: int
        switch {
        case c >= '0' && c <= '9': d = int(c - '0')
        case c >= 'a' && c <= 'f': d = int(c - 'a') + 10
        case c >= 'A' && c <= 'F': d = int(c - 'A') + 10
        case: return val, n, n > 0
        }
        val = val * 16 + d
        n += 1
    }
    return val, n, n > 0
}

// Decodifica escapes de um literal de string: \n \t \r \b \f \v \0, \xNN,
// \uNNNN (com par surrogate \uD8xx\uDCxx combinado), \u{...}, continuação de
// linha (\ + newline vira nada) e \\ \' \" \` \$ literais.
// Caminho rápido: sem barra invertida, devolve a própria fatia (não aloca).
// Com escapes, aloca a string decodificada e a registra em `owned` — o
// chamador (vm_run) transfere a posse para o vm, que vive tanto quanto a AST.
@(private = "file")
decode_escapes :: proc(s: string, owned: ^[dynamic]string, octal: ^bool = nil, bad: ^bool = nil) -> string {
    if strings.index_byte(s, '\\') < 0 do return s
    sb := strings.builder_make()
    i := 0
    for i < len(s) {
        c := s[i]
        if c == '\\' && i + 1 < len(s) {
            switch s[i + 1] {
            case 'n':  strings.write_byte(&sb, '\n'); i += 2
            case 't':  strings.write_byte(&sb, '\t'); i += 2
            case 'r':  strings.write_byte(&sb, '\r'); i += 2
            case 'b':  strings.write_byte(&sb, 0x08); i += 2
            case 'f':  strings.write_byte(&sb, 0x0C); i += 2
            case 'v':  strings.write_byte(&sb, 0x0B); i += 2
            case '0' ..= '7':
                // `\0` não seguido de dígito é NUL (válido em strict). O resto é
                // escape OCTAL legado (`\101` = "A"), só sloppy — antes `\1` virava
                // o caractere "1" literal.
                if s[i + 1] == '0' && !(i + 2 < len(s) && s[i + 2] >= '0' && s[i + 2] <= '9') {
                    strings.write_byte(&sb, 0); i += 2
                    continue
                }
                if octal != nil do octal^ = true
                maxd := 3 if s[i + 1] <= '3' else 2
                v := 0
                j := i + 1
                for j < len(s) && j < i + 1 + maxd && s[j] >= '0' && s[j] <= '7' {
                    v = v * 8 + int(s[j] - '0')
                    j += 1
                }
                strings.write_rune(&sb, rune(v))
                i = j
            case '8', '9': // NonOctalDecimalEscapeSequence: o próprio dígito, só sloppy
                if octal != nil do octal^ = true
                strings.write_byte(&sb, s[i + 1]); i += 2
            case '\n': i += 2                       // continuação de linha: some
            case '\r': i += 2; if i < len(s) && s[i] == '\n' do i += 1 // \<CRLF>
            case 'x':
                if v, n, ok := read_hex(s, i + 2, 2); ok && n == 2 {
                    strings.write_rune(&sb, rune(v))
                    i += 4
                } else { // \x malformado: SyntaxError (o parser decide; template tagged tolera)
                    if bad != nil do bad^ = true
                    strings.write_byte(&sb, 'x'); i += 2
                }
            case 'u':
                if i + 2 < len(s) && s[i + 2] == '{' { // \u{1F600}
                    if v, n, ok := read_hex(s, i + 3, 6); ok && i + 3 + n < len(s) && s[i + 3 + n] == '}' && v <= 0x10FFFF {
                        strings.write_rune(&sb, rune(v))
                        i += 4 + n
                        continue
                    }
                    if bad != nil do bad^ = true
                    strings.write_byte(&sb, 'u'); i += 2
                    continue
                }
                v, n, ok := read_hex(s, i + 2, 4)
                if !ok || n != 4 { // \u malformado: SyntaxError
                    if bad != nil do bad^ = true
                    strings.write_byte(&sb, 'u'); i += 2
                    continue
                }
                i += 6
                // par surrogate: \uD800-\uDBFF seguido de \uDC00-\uDFFF vira um code point
                if v >= 0xD800 && v <= 0xDBFF && i + 1 < len(s) && s[i] == '\\' && s[i + 1] == 'u' {
                    if lo, n2, ok2 := read_hex(s, i + 2, 4); ok2 && n2 == 4 && lo >= 0xDC00 && lo <= 0xDFFF {
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                        i += 6
                    }
                }
                strings.write_rune(&sb, rune(v))
            case:
                strings.write_byte(&sb, s[i + 1]) // \\ \' \" \` \$ e desconhecidos: literal
                i += 2
            }
        } else {
            strings.write_byte(&sb, c)
            i += 1
        }
    }
    out := strings.to_string(sb) // fica dona do buffer do builder
    append(owned, out)
    return out
}

// Emite o trecho LITERAL de um template a partir de `i` (logo após ` ou }):
// um token .Str (mesmo vazio) e o delimitador que o encerra — .TplEnd no `
// final ou .TplExprStart no ${ (que empilha em interp_braces; o loop principal
// tokeniza a expressão normalmente e o '}' de profundidade 0 emite .TplExprEnd).
// Retorna o novo índice.
@(private = "file")
lex_template_chunk :: proc(toks: ^[dynamic]Token, src: string, start_i: int, interp_braces: ^[dynamic]int, owned: ^[dynamic]string) -> (next: int, closed: bool) {
    i := start_i
    start := i
    chunk :: proc(toks: ^[dynamic]Token, raw: string, owned: ^[dynamic]string) {
        oct, bad: bool
        cooked := decode_escapes(raw, owned, &oct, &bad)
        // template: QUALQUER escape octal (inclusive `\0` seguido de dígito) é
        // inválido — vale p/ o parser só se o template não for tagged.
        append(toks, Token{kind = .Str, text = cooked, flags = raw, bad_escape = bad || oct})
    }
    for i < len(src) {
        if src[i] == '\\' && i + 1 < len(src) {
            i += 2 // \` e \${ escapados não terminam/abrem nada
            continue
        }
        if src[i] == '`' {
            chunk(toks, src[start:i], owned)
            append(toks, Token{kind = .TplEnd})
            return i + 1, true
        }
        if src[i] == '$' && i + 1 < len(src) && src[i + 1] == '{' {
            chunk(toks, src[start:i], owned)
            append(toks, Token{kind = .TplExprStart})
            append(interp_braces, 0) // '}' com profundidade 0 fecha esta interpolação
            return i + 2, true
        }
        i += 1
    }
    // template sem crase de fechamento: SyntaxError (o fluxo de tokens fecha mesmo
    // assim, p/ o parser terminar)
    chunk(toks, src[start:i], owned)
    append(toks, Token{kind = .TplEnd})
    return i, false
}

// Quebra `src` inteiro em tokens, terminando sempre em .EOF.
// As fatias `text` apontam para dentro de `src` (não alocam).
//
// Template literals são AÇUCARADOS aqui mesmo: `a${x}b` vira o fluxo
//   ( "" + "a" + ( x ) + "b" )
// — o parser/interp nem sabem que templates existem. O "" inicial garante
// concatenação de string mesmo quando as partes são números (`${1}${2}`="12").
// `owned` devolve as strings ALOCADAS por escapes (\n etc.) — o chamador deve
// mantê-las vivas enquanto a AST viver (vm_run as transfere p/ o vm) e liberá-las.
// `bad` devolve quantos caracteres foram IGNORADOS por serem desconhecidos —
// em fonte válido deve ser 0 (conta como recuperação silenciosa nos testes).
tokenize :: proc(src: string, module := false) -> (toks: [dynamic]Token, owned: [dynamic]string, bad: int, lerr: Lex_Error) {
    interp_braces: [dynamic]int // profundidade de {} por interpolação ${} aberta
    defer delete(interp_braces)
    // pilha paralela aos `(`: true se o paren abriu um cabeçalho if/while/for/switch
    // (aí `/` logo após o `)` correspondente inicia regex). Mantida no hook do fim
    // do loop, que vê TODOS os tokens emitidos (inclusive os sintéticos de template).
    ctl_paren: [dynamic]bool
    defer delete(ctl_paren)
    last_rparen_ctl := false
    // pilha paralela às `{`: true se a chave abriu um LITERAL de objeto (posição de
    // expressão) — decide se `/` depois do `}` correspondente é divisão ou regex
    brace_obj: [dynamic]bool
    defer delete(brace_obj)
    last_rbrace_obj := false
    i := 0
    saw_nl := false // houve newline desde o último token emitido (vira nl_before do próximo)
    fail :: proc(lerr: ^Lex_Error, off: int, msg: string) {
        if lerr.msg == "" do lerr^ = Lex_Error{off = off, msg = msg}
    }
    // hashbang (`#!/usr/bin/env node`) só na posição 0: comentário de linha (ES2023)
    if len(src) >= 2 && src[0] == '#' && src[1] == '!' {
        i = skip_line_comment(src, i)
    }
    for i < len(src) {
        c := src[i]
        mark := len(toks)
        tok_start := i
        switch {
        case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C:
            if c == '\n' || c == '\r' do saw_nl = true
            i += 1
        case c >= 0x80 && unicode_space_size(src, i) > 0:
            sz, nl := unicode_space_at(src, i)
            if nl do saw_nl = true
            i += sz
        case c == '/' && i + 1 < len(src) && src[i + 1] == '/':
            // comentário de linha: pula até o fim da linha (U+2028/2029 também terminam)
            i = skip_line_comment(src, i)
        // comentários estilo HTML (Annex B, só em script): `<!--` em qualquer lugar e
        // `-->` no início de linha abrem comentário de linha. Página antiga embrulha o
        // <script> inteiro em `<!-- ... //-->`; sem isto era tudo erro de sintaxe.
        case !module && c == '<' && i + 3 < len(src) && src[i + 1] == '!' && src[i + 2] == '-' && src[i + 3] == '-':
            i = skip_line_comment(src, i)
        case !module && c == '-' && (saw_nl || len(toks) == 0) && i + 2 < len(src) && src[i + 1] == '-' && src[i + 2] == '>':
            i = skip_line_comment(src, i)
        case c == '/' && i + 1 < len(src) && src[i + 1] == '*':
            // comentário de bloco: pula até */ (newline interno conta p/ ASI)
            i += 2
            for i + 1 < len(src) && !(src[i] == '*' && src[i + 1] == '/') {
                if src[i] == '\n' || src[i] == '\r' do saw_nl = true
                if sz, nl := unicode_space_at(src, i); nl && sz > 0 do saw_nl = true
                i += 1
            }
            if i + 1 >= len(src) do fail(&lerr, tok_start, "Invalid or unexpected token") // /* sem */
            i = min(i + 2, len(src))
        case c == '(': append(&toks, Token{kind = .LParen});    i += 1
        case c == ')': append(&toks, Token{kind = .RParen});    i += 1
        case c == '`':
            append(&toks, Token{kind = .TplStart})
            closed: bool
            i, closed = lex_template_chunk(&toks, src, i + 1, &interp_braces, &owned)
            if !closed do fail(&lerr, tok_start, "Unterminated template literal")
        case c == '{':
            if len(interp_braces) > 0 do interp_braces[len(interp_braces) - 1] += 1
            append(&brace_obj, brace_opens_object(toks[:]))
            append(&toks, Token{kind = .LBrace}); i += 1
        case c == '}':
            if n := len(interp_braces); n > 0 && interp_braces[n - 1] == 0 {
                // fecha a interpolação ${...} e volta a lexar o trecho literal
                pop(&interp_braces)
                append(&toks, Token{kind = .TplExprEnd})
                closed: bool
                i, closed = lex_template_chunk(&toks, src, i + 1, &interp_braces, &owned)
                if !closed do fail(&lerr, tok_start, "Unterminated template literal")
            } else {
                if n > 0 do interp_braces[n - 1] -= 1
                last_rbrace_obj = len(brace_obj) > 0 && pop(&brace_obj)
                append(&toks, Token{kind = .RBrace}); i += 1
            }
        case c == '[': append(&toks, Token{kind = .LBracket}); i += 1
        case c == ']': append(&toks, Token{kind = .RBracket}); i += 1
        case c == ':': append(&toks, Token{kind = .Colon});     i += 1
        case c == ';': append(&toks, Token{kind = .Semicolon}); i += 1
        case c == ',': append(&toks, Token{kind = .Comma});     i += 1
        case c == '+':
            if i + 1 < len(src) && src[i + 1] == '+' {
                append(&toks, Token{kind = .PlusPlus}); i += 2
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .PlusEq}); i += 2
            } else {
                append(&toks, Token{kind = .Plus}); i += 1
            }
        case c == '-':
            if i + 1 < len(src) && src[i + 1] == '-' {
                append(&toks, Token{kind = .MinusMinus}); i += 2
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .MinusEq}); i += 2
            } else {
                append(&toks, Token{kind = .Minus}); i += 1
            }
        case c == '*':
            if i + 1 < len(src) && src[i + 1] == '*' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .StarStarEq}); i += 3
                } else {
                    append(&toks, Token{kind = .StarStar}); i += 2
                }
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .StarEq}); i += 2
            } else {
                append(&toks, Token{kind = .Star}); i += 1
            }
        case c == '/':
            if regex_allowed(toks[:], last_rparen_ctl, last_rbrace_obj) {
                closed: bool
                i, closed = lex_regex(&toks, src, i)
                if !closed do fail(&lerr, tok_start, "Invalid regular expression: missing /")
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .SlashEq}); i += 2
            } else {
                append(&toks, Token{kind = .Slash}); i += 1
            }
        case c == '%':
            if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .PercentEq}); i += 2
            } else {
                append(&toks, Token{kind = .Percent}); i += 1
            }
        case c == '.':
            if i + 2 < len(src) && src[i + 1] == '.' && src[i + 2] == '.' {
                append(&toks, Token{kind = .DotDotDot}); i += 3 // spread/rest
            } else if i + 1 < len(src) && src[i + 1] >= '0' && src[i + 1] <= '9' {
                nok: bool
                i, nok = lex_number(&toks, src, i) // número tipo .5
                if !nok do fail(&lerr, tok_start, "Invalid or unexpected token")
            } else {
                append(&toks, Token{kind = .Dot}); i += 1
            }
        case c == '=':
            if i + 1 < len(src) && src[i + 1] == '>' {
                append(&toks, Token{kind = .Arrow}); i += 2
            } else if i + 2 < len(src) && src[i + 1] == '=' && src[i + 2] == '=' {
                append(&toks, Token{kind = .EqEqEq}); i += 3
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .EqEq}); i += 2
            } else {
                append(&toks, Token{kind = .Assign}); i += 1
            }
        case c == '!':
            if i + 2 < len(src) && src[i + 1] == '=' && src[i + 2] == '=' {
                append(&toks, Token{kind = .NotEqEq}); i += 3
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .NotEq}); i += 2
            } else {
                append(&toks, Token{kind = .Bang}); i += 1
            }
        case c == '&':
            if i + 1 < len(src) && src[i + 1] == '&' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .AmpAmpEq}); i += 3
                } else {
                    append(&toks, Token{kind = .AmpAmp}); i += 2
                }
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .AmpEq}); i += 2
            } else {
                append(&toks, Token{kind = .Amp}); i += 1 // bitwise AND
            }
        case c == '|':
            if i + 1 < len(src) && src[i + 1] == '|' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .PipePipeEq}); i += 3
                } else {
                    append(&toks, Token{kind = .PipePipe}); i += 2
                }
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .PipeEq}); i += 2
            } else {
                append(&toks, Token{kind = .Pipe}); i += 1 // bitwise OR
            }
        case c == '^':
            if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .CaretEq}); i += 2
            } else {
                append(&toks, Token{kind = .Caret}); i += 1 // bitwise XOR
            }
        case c == '~':
            append(&toks, Token{kind = .Tilde}); i += 1 // bitwise NOT (unário)
        case c == '?':
            if i + 1 < len(src) && src[i + 1] == '?' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .QQuestionEq}); i += 3 // ??=
                } else {
                    append(&toks, Token{kind = .QQuestion}); i += 2 // ??
                }
            } else if i + 1 < len(src) && src[i + 1] == '.' && !(i + 2 < len(src) && src[i + 2] >= '0' && src[i + 2] <= '9') {
                append(&toks, Token{kind = .QDot}); i += 2 // ?.  (mas ?.5 é ternário + .5)
            } else {
                append(&toks, Token{kind = .Question}); i += 1
            }
        case c == '<':
            if i + 1 < len(src) && src[i + 1] == '<' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .ShlEq}); i += 3
                } else {
                    append(&toks, Token{kind = .Shl}); i += 2
                }
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .LtEq}); i += 2
            } else {
                append(&toks, Token{kind = .Lt}); i += 1
            }
        case c == '>':
            if i + 2 < len(src) && src[i + 1] == '>' && src[i + 2] == '>' {
                if i + 3 < len(src) && src[i + 3] == '=' {
                    append(&toks, Token{kind = .UShrEq}); i += 4
                } else {
                    append(&toks, Token{kind = .UShr}); i += 3
                }
            } else if i + 1 < len(src) && src[i + 1] == '>' {
                if i + 2 < len(src) && src[i + 2] == '=' {
                    append(&toks, Token{kind = .ShrEq}); i += 3
                } else {
                    append(&toks, Token{kind = .Shr}); i += 2
                }
            } else if i + 1 < len(src) && src[i + 1] == '=' {
                append(&toks, Token{kind = .GtEq}); i += 2
            } else {
                append(&toks, Token{kind = .Gt}); i += 1
            }
        case c == '"' || c == '\'':
            quote := c
            i += 1
            start := i
            for i < len(src) && src[i] != quote && src[i] != '\n' && src[i] != '\r' {
                if src[i] == '\\' && i + 1 < len(src) {
                    i += 1 // pula o char escapado (\<CRLF> é continuação de linha)
                    if src[i] == '\r' && i + 1 < len(src) && src[i + 1] == '\n' do i += 1
                }
                i += 1
            }
            oct, badesc: bool
            append(&toks, Token{kind = .Str, text = decode_escapes(src[start:min(i, len(src))], &owned, &oct, &badesc), legacy_octal = oct, bad_escape = badesc})
            if i < len(src) && src[i] == quote {
                i += 1 // consome a aspa de fechamento
            } else {
                fail(&lerr, tok_start, "Invalid or unexpected token") // string não terminada
            }
        case c >= '0' && c <= '9':
            nok: bool
            i, nok = lex_number(&toks, src, i)
            if !nok do fail(&lerr, tok_start, "Invalid or unexpected token")
        case c == '#' && i + 1 < len(src) && (is_ident_start(src[i + 1]) || ident_escape_at(src, i + 1)):
            // nome privado de classe (#x): um Ident cujo texto INCLUI o '#'.
            // Vira uma chave de propriedade "#x" que nunca enumera (ver is_private_key).
            start := i
            name, nx, esc := lex_ident_run(src, i + 1, &owned)
            if nx == i + 1 { // escape malformado logo após o '#'
                bad += 1
                fail(&lerr, tok_start, "Invalid or unexpected token")
                i += 1
                break
            }
            i = nx
            if esc { // com escape o '#' tem de ser RECOLADO no nome decodificado
                joined := strings.concatenate({"#", name})
                append(&owned, joined)
                append(&toks, Token{kind = .Ident, text = joined})
            } else {
                append(&toks, Token{kind = .Ident, text = src[start:i]})
            }
        case is_ident_start(c) || ident_escape_at(src, i):
            name, nx, esc := lex_ident_run(src, i, &owned)
            if nx == i { // `\u` malformado: não é identificador, cai no descarte
                bad += 1
                fail(&lerr, tok_start, "Invalid or unexpected token")
                i += 1
                break
            }
            i = nx
            append(&toks, Token{kind = .Ident, text = name, bad_escape = esc})
        case:
            bad += 1
            fail(&lerr, tok_start, "Invalid or unexpected token")
            i += 1 // caractere desconhecido: ignora (contabilizado em `bad`)
        }
        if saw_nl && len(toks) > mark {
            toks[mark].nl_before = true // primeiro token emitido após o(s) newline(s)
            saw_nl = false
        }
        for ti in mark ..< len(toks) do toks[ti].off = i32(tok_start)
        // mantém a pilha de parens de controle sobre TODOS os tokens emitidos
        for ti in mark ..< len(toks) {
            #partial switch toks[ti].kind {
            case .LParen:
                is_ctl := false
                if ti > 0 && toks[ti - 1].kind == .Ident {
                    switch toks[ti - 1].text {
                    case "if", "while", "for", "switch": is_ctl = true
                    }
                }
                append(&ctl_paren, is_ctl)
            case .RParen:
                last_rparen_ctl = false
                if n := len(ctl_paren); n > 0 {
                    last_rparen_ctl = ctl_paren[n - 1]
                    pop(&ctl_paren)
                }
            }
        }
    }
    append(&toks, Token{kind = .EOF, nl_before = saw_nl, off = i32(len(src))})
    return toks, owned, bad, lerr
}
