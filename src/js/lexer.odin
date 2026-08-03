package js

// Lexer (tokenizador): código-fonte -> sequência de tokens.
//
// M2 cobre o necessário para statements: números, strings, identificadores,
// operadores aritméticos/comparação e pontuação. Palavras-chave (var, if,
// while, true, ...) saem como Ident e são interpretadas pelo parser.

import "core:strconv"
import "core:strings"

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

// Lê o escape em `i` (que aponta para a '\'), juntando par surrogate como o
// decode_escapes das strings. ok=false se malformado (aí não é identificador).
@(private = "file")
read_ident_escape :: proc(src: string, i: int) -> (r: rune, next: int, ok: bool) {
    if !ident_escape_at(src, i) do return 0, i, false
    if i + 2 < len(src) && src[i + 2] == '{' { // \u{1F600}
        if v, n, k := read_hex(src, i + 3, 6); k && i + 3 + n < len(src) && src[i + 3 + n] == '}' && v <= 0x10FFFF {
            return rune(v), i + 4 + n, true
        }
        return 0, i, false
    }
    v, n, k := read_hex(src, i + 2, 4)
    if !k || n != 4 do return 0, i, false
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
            if _, nx, ok := read_ident_escape(src, i); ok {
                escaped = true
                i = nx
                continue
            }
            break
        }
        if !is_ident_part(src[i]) do break
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
regex_allowed :: proc(toks: []Token, after_ctl_rparen: bool) -> bool {
    if len(toks) == 0 do return true
    t := toks[len(toks) - 1]
    #partial switch t.kind {
    case .RParen:
        return after_ctl_rparen
    case .Number, .Str, .Regex, .RBracket, .PlusPlus, .MinusMinus, .TplEnd:
        return false // esses TERMINAM uma expressão => `/` é divisão
    case .Ident:
        // palavra-chave que precede expressão => regex; variável/this/true/... => divisão
        switch t.text {
        case "return", "typeof", "instanceof", "in", "of", "new", "delete",
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
lex_regex :: proc(toks: ^[dynamic]Token, src: string, i: int) -> int {
    j := i + 1
    in_class := false
    for j < len(src) {
        ch := src[j]
        if ch == '\\' { j += 2; continue }   // char escapado (pula o próximo)
        if ch == '\n' { break }               // não terminado
        if ch == '[' { in_class = true }
        else if ch == ']' { in_class = false }
        else if ch == '/' && !in_class { break }
        j += 1
    }
    pattern := src[i + 1:min(j, len(src))]
    k := j
    if k < len(src) && src[k] == '/' do k += 1 // fecha
    fstart := k
    for k < len(src) && ((src[k] >= 'a' && src[k] <= 'z') || (src[k] >= 'A' && src[k] <= 'Z')) do k += 1
    append(toks, Token{kind = .Regex, text = pattern, flags = src[fstart:k]})
    return k
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
lex_number :: proc(toks: ^[dynamic]Token, src: string, start: int) -> int {
    i := start
    has_sep := false
    // bases: 0x / 0b / 0o (parse_int com base 0 detecta o prefixo)
    if src[i] == '0' && i + 1 < len(src) {
        c := src[i + 1]
        if c == 'x' || c == 'X' || c == 'b' || c == 'B' || c == 'o' || c == 'O' {
            i += 2
            for i < len(src) && (is_base_digit(src[i]) || is_digit_sep(src, i)) {
                if src[i] == '_' do has_sep = true
                i += 1
            }
            lexeme := src[start:i]
            parse_src := lexeme
            buf: [96]u8
            if has_sep do parse_src = strip_seps(lexeme, buf[:])
            v, _ := strconv.parse_int(parse_src, 0)
            i2, big := eat_bigint_n(src, i)
            append(toks, Token{kind = .Number, num = f64(v), text = lexeme, is_big = big})
            return i2
        }
    }
    // decimal: dígitos, NO MÁXIMO um ponto, expoente científico (1e3, 1.5e-10)
    // e separadores 1_000_000. O segundo '.' pertence ao acesso a membro:
    // `100..toString(2)` é (100.).toString.
    seen_dot := false
    for i < len(src) && ((src[i] >= '0' && src[i] <= '9') || (src[i] == '.' && !seen_dot) || is_digit_sep(src, i)) {
        if src[i] == '.' do seen_dot = true
        if src[i] == '_' do has_sep = true
        i += 1
    }
    if i < len(src) && (src[i] == 'e' || src[i] == 'E') {
        j := i + 1
        if j < len(src) && (src[j] == '+' || src[j] == '-') do j += 1
        if j < len(src) && src[j] >= '0' && src[j] <= '9' { // só é expoente se houver dígito
            i = j
            for i < len(src) && ((src[i] >= '0' && src[i] <= '9') || is_digit_sep(src, i)) {
                if src[i] == '_' do has_sep = true
                i += 1
            }
        }
    }
    lexeme := src[start:i]
    parse_src := lexeme
    buf: [96]u8
    if has_sep do parse_src = strip_seps(lexeme, buf[:])
    val, ok := strconv.parse_f64(parse_src)
    if !ok && len(parse_src) > 1 && parse_src[len(parse_src) - 1] == '.' {
        val, _ = strconv.parse_f64(parse_src[:len(parse_src) - 1]) // "100." → 100
    }
    i2, big := eat_bigint_n(src, i)
    append(toks, Token{kind = .Number, num = val, text = lexeme, is_big = big})
    return i2
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
decode_escapes :: proc(s: string, owned: ^[dynamic]string) -> string {
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
            case '0':  strings.write_byte(&sb, 0);    i += 2
            case '\n': i += 2                       // continuação de linha: some
            case '\r': i += 2; if i < len(s) && s[i] == '\n' do i += 1 // \<CRLF>
            case 'x':
                if v, n, ok := read_hex(s, i + 2, 2); ok && n == 2 {
                    strings.write_rune(&sb, rune(v))
                    i += 4
                } else { // \x malformado: emite literal (comportamento antigo)
                    strings.write_byte(&sb, 'x'); i += 2
                }
            case 'u':
                if i + 2 < len(s) && s[i + 2] == '{' { // \u{1F600}
                    if v, n, ok := read_hex(s, i + 3, 6); ok && i + 3 + n < len(s) && s[i + 3 + n] == '}' && v <= 0x10FFFF {
                        strings.write_rune(&sb, rune(v))
                        i += 4 + n
                        continue
                    }
                    strings.write_byte(&sb, 'u'); i += 2
                    continue
                }
                v, n, ok := read_hex(s, i + 2, 4)
                if !ok || n != 4 { // \u malformado: emite literal
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
lex_template_chunk :: proc(toks: ^[dynamic]Token, src: string, start_i: int, interp_braces: ^[dynamic]int, owned: ^[dynamic]string) -> int {
    i := start_i
    start := i
    for i < len(src) {
        if src[i] == '\\' && i + 1 < len(src) {
            i += 2 // \` e \${ escapados não terminam/abrem nada
            continue
        }
        if src[i] == '`' {
            append(toks, Token{kind = .Str, text = decode_escapes(src[start:i], owned), flags = src[start:i]})
            append(toks, Token{kind = .TplEnd})
            return i + 1
        }
        if src[i] == '$' && i + 1 < len(src) && src[i + 1] == '{' {
            append(toks, Token{kind = .Str, text = decode_escapes(src[start:i], owned), flags = src[start:i]})
            append(toks, Token{kind = .TplExprStart})
            append(interp_braces, 0) // '}' com profundidade 0 fecha esta interpolação
            return i + 2
        }
        i += 1
    }
    // template sem crase de fechamento: emite o resto e fecha mesmo assim
    append(toks, Token{kind = .Str, text = decode_escapes(src[start:i], owned), flags = src[start:i]})
    append(toks, Token{kind = .TplEnd})
    return i
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
tokenize :: proc(src: string) -> (toks: [dynamic]Token, owned: [dynamic]string, bad: int) {
    interp_braces: [dynamic]int // profundidade de {} por interpolação ${} aberta
    defer delete(interp_braces)
    // pilha paralela aos `(`: true se o paren abriu um cabeçalho if/while/for/switch
    // (aí `/` logo após o `)` correspondente inicia regex). Mantida no hook do fim
    // do loop, que vê TODOS os tokens emitidos (inclusive os sintéticos de template).
    ctl_paren: [dynamic]bool
    defer delete(ctl_paren)
    last_rparen_ctl := false
    i := 0
    saw_nl := false // houve newline desde o último token emitido (vira nl_before do próximo)
    for i < len(src) {
        c := src[i]
        mark := len(toks)
        switch {
        case c == ' ' || c == '\t' || c == '\n' || c == '\r':
            if c == '\n' do saw_nl = true
            i += 1
        case c == '/' && i + 1 < len(src) && src[i + 1] == '/':
            // comentário de linha: pula até o fim da linha
            for i < len(src) && src[i] != '\n' do i += 1
        case c == '/' && i + 1 < len(src) && src[i + 1] == '*':
            // comentário de bloco: pula até */ (newline interno conta p/ ASI)
            i += 2
            for i + 1 < len(src) && !(src[i] == '*' && src[i + 1] == '/') {
                if src[i] == '\n' do saw_nl = true
                i += 1
            }
            i = min(i + 2, len(src))
        case c == '(': append(&toks, Token{kind = .LParen});    i += 1
        case c == ')': append(&toks, Token{kind = .RParen});    i += 1
        case c == '`':
            append(&toks, Token{kind = .TplStart})
            i = lex_template_chunk(&toks, src, i + 1, &interp_braces, &owned)
        case c == '{':
            if len(interp_braces) > 0 do interp_braces[len(interp_braces) - 1] += 1
            append(&toks, Token{kind = .LBrace}); i += 1
        case c == '}':
            if n := len(interp_braces); n > 0 && interp_braces[n - 1] == 0 {
                // fecha a interpolação ${...} e volta a lexar o trecho literal
                pop(&interp_braces)
                append(&toks, Token{kind = .TplExprEnd})
                i = lex_template_chunk(&toks, src, i + 1, &interp_braces, &owned)
            } else {
                if n > 0 do interp_braces[n - 1] -= 1
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
            if regex_allowed(toks[:], last_rparen_ctl) {
                i = lex_regex(&toks, src, i)
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
                i = lex_number(&toks, src, i) // número tipo .5
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
            for i < len(src) && src[i] != quote {
                if src[i] == '\\' && i + 1 < len(src) do i += 1 // pula o char escapado
                i += 1
            }
            append(&toks, Token{kind = .Str, text = decode_escapes(src[start:i], &owned)})
            if i < len(src) do i += 1 // consome a aspa de fechamento
        case c >= '0' && c <= '9':
            i = lex_number(&toks, src, i)
        case c == '#' && i + 1 < len(src) && (is_ident_start(src[i + 1]) || ident_escape_at(src, i + 1)):
            // nome privado de classe (#x): um Ident cujo texto INCLUI o '#'.
            // Vira uma chave de propriedade "#x" que nunca enumera (ver is_private_key).
            start := i
            name, nx, esc := lex_ident_run(src, i + 1, &owned)
            if nx == i + 1 { // escape malformado logo após o '#'
                bad += 1
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
            name, nx, _ := lex_ident_run(src, i, &owned)
            if nx == i { // `\u` malformado: não é identificador, cai no descarte
                bad += 1
                i += 1
                break
            }
            i = nx
            append(&toks, Token{kind = .Ident, text = name})
        case:
            bad += 1
            i += 1 // caractere desconhecido: ignora (contabilizado em `bad`)
        }
        if saw_nl && len(toks) > mark {
            toks[mark].nl_before = true // primeiro token emitido após o(s) newline(s)
            saw_nl = false
        }
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
    append(&toks, Token{kind = .EOF, nl_before = saw_nl})
    return toks, owned, bad
}
