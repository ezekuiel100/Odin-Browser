package js

import "core:strings"
import "core:fmt" // só usado pela sonda KEYPROBE (compile-gated)

// Parser: lista de tokens -> AST.
//
// Statements:
//   program   -> statement*
//   statement -> varDecl | if | while | block | exprStmt
//
// Expressões, da menor para a maior precedência:
//   assignment -> equality ('=' assignment)?
//   equality   -> comparison (('==' | '!=') comparison)*
//   comparison -> additive (('<' | '>' | '<=' | '>=') additive)*
//   additive   -> term (('+' | '-') term)*
//   term       -> unary (('*' | '/') unary)*
//   unary      -> ('-' | '!') unary | postfix
//   postfix    -> primary ('.' Ident | '(' args ')')*
//   primary    -> Number | Str | Ident/keyword | '(' assignment ')'

// Nota de diagnóstico de um problema de parse. Historicamente era o ponto onde o
// parser "engolia" algo inválido e seguia (recuperação silenciosa); hoje todo
// problema de parse é um SyntaxError de verdade (ver syntax_error) e esta nota
// guarda a mensagem + o trecho p/ o --diagnose e o modo estrito dos testes.
Parse_Recovery :: struct {
    pos:  int,        // índice do token que disparou
    kind: Token_Kind,
    text: string,     // texto do token (se houver)
    what: string,     // descrição estática do ponto de recuperação
}

Parser :: struct {
    toks: []Token,
    pos:  int,
    no_in: bool, // true no cabeçalho-init de um for: `in` não é operador ali
                 // (senão `for(x in obj)` consumiria o `in` como expressão)
    saw_arguments: bool, // o corpo de função sendo parseado AGORA menciona `arguments`?
                         // Salvo/restaurado na fronteira de cada função NÃO-arrow
                         // (fn_args_enter/exit); arrows NÃO o zeram de propósito — o
                         // `arguments` dentro de uma arrow pertence à função envolvente.
    recoveries: int,               // notas registradas (0 ou 1: o 1º erro vence)
    rec_notes: [8]Parse_Recovery,  // detalhe das primeiras (p/ diagnóstico)
    owned_strings: [dynamic]string, // strings que a AST referencia mas o parser
                                    // alocou (chaves numéricas canônicas): vm_exec
                                    // transfere p/ vm.owned_strings (posse do vm).
    src_url: string, // URL do módulo/script sendo parseado (M137). Carimbada nos nós
                     // ImportCall/ImportMeta: o referrer de um `import()` é LÉXICO
                     // (a spec captura o script ativo na compilação), não o módulo
                     // que estiver correndo na hora da chamada.

    // ── erro de sintaxe (early error) ─────────────────────────────────────────
    // O PRIMEIRO erro vence. Ao registrá-lo o cursor salta para o EOF: todo laço do
    // parser já para no EOF, então a descida termina rápido e sem cascata de erros
    // derivados. Um fonte com err=true NÃO é executado (vm_exec lança SyntaxError).
    src:     string, // fonte (linha:coluna da mensagem); "" = sem posição
    err:     bool,
    err_msg: string, // alocada (fmt.aprintf) — o chamador assume a posse
    err_off: int,    // offset em bytes do token culpado
    is_module: bool, // goal Module: strict, `await` reservado, sem comentário HTML
    ctx: Parse_Ctx,  // contexto sintático corrente (salvo/restaurado por função)
    is_eval: bool,   // código de eval/Function(): o contexto externo (classe envolvente,
                     // função) é desconhecido aqui — as checagens que dependem dele
                     // (`#x` declarado, `new.target`, `super`) ficam permissivas.
    priv_stack: [dynamic]Priv_Scope, // um por corpo de classe aberto (nomes `#x`)
    paren_node: ^Node, // último grupo `( … )` fechado: a AST não guarda parênteses, e
                       // `(-2) ** 2` / `(a || b) ?? c` só são válidos COM eles
}

// Nomes privados de UM corpo de classe: declarados (podem aparecer depois do uso)
// e referenciados. No fim da classe, referência não declarada sobe p/ a classe
// envolvente; sem nenhuma, é SyntaxError.
Priv_Scope :: struct {
    declared: map[string]u8, // 1 = campo/método, 2 = getter, 3 = setter, 4 = par get+set
    refs:     [dynamic]string,
}

// Contexto que muda na fronteira de função/classe e decide early errors:
// onde `return`/`break`/`continue`/`yield`/`await`/`super`/`new.target` valem.
Parse_Ctx :: struct {
    strict:      bool,
    in_function: bool, // `return` e `new.target` permitidos
    in_async:    bool, // `await` é operador
    in_gen:      bool, // `yield` é operador
    in_loop:     int,  // `continue` sem label permitido (>0)
    in_breakable: int, // `break` sem label permitido (loop ou switch)
    labels:      [dynamic]Label_Info, // labels ativos (fronteira de função zera)
    super_call:  bool, // `super(...)` permitido (constructor de classe derivada)
    super_prop:  bool, // `super.x` permitido (método)
    in_class_field: bool, // inicializador de campo: `arguments` é erro
    in_params:   bool, // parseando a lista de parâmetros (yield/await expr proibidos)
    new_target_ok: bool, // `new.target` permitido (função não-arrow, campo, static block)
    in_static_block: bool, // `static { }` de classe: `await` reservado, sem `return`
    scope:       ^Scope, // escopo de declarações corrente (redeclaração)
}

Label_Info :: struct {
    name:    string,
    is_loop: bool, // o statement rotulado é um laço (`continue label` exige)
}

// Escopo de declarações p/ as early errors de REDECLARAÇÃO (`let a; let a;`,
// `let a; var a;`). `lexical` = let/const/class (+ function em bloco); `vars` =
// nomes `var` declarados ou içados ATRAVÉS deste escopo. Escopo de função
// (`is_fn`) é onde o `var` para de subir.
Scope :: struct {
    parent:   ^Scope,
    is_fn:    bool,
    is_catch: bool, // parâmetro de catch simples: Annex B permite `var e` dentro
    lexical:  map[string]u8, // 1 = let/const/class, 2 = function em bloco, 3 = param de catch
    vars:     map[string]bool,
    params:   map[string]bool, // só no escopo de função: nomes de parâmetro
}

// FUNIL ÚNICO de criação de nó .Ident (5 call-sites). Existe porque um Ident de
// nome VAZIO chega ao usuário como `ReferenceError:  is not defined` — mensagem
// que não diz nem o identificador nem a sintaxe que o gerou, e que aborta o
// script. Nome vazio é SEMPRE defeito nosso: nenhum identificador JS é vazio.
//
// ⚠️ O `note_recovery` aqui NÃO é compile-gated de propósito: é ele que faz o
// caso aparecer no `--diagnose` e dar PÂNICO em build de teste. A sonda
// KEYPROBE (essa sim gated) só acrescenta o CONTEXTO ao redor, que é o que
// identifica a sintaxe culpada — foi assim que os dois gaps de `async` foram
// achados, depois que 5 bundles reais e 35 construtos deram zero.
@(private = "file")
mk_ident :: proc(p: ^Parser, name: string, origem: string) -> ^Node {
    if name == "" && p != nil { // (nil = lista de import/export, sem parser à mão)
        note_recovery(p, "identificador de nome vazio")
        when #config(KEYPROBE, false) {
            fmt.eprintfln("[KEYPROBE] Ident de nome VAZIO (%s): kind=%v ctx=%s",
                origem, peek(p).kind, recovery_snippet(p))
        }
    }
    n := new(Node)
    n.kind = .Ident
    n.name = name
    return n
}

// Antes era uma RECUPERAÇÃO SILENCIOSA: o parser trocava o trecho inválido por `0`
// (ou descartava a atribuição) e seguia, e o script rodava miscompilado. Agora todo
// ponto de recuperação é um SyntaxError de verdade — o fonte não executa. `what`
// (descrição interna do ponto) vai só p/ o diagnóstico; a mensagem é a do V8.
note_recovery :: proc(p: ^Parser, what: string) {
    unexpected(p, what)
}

// Registra o primeiro erro de sintaxe e salta para o EOF (ver Parser.err).
syntax_error :: proc(p: ^Parser, msg: string, what := "") {
    if p.err do return
    p.err = true
    t := p.toks[min(p.pos, len(p.toks) - 1)]
    p.err_off = int(t.off)
    p.err_msg = fmt.aprintf("%s", msg)
    if p.recoveries < len(p.rec_notes) {
        p.rec_notes[p.recoveries] = Parse_Recovery{pos = p.pos, kind = t.kind, text = recovery_snippet(p), what = what if what != "" else msg}
    }
    p.recoveries += 1
    p.pos = len(p.toks) - 1 // EOF: os laços terminam
}

syntax_errorf :: proc(p: ^Parser, format: string, args: ..any) {
    if p.err do return
    msg := fmt.tprintf(format, ..args)
    syntax_error(p, msg)
}

// "Unexpected token X" no formato do V8, a partir do token corrente.
unexpected :: proc(p: ^Parser, what := "") {
    if p.err do return
    t := peek(p)
    msg: string
    #partial switch t.kind {
    case .EOF:      msg = "Unexpected end of input"
    case .Number:   msg = "Unexpected number"
    case .Str:      msg = "Unexpected string"
    case .Regex:    msg = "Unexpected regular expression"
    case .TplStart: msg = "Unexpected template string"
    case .Ident:
        if is_reserved_word(t.text) || t.text == "true" || t.text == "false" || t.text == "null" {
            msg = fmt.tprintf("Unexpected token '%s'", t.text)
        } else if is_strict_reserved(t.text) && p.ctx.strict {
            msg = "Unexpected strict mode reserved word"
        } else {
            msg = fmt.tprintf("Unexpected identifier '%s'", t.text)
        }
    case:
        msg = fmt.tprintf("Unexpected token '%s'", tok_glyph(t))
    }
    syntax_error(p, msg, what)
}

// Consome o token esperado ou é SyntaxError.
@(private = "file")
expect :: proc(p: ^Parser, k: Token_Kind) -> bool {
    if peek(p).kind == k {
        advance(p)
        return true
    }
    unexpected(p)
    return false
}

@(private = "file")
expect_word :: proc(p: ^Parser, w: string) -> bool {
    if t := peek(p); t.kind == .Ident && t.text == w && !t.bad_escape {
        advance(p)
        return true
    }
    unexpected(p)
    return false
}

// Fim de statement com ASI (spec 12.10): `;` explícito, ou o próximo token é `}`,
// EOF, ou vem depois de uma quebra de linha. Qualquer outra coisa (`a b`,
// `var a = 1 2`) é SyntaxError — antes era aceito e virava dois statements.
@(private = "file")
consume_semicolon :: proc(p: ^Parser) {
    t := peek(p)
    if t.kind == .Semicolon { advance(p); return }
    if t.kind == .RBrace || t.kind == .EOF || t.nl_before do return
    unexpected(p)
}

// ReservedWord da spec (sempre reservadas, em qualquer modo).
is_reserved_word :: proc(s: string) -> bool {
    switch s {
    case "break", "case", "catch", "class", "const", "continue", "debugger",
         "default", "delete", "do", "else", "enum", "export", "extends", "false",
         "finally", "for", "function", "if", "import", "in", "instanceof", "new",
         "null", "return", "super", "switch", "this", "throw", "true", "try",
         "typeof", "var", "void", "while", "with":
        return true
    }
    return false
}

// Reservadas só em código strict.
is_strict_reserved :: proc(s: string) -> bool {
    switch s {
    case "implements", "interface", "let", "package", "private", "protected",
         "public", "static", "yield":
        return true
    }
    return false
}

// O nome pode ser usado como BindingIdentifier aqui? (declaração, parâmetro,
// catch, import). Registra o erro e devolve false se não.
@(private = "file")
check_binding_name :: proc(p: ^Parser, name: string) -> bool {
    if p.err do return false
    if is_reserved_word(name) {
        syntax_errorf(p, "Unexpected token '%s'", name)
        return false
    }
    if p.ctx.strict {
        if is_strict_reserved(name) {
            syntax_error(p, "Unexpected strict mode reserved word")
            return false
        }
        if name == "eval" || name == "arguments" {
            syntax_error(p, "Unexpected eval or arguments in strict mode")
            return false
        }
    }
    if name == "yield" && (p.ctx.in_gen || p.ctx.strict) {
        syntax_error(p, "Unexpected identifier 'yield'")
        return false
    }
    if name == "await" && (p.ctx.in_async || p.is_module || p.ctx.in_static_block) {
        syntax_error(p, "Unexpected reserved word")
        return false
    }
    return true
}

// LabelIdentifier: como identificador, mas `eval`/`arguments` valem até em strict.
@(private = "file")
check_label_name :: proc(p: ^Parser, name: string) {
    if is_reserved_word(name) {
        syntax_errorf(p, "Unexpected token '%s'", name)
    } else if p.ctx.strict && is_strict_reserved(name) {
        syntax_error(p, "Unexpected strict mode reserved word")
    } else if name == "yield" && p.ctx.in_gen {
        syntax_error(p, "Unexpected identifier 'yield'")
    } else if name == "await" && (p.ctx.in_async || p.is_module || p.ctx.in_static_block) {
        syntax_error(p, "Unexpected reserved word")
    }
}

// Palavra reservada escrita com escape (`\u0069f`): vale como NOME de propriedade
// (`o.\u0069f`, `{\u0069f: 1}`), mas não como keyword nem como identificador.
// Chamado onde o token age como um dos dois. Devolve true se era erro.
@(private = "file")
escaped_keyword :: proc(p: ^Parser, t: Token) -> bool {
    if t.kind != .Ident || !t.bad_escape do return false
    if is_reserved_word(t.text) || (p.ctx.strict && is_strict_reserved(t.text)) {
        syntax_error(p, "Keyword must not contain escaped characters")
        return true
    }
    return false
}

// Lê um BindingIdentifier (nome simples) ou é SyntaxError.
@(private = "file")
binding_ident :: proc(p: ^Parser) -> string {
    t := peek(p)
    if t.kind != .Ident || (len(t.text) > 0 && t.text[0] == '#') {
        unexpected(p)
        return ""
    }
    if escaped_keyword(p, t) do return ""
    if !check_binding_name(p, t.text) do return ""
    advance(p)
    return t.text
}

// Linha e coluna (1-based) de um offset no fonte.
src_line_col :: proc(src: string, off: int) -> (line, col: int) {
    line = 1
    last_nl := -1
    for i in 0 ..< min(off, len(src)) {
        if src[i] == '\n' { line += 1; last_nl = i }
    }
    return line, off - last_nl
}

// DIAG temporário: reconstrói ~9 tokens ao redor de p.pos como texto para
// identificar a sintaxe real que causou o desync (o token que dispara o
// recovery costuma ser downstream). Marca o token disparador com «».
@(private = "file")
recovery_snippet :: proc(p: ^Parser) -> string {
    lo := max(0, p.pos - 12)
    hi := min(len(p.toks), p.pos + 4)
    sb := strings.builder_make(context.temp_allocator) // nota efêmera: o vm guarda a sua
    for i in lo ..< hi {
        if i > lo do strings.write_byte(&sb, ' ')
        if i == p.pos do strings.write_string(&sb, "«")
        strings.write_string(&sb, tok_glyph(p.toks[i]))
        if i == p.pos do strings.write_string(&sb, "»")
    }
    return strings.to_string(sb)
}

@(private = "file")
tok_glyph :: proc(t: Token) -> string {
    if t.text != "" do return t.text
    #partial switch t.kind {
    case .Number:    return "«num»"
    case .Str:       return "«str»"
    case .LParen:    return "("
    case .RParen:    return ")"
    case .LBracket:  return "["
    case .RBracket:  return "]"
    case .LBrace:    return "{"
    case .RBrace:    return "}"
    case .Comma:     return ","
    case .Semicolon: return ";"
    case .Dot:       return "."
    case .DotDotDot: return "..."
    case .Colon:     return ":"
    case .Question:  return "?"
    case .Arrow:     return "=>"
    case .Assign:    return "="
    case .Plus:      return "+"
    case .Minus:     return "-"
    case .Star:      return "*"
    case .Slash:     return "/"
    case .Percent:   return "%"
    case .Bang:      return "!"
    case .Amp:       return "&"
    case .Pipe:      return "|"
    case .Caret:     return "^"
    case .Tilde:     return "~"
    case .Lt:        return "<"
    case .Gt:        return ">"
    case .EOF:       return "«eof»"
    case .TplStart:  return "`"
    case .TplEnd:    return "`"
    case .TplExprStart: return "${"
    case .TplExprEnd:   return "}"
    // Operadores de MAIS DE UM caractere. Faltavam TODOS, e o fallback "¿" os
    // apagava justamente do contexto que a nota de recuperação existe para
    // mostrar: `n.match(G) ¿ []` não diz nada, `n.match(G) || []` diz tudo.
    // Diagnosticar slack/weather por esse dump me levou a uma hipótese ERRADA.
    case .EqEq:      return "=="
    case .NotEq:     return "!="
    case .EqEqEq:    return "==="
    case .NotEqEq:   return "!=="
    case .LtEq:      return "<="
    case .GtEq:      return ">="
    case .AmpAmp:    return "&&"
    case .PipePipe:  return "||"
    case .QQuestion: return "??"
    case .QDot:      return "?."
    case .AmpAmpEq:  return "&&="
    case .PipePipeEq: return "||="
    case .QQuestionEq: return "??="
    case .PlusPlus:  return "++"
    case .MinusMinus: return "--"
    case .PlusEq:    return "+="
    case .MinusEq:   return "-="
    case .StarEq:    return "*="
    case .SlashEq:   return "/="
    case .PercentEq: return "%="
    case .StarStar:  return "**"
    case .StarStarEq: return "**="
    case .Shl:       return "<<"
    case .Shr:       return ">>"
    case .UShr:      return ">>>"
    case .AmpEq:     return "&="
    case .PipeEq:    return "|="
    case .CaretEq:   return "^="
    case .ShlEq:     return "<<="
    case .ShrEq:     return ">>="
    case .UShrEq:    return ">>>="
    case .Instanceof: return "instanceof"
    case .In:        return "in"
    case .Regex:     return "«regex»"
    }
    return "¿" // token sem glifo (o kind exato vai no campo separado do relatório)
}

@(private = "file")
peek :: proc(p: ^Parser) -> Token {
    return p.toks[p.pos]
}

@(private = "file")
advance :: proc(p: ^Parser) -> Token {
    t := p.toks[p.pos]
    if p.pos < len(p.toks) - 1 do p.pos += 1 // trava no EOF
    return t
}

// ── statements ────────────────────────────────────────────────────────────────

parse_program :: proc(p: ^Parser) -> ^Node {
    prog := new(Node)
    prog.kind = .Program
    root := push_scope(p, true)
    if p.is_module do p.ctx.strict = true
    parse_directives(p)
    prog.strict = p.ctx.strict // eval strict roda num escopo PRÓPRIO (var não vaza)
    for peek(p).kind != .EOF {
        append(&prog.body, parse_statement(p))
    }
    pop_scope(p, root)
    delete(p.ctx.labels)
    p.ctx.labels = nil
    for &ps in p.priv_stack { delete(ps.declared); delete(ps.refs) }
    delete(p.priv_stack)
    p.priv_stack = nil
    return prog
}

// ── prólogo de diretivas ("use strict") ─────────────────────────────────────
// Olha os statements-string do início do corpo SEM consumi-los (eles são parseados
// normalmente depois, como ExprStmt). "use strict" só conta escrito LITERALMENTE
// (sem escape) — por isso compara o texto CRU do fonte. Devolve se havia a diretiva.
@(private = "file")
parse_directives :: proc(p: ^Parser) -> bool {
    j := p.pos
    octal_before := false
    for j < len(p.toks) {
        t := p.toks[j]
        if t.kind != .Str do break
        nx := p.toks[min(j + 1, len(p.toks) - 1)]
        ends := nx.kind == .Semicolon || nx.kind == .RBrace || nx.kind == .EOF
        if !ends && nx.nl_before {
            #partial switch nx.kind {
            case .Ident:
                ends = nx.text != "in" && nx.text != "instanceof"
            case .Str, .Number, .LBrace, .Bang, .Tilde, .PlusPlus, .MinusMinus, .Regex:
                ends = true
            }
        }
        if !ends do break
        if raw_use_strict(p, t) {
            p.ctx.strict = true
            if octal_before {
                p.pos = j
                syntax_error(p, "Octal escape sequences are not allowed in strict mode.")
            }
            return true
        }
        if t.legacy_octal do octal_before = true
        j += 1
        if nx.kind == .Semicolon do j += 1
    }
    return false
}

@(private = "file")
raw_use_strict :: proc(p: ^Parser, t: Token) -> bool {
    if p.src == "" do return t.text == "use strict"
    o := int(t.off)
    if o + 12 > len(p.src) do return false
    q := p.src[o]
    return p.src[o + 1:o + 11] == "use strict" && p.src[o + 11] == q
}

// ── escopos de declaração ───────────────────────────────────────────────────
@(private = "file")
push_scope :: proc(p: ^Parser, is_fn: bool) -> ^Scope {
    s := new(Scope)
    s.parent = p.ctx.scope
    s.is_fn = is_fn
    p.ctx.scope = s
    return s
}

@(private = "file")
pop_scope :: proc(p: ^Parser, s: ^Scope) {
    p.ctx.scope = s.parent
    delete(s.lexical)
    delete(s.vars)
    delete(s.params)
    free(s)
}

@(private = "file")
redeclared :: proc(p: ^Parser, name: string) {
    syntax_errorf(p, "Identifier '%s' has already been declared", name)
}

// let/const/class (kind 1), function em bloco (kind 2), param de catch (3 simples, 4 padrão).
@(private = "file")
declare_lexical :: proc(p: ^Parser, name: string, kind: u8 = 1) {
    s := p.ctx.scope
    if s == nil || name == "" || p.err do return
    if v, ok := s.lexical[name]; ok {
        // Annex B: em código sloppy, duas declarações de function no MESMO bloco valem
        if !(kind == 2 && v == 2 && !p.ctx.strict) do redeclared(p, name)
        return
    }
    if s.vars[name] || (s.is_fn && s.params[name]) {
        redeclared(p, name)
        return
    }
    s.lexical[name] = kind
}

// `var` (e function no topo de função/script): sobe até o escopo de função,
// colidindo com qualquer léxico no caminho.
@(private = "file")
declare_var :: proc(p: ^Parser, name: string) {
    if name == "" || p.err do return
    for s := p.ctx.scope; s != nil; s = s.parent {
        if v, ok := s.lexical[name]; ok && v != 3 { // 3: catch(e){ var e } é Annex B
            redeclared(p, name)
            return
        }
        s.vars[name] = true
        if s.is_fn do break
    }
}

// Nomes ligados por um padrão de declaração ({a, b: [c]} → a, c).
@(private = "file")
pattern_names :: proc(pat: ^Node, out: ^[dynamic]string) {
    if pat == nil do return
    for el in pat.body {
        if el == nil do continue
        if el.left != nil && el.left.kind == .Pattern {
            pattern_names(el.left, out)
        } else if el.name != "" {
            append(out, el.name)
        }
    }
}

@(private = "file")
declare_pattern :: proc(p: ^Parser, pat: ^Node, is_var: bool, kind: u8 = 1) {
    names: [dynamic]string
    defer delete(names)
    pattern_names(pat, &names)
    for nm in names {
        if is_var {
            declare_var(p, nm)
        } else {
            if nm == "let" do syntax_error(p, "let is disallowed as a lexically bound name")
            declare_lexical(p, nm, kind)
        }
    }
}

// Declaração de função no ponto corrente: no topo de função/script é como `var`;
// dentro de bloco é LÉXICA (kind 2 = sloppy simples, que o Annex B deixa repetir).
@(private = "file")
declare_function :: proc(p: ^Parser, name: string, simple: bool) {
    if name == "" do return
    s := p.ctx.scope
    if p.is_module && s != nil && s.parent == nil && !p.ctx.in_function {
        declare_lexical(p, name, 1) // topo de módulo: function é LÉXICA
        return
    }
    if s != nil && s.is_fn {
        if v, ok := s.lexical[name]; ok && v != 3 {
            redeclared(p, name)
            return
        }
        s.vars[name] = true
        return
    }
    declare_lexical(p, name, 2 if simple else 1)
}

// ── statements ────────────────────────────────────────────────────────────────

// Corpo de if/while/for/do/label: um Statement, NÃO uma declaração. `if (x) let y`
// e `while (x) class C {}` são SyntaxError; `if (x) function f(){}` só em sloppy
// (Annex B), e só como corpo de if.
@(private = "file")
parse_sub_statement :: proc(p: ^Parser, is_if_body := false) -> ^Node {
    t := peek(p)
    if t.kind == .Ident {
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        switch t.text {
        case "const", "class":
            syntax_error(p, "Lexical declaration cannot appear in a single-statement context")
            return make_num(0)
        case "let":
            if nx.kind == .LBracket || (nx.kind == .LBrace && !nx.nl_before) ||
               (nx.kind == .Ident && !nx.nl_before && nx.text != "in" && nx.text != "instanceof") {
                syntax_error(p, "Lexical declaration cannot appear in a single-statement context")
                return make_num(0)
            }
            if !p.ctx.strict && !t.bad_escape {
                // `if (x) let \n {}`: aqui não cabe declaração, então `let` é o
                // identificador e a quebra de linha encerra o statement (ASI)
                expr := parse_sequence(p)
                consume_semicolon(p)
                es := new(Node)
                es.kind = .ExprStmt
                es.left = expr
                return es
            }
        case "function":
            if p.ctx.strict {
                syntax_error(p, "In strict mode code, functions can only be declared at top level or inside a block.")
                return make_num(0)
            }
            if !is_if_body {
                syntax_error(p, "In non-strict mode code, functions can only be declared at top level, inside a block, or as the body of an if statement.")
                return make_num(0)
            }
            if nx.kind == .Star {
                syntax_error(p, "Generators can only be declared at the top level or inside a block.")
                return make_num(0)
            }
            // o `function` do corpo de if (Annex B) ganha um bloco implícito próprio
            sc := push_scope(p, false)
            defer pop_scope(p, sc)
            return parse_statement(p)
        case "async":
            if nx.kind == .Ident && nx.text == "function" && !nx.nl_before {
                syntax_error(p, "Async functions can only be declared at the top level or inside a block.")
                return make_num(0)
            }
        case "export":
            unexpected(p)
            return make_num(0)
        case "import":
            if nx.kind != .LParen && nx.kind != .Dot {
                syntax_error(p, "Cannot use import statement outside a module")
                return make_num(0)
            }
        }
    }
    return parse_statement(p)
}

// O statement rotulado (atrás de outros labels) é um laço? `a: b: while(1) continue a`.
@(private = "file")
labels_a_loop :: proc(p: ^Parser) -> bool {
    j := p.pos
    for j + 1 < len(p.toks) && p.toks[j].kind == .Ident && p.toks[j + 1].kind == .Colon do j += 2
    t := p.toks[min(j, len(p.toks) - 1)]
    return t.kind == .Ident && (t.text == "for" || t.text == "while" || t.text == "do")
}

@(private = "file")
find_label :: proc(p: ^Parser, name: string) -> (Label_Info, bool) {
    for l in p.ctx.labels do if l.name == name do return l, true
    return {}, false
}

@(private = "file")
parse_statement :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    if escaped_keyword(p, t) do return make_num(0)
    if t.kind == .Semicolon { // statement VAZIO: `;` (if(x); / ;; de minifier)
        advance(p)
        n := new(Node)
        n.kind = .Undef // avaliar dá undefined, sem efeito
        return n
    }
    // labeled statement: `label: stmt`. Em posição de statement, `Ident :` só pode
    // ser um label (React minificado usa `a: switch(...)` + `break a`). Detecta
    // ANTES do switch de keywords (o label nunca é palavra reservada).
    if t.kind == .Ident && p.toks[min(p.pos + 1, len(p.toks) - 1)].kind == .Colon && t.text[0] != '#' {
        label := t.text
        check_label_name(p, label)
        if p.err do return make_num(0)
        advance(p) // nome do label
        advance(p) // ':'
        if _, dup := find_label(p, label); dup {
            syntax_errorf(p, "Label '%s' has already been declared", label)
            return make_num(0)
        }
        append(&p.ctx.labels, Label_Info{name = label, is_loop = labels_a_loop(p)})
        n := new(Node); n.kind = .Labeled
        n.name = label
        if nt := peek(p); nt.kind == .Ident && nt.text == "function" {
            // Annex B: `l: function f(){}` só em sloppy, e nunca generator
            if p.ctx.strict {
                syntax_error(p, "In strict mode code, functions can only be declared at top level or inside a block.")
            } else if p.toks[min(p.pos + 1, len(p.toks) - 1)].kind == .Star {
                syntax_error(p, "Generators can only be declared at the top level or inside a block.")
            }
            n.left = parse_statement(p)
        } else {
            n.left = parse_sub_statement(p)
        }
        if len(p.ctx.labels) > 0 do pop(&p.ctx.labels)
        return n
    }
    if t.kind == .Ident && !t.bad_escape { // `\u0061sync`: identificador, não keyword
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        switch t.text {
        case "var", "const":
            return parse_var_decl(p)
        case "let":
            // `let` só abre declaração se seguido de nome, `[` ou `{` — senão é um
            // identificador comum em código sloppy (`let = 1`, `let.x`).
            if t.bad_escape && !p.ctx.strict do break
            if nx.kind == .LBracket || nx.kind == .LBrace || p.ctx.strict ||
               (nx.kind == .Ident && nx.text != "in" && nx.text != "instanceof") {
                return parse_var_decl(p)
            }
        case "if":
            return parse_if(p)
        case "while":
            return parse_while(p)
        case "do":
            return parse_do_while(p)
        case "for":
            return parse_for(p)
        case "switch":
            return parse_switch(p)
        case "function":
            f := parse_function(p, is_decl = true)
            f.decl = true // declaração: o nome binda no escopo externo
            return f
        case "class":
            c := parse_class(p, is_decl = true)
            c.decl = true
            return c
        case "async":
            // async function nome() {} — declaração; async arrows caem no
            // fluxo de expressão abaixo (try_parse_arrow reconhece o prefixo)
            if nx.kind == .Ident && nx.text == "function" && !nx.nl_before && !t.bad_escape {
                advance(p) // async
                f := parse_function(p, is_decl = true, is_async = true)
                f.decl = true
                return f
            }
        case "return":
            return parse_return(p)
        case "break":
            advance(p)
            n := new(Node); n.kind = .Break
            // ASI: label só na MESMA linha (`break\nfoo()` é break + chamada)
            if tk := peek(p); tk.kind == .Ident && !tk.nl_before && !is_reserved_word(tk.text) {
                n.name = advance(p).text
                if _, ok := find_label(p, n.name); !ok {
                    syntax_errorf(p, "Undefined label '%s'", n.name)
                }
            } else if p.ctx.in_breakable == 0 {
                syntax_error(p, "Illegal break statement")
            }
            consume_semicolon(p)
            return n
        case "continue":
            advance(p)
            n := new(Node); n.kind = .Continue
            if tk := peek(p); tk.kind == .Ident && !tk.nl_before && !is_reserved_word(tk.text) { // ASI, como o break
                n.name = advance(p).text
                if l, ok := find_label(p, n.name); !ok {
                    syntax_errorf(p, "Undefined label '%s'", n.name)
                } else if !l.is_loop || p.ctx.in_loop == 0 {
                    syntax_errorf(p, "Illegal continue statement: '%s' does not denote an iteration statement", n.name)
                }
            } else if p.ctx.in_loop == 0 {
                syntax_error(p, "Illegal continue statement: no surrounding iteration statement")
            }
            consume_semicolon(p)
            return n
        case "throw":
            advance(p)
            n := new(Node); n.kind = .Throw
            if peek(p).nl_before {
                syntax_error(p, "Illegal newline after throw")
                return n
            }
            n.right = parse_sequence(p)
            consume_semicolon(p)
            return n
        case "try":
            return parse_try(p)
        case "debugger":
            advance(p)
            consume_semicolon(p)
            n := new(Node)
            n.kind = .Undef // sem depurador: no-op
            return n
        case "with":
            return parse_with(p)
        case "export":
            if !at_module_top(p) {
                syntax_error(p, "Unexpected token 'export'")
                return make_num(0)
            }
            return parse_export(p)
        case "import":
            // `import(...)` / `import.meta` são EXPRESSÕES — deixa p/ o fluxo normal.
            if nx.kind != .LParen && nx.kind != .Dot {
                if !at_module_top(p) {
                    syntax_error(p, "Cannot use import statement outside a module")
                    return make_num(0)
                }
                return parse_import(p) // import estático: ignorado (bundle já inlina)
            }
        case "else", "case", "default", "catch", "finally", "extends", "enum", "in", "instanceof":
            unexpected(p)
            return make_num(0)
        }
    }
    if t.kind == .LBrace {
        return parse_block(p)
    }
    // expression statement (aceita sequência: `a, b, c;`)
    expr := parse_sequence(p)
    consume_semicolon(p)
    s := new(Node)
    s.kind = .ExprStmt
    s.left = expr
    return s
}

// `import`/`export` estáticos só no TOPO de um MÓDULO (goal Module: vm_run_module e
// módulos importados, que rodam com current_module). Em script clássico, dentro de
// função ou de bloco é SyntaxError — como num navegador.
@(private = "file")
at_module_top :: proc(p: ^Parser) -> bool {
    return p.is_module && p.ctx.scope != nil && p.ctx.scope.parent == nil && !p.ctx.in_function && p.ctx.in_breakable == 0 && len(p.ctx.labels) == 0
}

// `with (obj) stmt`: proibido em strict (early error). Em sloppy é sintaxe VÁLIDA
// que o motor não implementa — vira um throw em RUNTIME com mensagem honesta, em
// vez de SyntaxError (que mentiria sobre o fonte) ou de executar errado.
@(private = "file")
parse_with :: proc(p: ^Parser) -> ^Node {
    if p.ctx.strict {
        syntax_error(p, "Strict mode code may not include a with statement")
        return make_num(0)
    }
    advance(p) // with
    expect(p, .LParen)
    obj := parse_sequence(p)
    expect(p, .RParen)
    body := parse_sub_statement(p)
    free_ast(body)
    blk := new(Node); blk.kind = .Block
    es := new(Node); es.kind = .ExprStmt; es.left = obj
    append(&blk.body, es)
    thr := new(Node); thr.kind = .Throw
    ctor := new(Node); ctor.kind = .New; ctor.callee = mk_ident(p, "TypeError", "with")
    msg := new(Node); msg.kind = .Str; msg.str = "with statement is not supported by this engine"
    append(&ctor.body, msg)
    thr.right = ctor
    append(&blk.body, thr)
    return blk
}

/// Sintaxe de módulo ES. O navegador roda o bundle como script único (imports já
// inlinados pelo Vite), então só precisamos parsear sem quebrar:
//   export default expr;        -> avalia expr (efeitos)
//   export { a, b as c };       -> no-op (lista de nomes)
//   export const/function/...   -> a declaração, sem o `export`
//   export * from "...";        -> no-op
// Um item de lista `{a, b as c}` de import/export: nó .Ident com os DOIS nomes.
// Em import: str=nome exportado (no módulo-fonte), name=alias local.
// Em export: name=nome local, str=nome exportado (visto por quem importa).
@(private = "file")
make_module_name_pair :: proc(a, b: string) -> ^Node {
    n := mk_ident(nil, a, "module-name-pair")
    n.str = b
    return n
}

// ModuleExportName: identificador (inclusive palavra reservada, `export {x as default}`)
// ou string (`export {x as "a b"}`, ES2022).
@(private = "file")
module_export_name :: proc(p: ^Parser) -> string {
    t := peek(p)
    if t.kind == .Ident || t.kind == .Str {
        advance(p)
        return t.text
    }
    unexpected(p)
    return ""
}

// `from "especificador"` obrigatório + atributos opcionais (`with { type: "json" }`).
@(private = "file")
module_from :: proc(p: ^Parser) -> string {
    if !expect_word(p, "from") do return ""
    t := peek(p)
    if t.kind != .Str {
        unexpected(p)
        return ""
    }
    advance(p)
    skip_import_attributes(p)
    return t.text
}

@(private = "file")
skip_import_attributes :: proc(p: ^Parser) {
    t := peek(p)
    if t.kind != .Ident || (t.text != "with" && !(t.text == "assert" && !t.nl_before)) do return
    advance(p)
    if !expect(p, .LBrace) do return
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        if k := peek(p).kind; k != .Ident && k != .Str { unexpected(p); return }
        advance(p)
        if !expect(p, .Colon) do return
        if peek(p).kind != .Str { unexpected(p); return }
        advance(p)
        if peek(p).kind == .Comma { advance(p); continue }
        break
    }
    expect(p, .RBrace)
}

// export ... — M109: em vez de descartar, produz .ExportDecl com os nomes
// exportados (o eval registra no namespace do módulo corrente; fora de módulo,
// só avalia a declaração — comportamento antigo).
@(private = "file")
parse_export :: proc(p: ^Parser) -> ^Node {
    advance(p) // export
    t := peek(p)
    n := new(Node); n.kind = .ExportDecl
    if t.kind == .Ident && t.text == "default" {
        advance(p) // default
        n.bval = true
        // `export default function f(){}` / `class C{}`: DECLARAÇÃO (nome opcional),
        // sem `;` depois. O nome também binda no escopo do módulo (spec).
        nt := peek(p)
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if nt.kind == .Ident && nt.text == "function" {
            n.left = parse_function(p, is_decl = true, anon_ok = true)
        } else if nt.kind == .Ident && nt.text == "async" && nx.kind == .Ident && nx.text == "function" && !nx.nl_before {
            advance(p)
            n.left = parse_function(p, is_decl = true, is_async = true, anon_ok = true)
        } else if nt.kind == .Ident && nt.text == "class" {
            n.left = parse_class(p, is_decl = true, anon_ok = true)
        } else {
            n.left = parse_assignment(p)
            consume_semicolon(p)
            return n
        }
        if n.left != nil && n.left.name != "" do n.left.decl = true
        return n
    }
    if t.kind == .LBrace { // export { a, b as c } [from "..."]
        advance(p) // {
        for peek(p).kind != .RBrace && peek(p).kind != .EOF {
            local := module_export_name(p)
            exported := local
            if is_kw(peek(p), "as") { advance(p); exported = module_export_name(p) }
            append(&n.body, make_module_name_pair(local, exported))
            if peek(p).kind == .Comma { advance(p) } else { break }
        }
        expect(p, .RBrace)
        if is_kw(peek(p), "from") {
            n.str = module_from(p) // re-export
        }
        consume_semicolon(p)
        return n
    }
    if t.kind == .Star { // export * [as ns] from "..."
        advance(p) // *
        n.aux = true
        if is_kw(peek(p), "as") { advance(p); n.name = module_export_name(p) }
        n.str = module_from(p)
        consume_semicolon(p)
        return n
    }
    // export const/let/var/function/class/async — embrulha a declaração;
    // o eval a executa E registra os nomes declarados como exports.
    if t.kind == .Ident {
        switch t.text {
        case "var", "let", "const", "function", "class", "async":
            n.left = parse_statement(p)
            return n
        }
    }
    unexpected(p)
    return n
}

// import estático — M109: produz .ImportDecl com especificador + bindings.
// O eval carrega o módulo (via hooks module_resolve/module_fetch) e define os
// nomes no escopo; sem hooks instalados, degrada p/ no-op (comportamento antigo).
@(private = "file")
parse_import :: proc(p: ^Parser) -> ^Node {
    advance(p) // import
    n := new(Node); n.kind = .ImportDecl
    if peek(p).kind == .Str { // import "./efeito.js" (só efeitos colaterais)
        n.str = advance(p).text
        skip_import_attributes(p)
        consume_semicolon(p)
        return n
    }
    need_clause := true
    // default import: `import D [, ...] from`
    if peek(p).kind == .Ident && !(is_kw(peek(p), "from") && p.toks[min(p.pos + 1, len(p.toks) - 1)].kind == .Str) {
        n.name = binding_ident(p)
        declare_lexical(p, n.name)
        need_clause = false
        if peek(p).kind == .Comma {
            advance(p)
            need_clause = true
        }
    }
    if need_clause {
        if peek(p).kind == .Star { // * as ns
            advance(p)
            expect_word(p, "as")
            n.rest_param = binding_ident(p)
            declare_lexical(p, n.rest_param)
        } else if peek(p).kind == .LBrace { // { a, b as c }
            advance(p)
            for peek(p).kind != .RBrace && peek(p).kind != .EOF {
                it := peek(p)
                imported := module_export_name(p)
                local := imported
                if is_kw(peek(p), "as") {
                    advance(p)
                    local = binding_ident(p)
                } else if it.kind == .Str || is_reserved_word(imported) {
                    // `import {"a b"}` / `import {default}` exigem `as nome`
                    unexpected(p)
                } else {
                    check_binding_name(p, local)
                }
                declare_lexical(p, local)
                append(&n.body, make_module_name_pair(local, imported))
                if peek(p).kind == .Comma { advance(p) } else { break }
            }
            expect(p, .RBrace)
        } else {
            unexpected(p)
            return n
        }
    }
    n.str = module_from(p)
    consume_semicolon(p)
    return n
}

@(private = "file")
parse_var_decl :: proc(p: ^Parser) -> ^Node {
    is_var := peek(p).text == "var" // var = function-scoped; let/const = block-scoped
    is_const := peek(p).text == "const" // reatribuir lança TypeError (ver env_assign)
    advance(p) // var/let/const
    n := parse_one_declarator(p, is_var, is_const, false)
    n.aux = is_var
    n.is_const = is_const
    // múltiplos declaradores: `var a = 1, b = 2, c` — os extras vão em n.body,
    // avaliados no MESMO escopo (eval .VarDecl os percorre).
    for peek(p).kind == .Comma {
        advance(p)
        d := parse_one_declarator(p, is_var, is_const, false)
        d.aux = is_var
        d.is_const = is_const
        append(&n.body, d)
    }
    consume_semicolon(p)
    return n
}

// Um único declarador: nome-simples ou padrão, com init opcional. Não consome
// vírgula nem ponto-e-vírgula (o chamador cuida da lista). `in_for`: cabeçalho de
// for — lá `const x` / padrão SEM inicializador valem (for-in/of), e quem valida é
// o parse_for.
@(private = "file")
parse_one_declarator :: proc(p: ^Parser, is_var, is_const, in_for: bool) -> ^Node {
    n := new(Node)
    n.kind = .VarDecl
    if k := peek(p).kind; k == .LBrace || k == .LBracket {
        n.left = parse_pattern(p, binding = true) // destructuring: const {a,b} = x / [a,b] = arr
        declare_pattern(p, n.left, is_var)
    } else {
        n.name = binding_ident(p) // Ident simples
        if !is_var && n.name == "let" do syntax_error(p, "let is disallowed as a lexically bound name")
        if is_var do declare_var(p, n.name)
        else do declare_lexical(p, n.name)
    }
    if peek(p).kind == .Assign {
        advance(p)
        n.right = parse_assignment(p) // NÃO usa parse_expr: a vírgula separa declaradores
    } else if !in_for {
        if n.left != nil {
            syntax_error(p, "Missing initializer in destructuring declaration")
        } else if is_const {
            syntax_error(p, "Missing initializer in const declaration")
        }
    }
    return n
}

@(private = "file")
parse_if :: proc(p: ^Parser) -> ^Node {
    advance(p) // if
    expect(p, .LParen)
    cond := parse_sequence(p) // if(a, b, c) — condição pode ser sequência vírgula
    expect(p, .RParen)
    n := new(Node)
    n.kind = .If
    n.left = cond
    n.right = parse_sub_statement(p, is_if_body = true)
    if peek(p).kind == .Ident && peek(p).text == "else" {
        advance(p)
        n.third = parse_sub_statement(p, is_if_body = true)
    }
    return n
}

// ── funções: contexto, parâmetros e corpo ───────────────────────────────────

Fn_Kind :: enum { Normal, Arrow, Method, Getter, Setter, Ctor, Derived_Ctor }

// O que a lista de parâmetros revelou e que só pode ser JULGADO depois do corpo
// (um "use strict" no corpo torna retroativamente ilegais params duplicados, `eval`
// como nome etc.).
Params_Info :: struct {
    names:      [dynamic]string, // todos os nomes ligados (inclui padrões e rest)
    non_simple: bool,            // há default, padrão ou rest
    dup:        string,          // 1º nome repetido ("" = nenhum)
    formal:     int,             // nº de params formais SEM o rest
    has_rest:   bool,
}

// Entra no contexto de uma função: zera labels/laços, liga async/generator e o
// que a fronteira de função permite. Arrow herda `this`/`super`/`new.target`
// (não mexe nesses) mas tem labels e laços próprios. Devolve o contexto externo.
@(private = "file")
enter_fn :: proc(p: ^Parser, kind: Fn_Kind, is_async, is_gen: bool) -> Parse_Ctx {
    saved := p.ctx
    p.ctx.labels = nil
    p.ctx.in_loop = 0
    p.ctx.in_breakable = 0
    p.ctx.in_async = is_async
    p.ctx.in_gen = is_gen
    p.ctx.in_params = false
    p.ctx.in_function = true
    p.ctx.in_static_block = false
    if kind != .Arrow {
        p.ctx.new_target_ok = true
        p.ctx.in_class_field = false
        p.ctx.super_prop = kind != .Normal
        p.ctx.super_call = kind == .Derived_Ctor
    }
    push_scope(p, true)
    return saved
}

@(private = "file")
exit_fn :: proc(p: ^Parser, saved: Parse_Ctx) {
    delete(p.ctx.labels)
    if p.ctx.scope != nil && p.ctx.scope != saved.scope do pop_scope(p, p.ctx.scope)
    p.ctx = saved
}

// Julga, com a strictness FINAL do corpo, o que parse_params só registrou.
@(private = "file")
validate_params :: proc(p: ^Parser, info: ^Params_Info, kind: Fn_Kind, fn_name: string) {
    if p.err do return
    strict := p.ctx.strict
    if info.dup != "" && (strict || info.non_simple || kind != .Normal) {
        syntax_error(p, "Duplicate parameter name not allowed in this context")
        return
    }
    if !strict do return
    names := info.names[:]
    for nm in names {
        if nm == "eval" || nm == "arguments" {
            syntax_error(p, "Unexpected eval or arguments in strict mode")
            return
        }
        if is_strict_reserved(nm) {
            syntax_error(p, "Unexpected strict mode reserved word")
            return
        }
    }
    if fn_name == "eval" || fn_name == "arguments" {
        syntax_error(p, "Unexpected eval or arguments in strict mode")
    } else if is_strict_reserved(fn_name) {
        syntax_error(p, "Unexpected strict mode reserved word")
    }
}

// function nome(a, b) { ... }   — declaração (statement) ou expressão.
// O nome é opcional em contexto de expressão (função anônima). O `async` (se houver)
// já foi consumido pelo chamador, que passa is_async.
@(private = "file")
parse_function :: proc(p: ^Parser, is_decl := false, is_async := false, anon_ok := false) -> ^Node {
    advance(p) // function
    n := new(Node)
    n.kind = .Func
    n.aux = is_async
    if peek(p).kind == .Star { advance(p); n.is_generator = true } // function* = generator
    if t := peek(p); t.kind == .Ident {
        if is_decl do check_binding_name(p, t.text)
        n.name = t.text
        advance(p)
    } else if is_decl && !anon_ok {
        syntax_error(p, "Function statements require a function name")
    }
    if is_decl do declare_function(p, n.name, !n.is_generator && !is_async)
    saved_args := fn_args_enter(p)
    saved := enter_fn(p, .Normal, is_async, n.is_generator)
    // nome de EXPRESSÃO: julgado no contexto da própria função (`function* yield(){}`)
    if !is_decl && n.name != "" do check_binding_name(p, n.name)
    info: Params_Info
    defer delete(info.names)
    expect(p, .LParen)
    parse_params(p, n, &info)
    expect(p, .RParen)
    n.right = parse_fn_body(p, &info) // corpo { ... } (yield só é keyword se generator)
    validate_params(p, &info, .Normal, n.name)
    n.strict = p.ctx.strict // ANTES do exit_fn, que restaura o contexto envolvente
    exit_fn(p, saved)
    fn_args_exit(p, n, saved_args)
    return n
}

// Corpo `{...}` de função, JÁ dentro do contexto da função (enter_fn). As
// declarações do topo do corpo vivem no escopo de função (não num bloco à parte):
// é lá que `let x` colide com o parâmetro `x`.
@(private = "file")
parse_fn_body :: proc(p: ^Parser, info: ^Params_Info) -> ^Node {
    blk := new(Node)
    blk.kind = .Block
    if !expect(p, .LBrace) do return blk
    saved_no_in := p.no_in
    p.no_in = false
    defer p.no_in = saved_no_in
    if parse_directives(p) && info != nil && info.non_simple {
        syntax_error(p, "Illegal 'use strict' directive in function with non-simple parameter list")
    }
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        append(&blk.body, parse_statement(p))
    }
    expect(p, .RBrace)
    return blk
}

// ── fronteira de `arguments` ─────────────────────────────────────────────────
// Toda função NÃO-arrow tem o SEU objeto `arguments`; uma arrow não, ela enxerga
// o da envolvente. Envolver params+corpo neste par diz, no fim, se este nó de
// função precisa mesmo do objeto — o que evita alocar um ^Array por chamada em
// código que nunca o menciona (a maioria esmagadora). Chamar ANTES de
// parse_params: um default (`function f(a = arguments[0])`) também conta p/ f.
@(private = "file")
fn_args_enter :: proc(p: ^Parser) -> bool {
    saved := p.saw_arguments
    p.saw_arguments = false
    return saved
}

// Carimba o nó e devolve o flag ao contexto da função ENVOLVENTE (um `arguments`
// usado só na função aninhada não obriga a externa a materializar o dela).
@(private = "file")
fn_args_exit :: proc(p: ^Parser, n: ^Node, saved: bool) {
    n.uses_arguments = p.saw_arguments
    p.saw_arguments = saved
}

/// class Nome extends Super { constructor(...){} metodo(...){} static m(){} }
// Açúcar sobre função-construtora + objeto prototype (montado no eval .Class).
// O corpo (e o `extends`) de uma classe é SEMPRE strict.
@(private = "file")
parse_class :: proc(p: ^Parser, is_decl := false, anon_ok := false) -> ^Node {
    advance(p) // class
    n := new(Node)
    n.kind = .Class
    saved_strict := p.ctx.strict
    p.ctx.strict = true
    defer p.ctx.strict = saved_strict
    if t := peek(p); t.kind == .Ident && t.text != "extends" {
        check_binding_name(p, t.text)
        n.name = t.text
        advance(p)
    } else if is_decl && !anon_ok {
        unexpected(p) // `class {` como statement: falta o nome
    }
    if is_decl do declare_lexical(p, n.name)
    // extends Super  (LeftHandSideExpression: a.b.C, mixin(A, B), (cond ? A : B))
    if peek(p).kind == .Ident && peek(p).text == "extends" {
        advance(p) // extends
        if t := peek(p); t.kind == .Ident && t.text == "new" {
            n.callee = parse_unary(p)
        } else {
            n.callee = parse_postfix(p)
        }
    }
    if !expect(p, .LBrace) do return n
    append(&p.priv_stack, Priv_Scope{})
    has_ctor := false
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        if peek(p).kind == .Semicolon { advance(p); continue } // ; solto entre métodos
        append(&n.body, parse_class_method(p, n.callee != nil, &has_ctor))
    }
    expect(p, .RBrace)
    priv_pop(p)
    return n
}

// Fecha o escopo de nomes privados de um corpo de classe: o que foi usado e não
// declarado aqui sobe p/ a classe envolvente; sem nenhuma, é SyntaxError.
@(private = "file")
priv_pop :: proc(p: ^Parser) {
    if len(p.priv_stack) == 0 do return
    ps := pop(&p.priv_stack)
    defer { delete(ps.declared); delete(ps.refs) }
    for r in ps.refs {
        if r in ps.declared do continue
        if len(p.priv_stack) > 0 {
            append(&p.priv_stack[len(p.priv_stack) - 1].refs, r)
        } else if !p.is_eval {
            syntax_errorf(p, "Private field '%s' must be declared in an enclosing class", r)
            return
        }
    }
}

// Uso de `#x` (em `o.#x`, `#x in o`): resolvido no fim da classe (priv_pop).
@(private = "file")
priv_ref :: proc(p: ^Parser, name: string) {
    if len(p.priv_stack) == 0 {
        if !p.is_eval do syntax_errorf(p, "Private field '%s' must be declared in an enclosing class", name)
        return
    }
    append(&p.priv_stack[len(p.priv_stack) - 1].refs, name)
}

// Declaração de `#x` num corpo de classe. kind: 1 campo/método, 2 getter, 3 setter.
// Só o par getter+setter pode repetir o nome.
@(private = "file")
priv_declare :: proc(p: ^Parser, name: string, kind: u8) {
    if len(p.priv_stack) == 0 do return
    if name == "#constructor" {
        syntax_error(p, "Classes may not have a private field named '#constructor'")
        return
    }
    ps := &p.priv_stack[len(p.priv_stack) - 1]
    if prev, ok := ps.declared[name]; ok {
        if (prev == 2 && kind == 3) || (prev == 3 && kind == 2) {
            ps.declared[name] = 4
            return
        }
        syntax_errorf(p, "Identifier '%s' has already been declared", name)
        return
    }
    ps.declared[name] = kind
}

// `(params){body}` de um método/getter/setter de object literal (o nome já foi lido).
@(private = "file")
parse_object_method_fn :: proc(p: ^Parser, kind: Fn_Kind = .Method) -> ^Node {
    return parse_object_method_fn_gen(p, false, false, kind)
}

// Idem, com contexto de generator/async. Getter não tem parâmetro; setter tem
// exatamente um (e não rest).
@(private = "file")
parse_object_method_fn_gen :: proc(p: ^Parser, is_gen: bool, is_async := false, kind: Fn_Kind = .Method) -> ^Node {
    m := new(Node)
    m.kind = .Func
    m.is_method = true
    m.is_generator = is_gen
    m.aux = is_async
    saved_args := fn_args_enter(p)
    saved := enter_fn(p, kind, is_async, is_gen)
    info: Params_Info
    defer delete(info.names)
    expect(p, .LParen)
    parse_params(p, m, &info)
    expect(p, .RParen)
    if kind == .Getter && (info.formal > 0 || info.has_rest) {
        syntax_error(p, "Getter must not have any formal parameters.")
    } else if kind == .Setter && info.has_rest {
        syntax_error(p, "Setter function argument must not be a rest parameter")
    } else if kind == .Setter && info.formal != 1 {
        syntax_error(p, "Setter must have exactly one formal parameter.")
    }
    m.right = parse_fn_body(p, &info)
    validate_params(p, &info, kind, "")
    m.strict = p.ctx.strict // ANTES do exit_fn (método de classe é sempre strict)
    exit_fn(p, saved)
    fn_args_exit(p, m, saved_args)
    return m
}

// Palavra contextual (get/set/static/async/of/let) escrita SEM escape: a forma
// escapada (`\u0067et`) é só um identificador, nunca o modificador.
is_kw :: proc(t: Token, w: string) -> bool {
    return t.kind == .Ident && t.text == w && !t.bad_escape
}

// O token pode começar um nome de membro (de classe ou objeto)?
@(private = "file")
is_member_name_start :: proc(t: Token) -> bool {
    #partial switch t.kind {
    case .Ident, .Str, .Number, .LBracket:
        return true
    }
    return false
}

// Inicializador de campo de classe: expressão com `this`/`super.x`/`new.target`
// válidos e `arguments` proibido; `await`/`yield` não são operadores aqui.
@(private = "file")
parse_field_initializer :: proc(p: ^Parser) -> ^Node {
    saved := p.ctx
    p.ctx.in_async = false
    p.ctx.in_gen = false
    p.ctx.super_prop = true
    p.ctx.super_call = false
    p.ctx.new_target_ok = true
    p.ctx.in_class_field = true
    v := parse_assignment(p)
    p.ctx = saved
    return v
}

// Um membro de classe:
//   método: [static] [async] nome(params) { corpo }   -> nó .Func (stat/aux marcados)
//   campo:  [static] nome [= init] ;                   -> nó .ClassField (stat, right=init)
// Método vs campo é decidido pelo `(` que segue o nome.
@(private = "file")
parse_class_method :: proc(p: ^Parser, has_super: bool, has_ctor: ^bool) -> ^Node {
    is_static := false
    if is_kw(peek(p), "static") {
        // bloco de inicialização estática: `static { ... }` — roda com this=classe
        // no ponto do corpo (junto dos campos static, em ordem de fonte).
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if nx.kind == .LBrace {
            advance(p) // consome `static`
            sb := new(Node)
            sb.kind = .StaticBlock
            sb.stat = true
            sb.right = parse_static_block(p)
            return sb
        }
        // "static" é modificador, A MENOS que o próximo token indique que "static"
        // é o PRÓPRIO nome do membro (static(){}, static = 1, static; static\n).
        if nx.kind != .LParen && nx.kind != .Assign && nx.kind != .Semicolon && nx.kind != .RBrace && !(nx.nl_before && !is_member_name_start(nx) && nx.kind != .Star) {
            advance(p)
            is_static = true
        }
    }
    // getter/setter: `get x(){}` / `set [k](v){}` / `get #p(){}` — get/set é
    // modificador quando seguido de um nome de membro (senão é o PRÓPRIO nome:
    // get(){}, get = 1, get;).
    if t := peek(p); is_kw(t, "get") || is_kw(t, "set") {
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if is_member_name_start(nx) {
            is_get := advance(p).text == "get" // consome get/set
            m: ^Node
            key_tok := peek(p)
            if key_tok.kind == .LBracket {
                advance(p) // [
                key := parse_computed_key(p)
                m = parse_object_method_fn(p, .Getter if is_get else .Setter)
                m.left = key // chave computada (name fica "")
            } else {
                advance(p)
                name := prop_key_from_token(p, key_tok)
                if len(name) > 0 && name[0] == '#' && key_tok.kind == .Ident do priv_declare(p, name, 2 if is_get else 3)
                if !is_static && name == "constructor" && key_tok.kind != .Number {
                    syntax_error(p, "Class constructor may not be an accessor")
                } else if is_static && name == "prototype" {
                    syntax_error(p, "Classes may not have a static property named 'prototype'")
                }
                m = parse_object_method_fn(p, .Getter if is_get else .Setter)
                m.name = name
            }
            m.stat = is_static
            m.acc = 1 if is_get else 2 // 1=getter, 2=setter
            return m
        }
    }
    is_async := false
    if t := peek(p); is_kw(t, "async") {
        // async só é modificador se seguido (na mesma linha) de nome de método ou `*`
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if (is_member_name_start(nx) || nx.kind == .Star) && !nx.nl_before {
            advance(p)
            is_async = true
        }
    }
    is_gen := false
    if peek(p).kind == .Star { advance(p); is_gen = true } // *nome(){} = método generator

    // chave COMPUTADA: `[expr]() {}` (método) ou `[expr] = v` (campo) —
    // a expressão vai em .left (name fica ""); eval_class/init resolvem.
    if peek(p).kind == .LBracket {
        advance(p) // [
        key_expr := parse_computed_key(p)
        if peek(p).kind == .LParen {
            m := parse_object_method_fn_gen(p, is_gen, is_async, .Method)
            m.stat = is_static
            m.left = key_expr
            return m
        }
        if is_gen || is_async {
            unexpected(p)
            return key_expr
        }
        f := new(Node)
        f.kind = .ClassField
        f.stat = is_static
        f.left = key_expr
        if peek(p).kind == .Assign {
            advance(p)
            f.right = parse_field_initializer(p)
        }
        consume_semicolon(p)
        return f
    }

    key_tok := peek(p)
    if !is_member_name_start(key_tok) {
        unexpected(p)
        advance(p)
        return make_num(0)
    }
    advance(p)
    name := prop_key_from_token(p, key_tok) // nome do membro (ou "constructor")
    is_priv := key_tok.kind == .Ident && len(name) > 0 && name[0] == '#'
    is_ctor_name := name == "constructor" && key_tok.kind != .Number && !is_priv

    // método: o nome é seguido de '('
    if peek(p).kind == .LParen {
        kind := Fn_Kind.Method
        if is_ctor_name && !is_static {
            if is_gen {
                syntax_error(p, "Class constructor may not be a generator")
            } else if is_async {
                syntax_error(p, "Class constructor may not be an async method")
            } else if has_ctor^ {
                syntax_error(p, "A class may only have one constructor")
            }
            has_ctor^ = true
            kind = .Derived_Ctor if has_super else .Ctor
        }
        if is_static && name == "prototype" {
            syntax_error(p, "Classes may not have a static property named 'prototype'")
        }
        if is_priv do priv_declare(p, name, 1)
        m := parse_object_method_fn_gen(p, is_gen, is_async, kind)
        m.stat = is_static
        m.name = name
        return m
    }
    if is_gen || is_async {
        unexpected(p)
        return make_num(0)
    }

    // campo: nome [= AssignmentExpression] ; (o `;` é opcional — ASI implícito)
    if is_ctor_name {
        syntax_error(p, "Classes may not have a field named 'constructor'")
    } else if is_static && name == "prototype" {
        syntax_error(p, "Classes may not have a static property named 'prototype'")
    }
    if is_priv do priv_declare(p, name, 1)
    f := new(Node)
    f.kind = .ClassField
    f.stat = is_static
    f.name = name
    if peek(p).kind == .Assign {
        advance(p) // =
        f.right = parse_field_initializer(p) // não consome vírgula nem `;`
    }
    consume_semicolon(p)
    return f
}

// `static { ... }`: corpo próprio (var local a ele), sem `return`, `arguments`
// proibido, `await` reservado; `this`/`super.x`/`new.target` valem.
@(private = "file")
parse_static_block :: proc(p: ^Parser) -> ^Node {
    saved := enter_fn(p, .Method, false, false)
    p.ctx.in_function = false
    p.ctx.in_class_field = true
    p.ctx.in_static_block = true
    blk := new(Node)
    blk.kind = .Block
    if expect(p, .LBrace) {
        for peek(p).kind != .RBrace && peek(p).kind != .EOF {
            append(&blk.body, parse_statement(p))
        }
        expect(p, .RBrace)
    }
    exit_fn(p, saved)
    return blk
}

// `[expr]` de chave computada (o `[` já consumido): AssignmentExpression `[+In]`.
@(private = "file")
parse_computed_key :: proc(p: ^Parser) -> ^Node {
    sv := p.no_in
    p.no_in = false
    k := parse_assignment(p)
    p.no_in = sv
    expect(p, .RBracket)
    return k
}

// Continua um alvo member/index a partir de um Ident já consumido: a.x, a[i].c…
// Só aparece em destructuring-EXPRESSÃO (`[a.x] = v`); declarações usam nomes puros.
@(private = "file")
parse_pattern_target_chain :: proc(p: ^Parser, base_name: string) -> ^Node {
    tgt := mk_ident(p, base_name, "pattern-target-chain")
    for {
        if peek(p).kind == .Dot {
            advance(p)
            m := new(Node)
            m.kind = .Member
            m.left = tgt
            if t := peek(p); t.kind == .Ident {
                m.name = t.text
                advance(p)
            } else {
                unexpected(p)
            }
            tgt = m
        } else if peek(p).kind == .LBracket {
            advance(p)
            ix := new(Node)
            ix.kind = .Index
            ix.left = tgt
            ix.right = parse_sequence(p)
            expect(p, .RBracket)
            tgt = ix
        } else {
            break
        }
    }
    return tgt
}

// Alvo simples de um elemento de padrão: em DECLARAÇÃO só um nome; em atribuição
// também `o.x` / `a[i]`. Preenche el.name ou el.left.
@(private = "file")
pattern_target :: proc(p: ^Parser, el: ^Node, binding: bool) {
    if k := peek(p).kind; k == .LBrace || k == .LBracket {
        if !binding && !nested_is_pattern(p) {
            el.left = parse_lhs_target(p)
            return
        }
        el.left = parse_pattern(p, binding)
        return
    }
    t := peek(p)
    if t.kind != .Ident || (len(t.text) > 0 && t.text[0] == '#') {
        unexpected(p)
        return
    }
    if binding {
        el.name = binding_ident(p)
        return
    }
    nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
    if nx.kind == .Dot || nx.kind == .LBracket || nx.kind == .LParen || nx.kind == .QDot || nx.kind == .TplStart {
        el.left = parse_lhs_target(p) // alvo member/index: `[o.x] = v`, `[f().y] = v`
        return
    }
    check_assign_ident(p, t.text)
    advance(p)
    el.name = t.text
}

// Alvo de padrão de atribuição que é EXPRESSÃO (não nome nem padrão aninhado):
// `[o.x] = v`, `[{}[k]] = v`, `[f()[g()]] = v`. Tem de terminar em membro/índice.
@(private = "file")
parse_lhs_target :: proc(p: ^Parser) -> ^Node {
    e: ^Node
    if t := peek(p); t.kind == .Ident && t.text == "new" {
        e = parse_unary(p)
    } else {
        e = parse_postfix(p)
    }
    check_simple_target(p, e, "Invalid destructuring assignment target")
    return e
}

// `[`/`{` aqui abre um padrão ANINHADO (o grupo fecha antes de `=`, `,`, `]`, `}`)
// ou é o começo de uma expressão-alvo (`{}[k]`, `[a][0]`)?
@(private = "file")
nested_is_pattern :: proc(p: ^Parser) -> bool {
    depth := 0
    for j := p.pos; j < len(p.toks); j += 1 {
        #partial switch p.toks[j].kind {
        case .LBracket, .LBrace, .LParen:
            depth += 1
        case .RBracket, .RBrace, .RParen:
            depth -= 1
            if depth == 0 {
                #partial switch p.toks[min(j + 1, len(p.toks) - 1)].kind {
                case .Assign, .Comma, .RBracket, .RBrace, .EOF:
                    return true
                case .Ident:
                    nt := p.toks[min(j + 1, len(p.toks) - 1)]
                    return nt.text == "of" || nt.text == "in"
                }
                return false
            }
        case .EOF:
            return true
        }
    }
    return true
}

// Identificador como ALVO de atribuição: palavra reservada não; `eval`/`arguments`
// não em strict.
@(private = "file")
check_assign_ident :: proc(p: ^Parser, name: string) {
    if is_reserved_word(name) {
        syntax_errorf(p, "Unexpected token '%s'", name)
    } else if p.ctx.strict && (name == "eval" || name == "arguments") {
        syntax_error(p, "Unexpected eval or arguments in strict mode")
    } else if p.ctx.strict && is_strict_reserved(name) {
        syntax_error(p, "Unexpected strict mode reserved word")
    } else if name == "yield" && p.ctx.in_gen {
        syntax_error(p, "Unexpected identifier 'yield'")
    } else if name == "await" && (p.ctx.in_async || p.is_module || p.ctx.in_static_block) {
        syntax_error(p, "Unexpected reserved word")
    }
}

// Padrão de desestruturação: { a, b: c, d = 5, e: {f} } ou [ x, , y = 1, [z] ].
// Devolve um nó .Pattern (bval = objeto?) com uma lista de .PatElem.
// `binding`: padrão de DECLARAÇÃO/parâmetro (alvos só nomes) vs de atribuição.
@(private = "file")
parse_pattern :: proc(p: ^Parser, binding := true) -> ^Node {
    n := new(Node)
    n.kind = .Pattern
    n.strict = p.ctx.strict // destructuring-ATRIBUIÇÃO strict: alvo que falha lança
    if peek(p).kind == .LBrace {
        n.bval = true
        advance(p) // {
        for peek(p).kind != .RBrace && peek(p).kind != .EOF {
            if peek(p).kind == .DotDotDot { // {a, ...resto}
                advance(p)
                el := new(Node); el.kind = .PatElem; el.bval = true
                if binding {
                    el.name = binding_ident(p)
                } else if t := peek(p); t.kind == .Ident {
                    nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
                    if nx.kind == .Dot || nx.kind == .LBracket || nx.kind == .LParen {
                        el.left = parse_lhs_target(p)
                    } else {
                        check_assign_ident(p, t.text)
                        advance(p)
                        el.name = t.text
                    }
                } else {
                    unexpected(p)
                }
                append(&n.body, el)
                if peek(p).kind == .Comma do syntax_error(p, "Rest element must be last element")
                break // rest é o último
            }
            el := new(Node)
            el.kind = .PatElem
            if peek(p).kind == .LBracket { // chave COMPUTADA: { [expr]: target } — expr vai em .third
                advance(p) // [
                el.third = parse_computed_key(p)
                expect(p, .Colon) // computada SEMPRE exige ':' + alvo
                pattern_target(p, el, binding)
            } else {
                kt := peek(p)
                if (kt.kind != .Ident && kt.kind != .Str && kt.kind != .Number) || (kt.kind == .Ident && len(kt.text) > 0 && kt.text[0] == '#') {
                    unexpected(p)
                    break
                }
                advance(p)
                el.str = prop_key_from_token(p, kt) // chave-fonte (Ident, Str ou Número)
                if peek(p).kind == .Colon { // rename ou aninhado: {a: c} / {a: {b}} / {a: o.x}
                    advance(p)
                    pattern_target(p, el, binding)
                } else {
                    // atalho {a} => bind "a" da chave "a" — tem de ser identificador válido
                    if kt.kind != .Ident || kt.text[0] == '#' {
                        unexpected(p)
                        break
                    }
                    if binding {
                        check_binding_name(p, kt.text)
                    } else {
                        check_assign_ident(p, kt.text)
                    }
                    el.name = el.str
                }
            }
            if peek(p).kind == .Assign { // default: {a = 5}
                advance(p)
                el.right = parse_assignment(p)
            }
            append(&n.body, el)
            if peek(p).kind == .Comma do advance(p); else do break
        }
        expect(p, .RBrace)
    } else if peek(p).kind == .LBracket {
        n.bval = false
        advance(p) // [
        for peek(p).kind != .RBracket && peek(p).kind != .EOF {
            if peek(p).kind == .Comma { // buraco: [a, , c]
                el := new(Node); el.kind = .PatElem
                append(&n.body, el)
                advance(p)
                continue
            }
            if peek(p).kind == .DotDotDot { // [a, ...resto] / [a, ...[b, c]]
                advance(p)
                el := new(Node); el.kind = .PatElem; el.bval = true
                pattern_target(p, el, binding)
                append(&n.body, el)
                if peek(p).kind == .Assign {
                    syntax_error(p, "Rest element may not have a default initializer")
                } else if peek(p).kind == .Comma {
                    syntax_error(p, "Rest element must be last element")
                }
                break // rest é o último
            }
            el := new(Node)
            el.kind = .PatElem
            pattern_target(p, el, binding)
            if peek(p).kind == .Assign {
                advance(p)
                el.right = parse_assignment(p)
            }
            append(&n.body, el)
            if peek(p).kind == .Comma do advance(p); else do break
        }
        expect(p, .RBracket)
    } else {
        unexpected(p)
    }
    return n
}

// Lista de parâmetros de função/arrow/método: preenche n.params (nome, ou "" se
// o parâmetro é um padrão) e n.param_pats (o padrão, ou nil), mantidos paralelos.
// Consome a lista até o ')' (exclusive); o chamador consome os parênteses. Os
// nomes vão p/ o escopo de função (colisão com `let` do corpo) e p/ `info`, que o
// validate_params julga depois do corpo.
@(private = "file")
parse_params :: proc(p: ^Parser, n: ^Node, info: ^Params_Info) {
    p.ctx.in_params = true
    defer p.ctx.in_params = false
    names := &info.names
    for peek(p).kind != .RParen && peek(p).kind != .EOF {
        if peek(p).kind == .DotDotDot { // ...xs — recolhe os args restantes
            advance(p)
            info.has_rest = true
            info.non_simple = true
            // O rest aceita um BindingPattern, não só um nome (spec:
            // BindingRestElement : ... BindingPattern) — `function j(e, ...[t]){}`
            // é o que o Babel emite ao compilar `[e, t]` desestruturado, e era o
            // topo das recuperações de parse em figma/angular: pegávamos o texto
            // do token `[` como se fosse o NOME e o resto do padrão virava lixo.
            if k := peek(p).kind; k == .LBracket || k == .LBrace {
                n.rest_pat = parse_pattern(p, binding = true)
                pattern_names(n.rest_pat, names)
            } else {
                n.rest_param = binding_ident(p)
                append(names, n.rest_param)
            }
            if peek(p).kind == .Assign {
                syntax_error(p, "Rest parameter may not have a default initializer")
            } else if peek(p).kind == .Comma {
                syntax_error(p, "Rest parameter must be last formal parameter")
            }
            break // rest é sempre o último
        }
        if k := peek(p).kind; k == .LBrace || k == .LBracket {
            append(&n.params, "")
            pat := parse_pattern(p, binding = true)
            append(&n.param_pats, pat)
            pattern_names(pat, names)
            info.non_simple = true
        } else if k == .Ident {
            nm := binding_ident(p)
            append(&n.params, nm)
            append(&n.param_pats, nil)
            append(names, nm)
        } else {
            unexpected(p)
            break
        }
        info.formal += 1
        // default: `(a = 5)` / `({a} = {})` — vale p/ param simples E padrão
        if peek(p).kind == .Assign {
            advance(p)
            info.non_simple = true
            append(&n.param_defaults, parse_assignment(p))
        } else {
            append(&n.param_defaults, nil)
        }
        if peek(p).kind == .Comma { advance(p); continue }
        break
    }
    if s := p.ctx.scope; s != nil {
        for nm in names {
            if nm == "" do continue
            if s.params[nm] && info.dup == "" do info.dup = nm
            s.params[nm] = true
        }
    }
}

// Um argumento de chamada / elemento de array: `...expr` vira nó .Spread; senão
// é uma expressão normal. O eval (eval_args/.ArrayLit) expande os spreads.
@(private = "file")
parse_arg :: proc(p: ^Parser) -> ^Node {
    if peek(p).kind == .DotDotDot {
        advance(p)
        s := new(Node)
        s.kind = .Spread
        s.left = parse_assignment(p)
        return s
    }
    return parse_assignment(p)
}

// Lista de argumentos de chamada: do '(' JÁ consumido até o ')' (que ela consome).
// Serve os três sítios — `f(a)`, `new X(a)` e `f?.(a)`.
//
// A VÍRGULA FINAL é válida desde ES2017 (`f(a, b,)`) e minificador emite: cada um
// dos três laços consumia a vírgula e chamava parse_arg JÁ EM CIMA do ')', que
// não é posição de expressão — virava um argumento `0` ESPÚRIO (deslocando o
// resto da lista) e uma "recuperação de parse". Testar o fechamento no topo do
// laço resolve os dois casos de uma vez: lista vazia e vírgula final.
@(private = "file")
parse_call_args :: proc(p: ^Parser, n: ^Node) {
    saved_no_in := p.no_in // argumentos são `[+In]` mesmo dentro de cabeçalho de for
    p.no_in = false
    for peek(p).kind != .RParen && peek(p).kind != .EOF {
        append(&n.body, parse_arg(p))
        if peek(p).kind == .Comma { advance(p); continue }
        break
    }
    p.no_in = saved_no_in
    expect(p, .RParen)
}

@(private = "file")
parse_return :: proc(p: ^Parser) -> ^Node {
    if !p.ctx.in_function {
        syntax_error(p, "Illegal return statement")
        return make_num(0)
    }
    advance(p) // return
    n := new(Node)
    n.kind = .Return
    k := peek(p).kind
    // ASI: `return\nexpr` retorna undefined (produção restrita — newline encerra)
    if k != .Semicolon && k != .RBrace && k != .EOF && !peek(p).nl_before {
        n.right = parse_sequence(p) // `return a, b, c` devolve o último
    }
    consume_semicolon(p)
    return n
}

// Corpo de laço: `continue` e `break` sem label passam a valer lá dentro.
@(private = "file")
parse_loop_body :: proc(p: ^Parser) -> ^Node {
    p.ctx.in_loop += 1
    p.ctx.in_breakable += 1
    body := parse_sub_statement(p)
    p.ctx.in_loop -= 1
    p.ctx.in_breakable -= 1
    return body
}

// O grupo [..]/{..} balanceado que começa em p.pos é seguido de `of`/`in`?
// (cabeçalho de for com padrão de ATRIBUIÇÃO: `for ([a, b] of pares)`)
@(private = "file")
pattern_then_of_in :: proc(p: ^Parser) -> bool {
    depth := 0
    for j := p.pos; j < len(p.toks); j += 1 {
        #partial switch p.toks[j].kind {
        case .LBracket, .LBrace, .LParen:
            depth += 1
        case .RBracket, .RBrace, .RParen:
            depth -= 1
            if depth == 0 {
                nx := p.toks[min(j + 1, len(p.toks) - 1)]
                return nx.kind == .Ident && (nx.text == "of" || nx.text == "in")
            }
        case .EOF:
            return false
        }
    }
    return false
}

// for (init; cond; update) body
//   init pode ser var-decl, expressão ou vazio; cond e update podem ser vazios.
@(private = "file")
parse_for :: proc(p: ^Parser) -> ^Node {
    advance(p) // for
    // `for await (x of asyncIter)`: drena um iterável ASSÍNCRONO, aguardando cada
    // resultado. Marcado no ForOf via is_generator (campo livre p/ ForOf).
    is_await := false
    if peek(p).kind == .Ident && peek(p).text == "await" {
        if !p.ctx.in_async && !(p.is_module && !p.ctx.in_function) && !(!p.ctx.in_function && !p.is_eval) {
            unexpected(p)
            return make_num(0)
        }
        advance(p)
        is_await = true
    }
    expect(p, .LParen)
    // o cabeçalho com let/const tem escopo próprio (envolve o corpo): `var x` no
    // corpo colide com `let x` do cabeçalho
    sc := push_scope(p, false)
    defer pop_scope(p, sc)
    n := new(Node)
    n.kind = .For

    make_for_of :: proc(p: ^Parser, is_of, is_await: bool) -> ^Node {
        fo := new(Node)
        fo.kind = .ForOf
        fo.strict = p.ctx.strict // alvo sem declaração (`for (x of a)`) segue as regras strict
        fo.bval = is_of
        fo.is_generator = is_await // for-await (drena iterável assíncrono)
        advance(p) // of/in
        // iterável: em for-IN é uma Expression completa (aceita vírgula-sequência —
        // React faz `for(f in A,B,b)`); em for-OF é AssignmentExpression.
        if is_of do fo.right = parse_assignment(p)
        else do fo.right = parse_sequence(p)
        expect(p, .RParen)
        fo.callee = parse_loop_body(p) // corpo
        return fo
    }
    of_or_in :: proc(p: ^Parser) -> (is_of: bool, ok: bool) {
        t := peek(p)
        if is_kw(t, "of") do return true, true
        if t.kind == .Ident && t.text == "in" do return false, true
        return false, false
    }

    // cabeçalho: pode ser `x of/in it`, `let x of/in it` ou o clássico `init;cond;upd`
    if peek(p).kind == .Semicolon {
        if is_await do unexpected(p)
        advance(p) // sem init
    } else if k := peek(p); k.kind == .Ident && (k.text == "var" || k.text == "const" ||
            (k.text == "let" && (p.ctx.strict || func_tok_is_decl_start(p.toks[min(p.pos + 1, len(p.toks) - 1)])))) {
        advance(p) // var/let/const
        is_var := k.text == "var"
        is_const := k.text == "const"
        p.no_in = true
        d := parse_one_declarator(p, is_var, is_const, true)
        p.no_in = false
        d.aux = is_var
        d.is_const = is_const
        if is_of, ok := of_or_in(p); ok {
            if d.right != nil {
                // Annex B: `for (var x = 1 in o)` só em sloppy, var e nome simples
                if is_of || !is_var || p.ctx.strict || d.left != nil {
                    syntax_error(p, "for-in loop variable declaration may not have an initializer.")
                    return n
                }
            }
            if is_await && !is_of do unexpected(p)
            fo := make_for_of(p, is_of, is_await)
            fo.aux = true      // declarado
            fo.stat = is_var   // `var` no loop-var: function-scoped (leak-out + hoisting)
            fo.is_const = is_const // atribuir ao loop-var dentro do corpo lança
            fo.name = d.name
            fo.left = d.left
            free(n) // não é um for clássico
            free_ast(d.right)
            free(d)
            return fo
        }
        if is_await do unexpected(p)
        // `var/let/const x = ...` de um for clássico: os inits que faltaram agora contam
        if d.right == nil {
            if d.left != nil do syntax_error(p, "Missing initializer in destructuring declaration")
            else if is_const do syntax_error(p, "Missing initializer in const declaration")
        }
        p.no_in = true // no_in cobre os inits; múltiplos declaradores em .body (`for(var i=0,n=x;`)
        for peek(p).kind == .Comma {
            advance(p)
            e := parse_one_declarator(p, is_var, is_const, false)
            e.aux = is_var
            e.is_const = is_const
            append(&d.body, e)
        }
        p.no_in = false
        n.left = d
        expect(p, .Semicolon)
    } else if (peek(p).kind == .LBracket || peek(p).kind == .LBrace) && pattern_then_of_in(p) {
        // `for ([a, b] of pares)` / `for ({x} of lista)`: padrão de ATRIBUIÇÃO
        pat := parse_pattern(p, binding = false)
        is_of, _ := of_or_in(p)
        if is_await && !is_of do unexpected(p)
        fo := make_for_of(p, is_of, is_await)
        fo.third = pat // alvo de atribuição (ver for_of_run_body)
        free(n)
        return fo
    } else {
        // expressão: pode ser `x of it` (bare) ou o init de um for clássico.
        // no_in: no cabeçalho, `in` marca for-in — não deve virar operador.
        starts_async := peek(p).kind == .Ident && peek(p).text == "async"
        starts_let := peek(p).kind == .Ident && peek(p).text == "let"
        p.no_in = true
        expr := parse_sequence(p) // for(i=0, j=n; ...) — init pode ter vírgula
        p.no_in = false
        if is_of, ok := of_or_in(p); ok {
            if is_of && starts_async && expr.kind == .Ident && !is_await {
                syntax_error(p, "The left-hand side of a for-of loop may not be 'async'.")
                return n
            }
            if is_of && starts_let {
                syntax_error(p, "The left-hand side of a for-of loop may not be 'let'.")
                return n
            }
            if is_await && !is_of do unexpected(p)
            if expr.kind == .Ident {
                check_assign_ident(p, expr.name)
                fo := make_for_of(p, is_of, is_await)
                fo.name = expr.name
                free_ast(expr)
                free(n)
                return fo
            }
            if (expr.kind == .Member || expr.kind == .Index) && !is_optional_chain(expr) {
                fo := make_for_of(p, is_of, is_await)
                fo.third = expr // alvo member/index: `for (o.k in obj)`
                free(n)
                return fo
            }
            syntax_error(p, "Invalid left-hand side in for-loop")
            return n
        }
        if is_await do unexpected(p)
        n.left = expr // init do for clássico
        expect(p, .Semicolon)
    }

    // clássico: cond (vírgula permitida; `in` já é operador normal aqui)
    if peek(p).kind != .Semicolon do n.right = parse_sequence(p)
    expect(p, .Semicolon)

    // update
    if peek(p).kind != .RParen do n.third = parse_sequence(p)
    expect(p, .RParen)

    n.callee = parse_loop_body(p) // corpo
    return n
}

// O token depois de `let` abre uma declaração? (nome, `[` ou `{`)
@(private = "file")
func_tok_is_decl_start :: proc(t: Token) -> bool {
    if t.kind == .LBracket || t.kind == .LBrace do return true
    return t.kind == .Ident && t.text != "in" && t.text != "of" && t.text != "instanceof"
}

@(private = "file")
parse_while :: proc(p: ^Parser) -> ^Node {
    advance(p) // while
    expect(p, .LParen)
    cond := parse_sequence(p)
    expect(p, .RParen)
    n := new(Node)
    n.kind = .While
    n.left = cond
    n.right = parse_loop_body(p)
    return n
}

// do corpo while (cond);
@(private = "file")
parse_do_while :: proc(p: ^Parser) -> ^Node {
    advance(p) // do
    n := new(Node)
    n.kind = .DoWhile
    n.right = parse_loop_body(p) // corpo
    expect_word(p, "while")
    expect(p, .LParen)
    n.left = parse_sequence(p)
    expect(p, .RParen)
    // o `;` depois de do-while é SEMPRE inserível (ASI especial, spec 12.10.1)
    if peek(p).kind == .Semicolon do advance(p)
    return n
}

// switch (d) { case e: stmts ... default: stmts }
@(private = "file")
parse_switch :: proc(p: ^Parser) -> ^Node {
    advance(p) // switch
    expect(p, .LParen)
    n := new(Node)
    n.kind = .Switch
    n.left = parse_sequence(p)
    expect(p, .RParen)
    if !expect(p, .LBrace) do return n
    sc := push_scope(p, false) // o bloco de cases é UM escopo
    defer pop_scope(p, sc)
    p.ctx.in_breakable += 1
    defer p.ctx.in_breakable -= 1
    has_default := false
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        t := peek(p)
        if t.kind == .Ident && t.text == "case" {
            advance(p)
            c := new(Node)
            c.kind = .SwitchCase
            c.left = parse_sequence(p)
            expect(p, .Colon)
            collect_case_stmts(p, c)
            append(&n.body, c)
        } else if t.kind == .Ident && t.text == "default" {
            advance(p)
            if has_default {
                syntax_error(p, "More than one default clause in switch statement")
                return n
            }
            has_default = true
            expect(p, .Colon)
            c := new(Node)
            c.kind = .SwitchCase // left = nil => default
            collect_case_stmts(p, c)
            append(&n.body, c)
        } else {
            note_recovery(p, "token inesperado no corpo do switch")
            return n
        }
    }
    expect(p, .RBrace)
    return n
}

// Statements de um case, até o próximo case/default ou o fim do switch.
@(private = "file")
collect_case_stmts :: proc(p: ^Parser, c: ^Node) {
    for {
        t := peek(p)
        if t.kind == .RBrace || t.kind == .EOF do break
        if t.kind == .Ident && (t.text == "case" || t.text == "default") do break
        append(&c.body, parse_statement(p))
    }
}

// try { ... } catch (e) { ... } finally { ... }  — catch e finally opcionais
// (mas pelo menos um dos dois). `catch {` sem parâmetro vale (ES2019).
@(private = "file")
parse_try :: proc(p: ^Parser) -> ^Node {
    advance(p) // try
    n := new(Node)
    n.kind = .Try
    n.left = parse_block(p)
    has_handler := false
    if peek(p).kind == .Ident && peek(p).text == "catch" {
        advance(p)
        has_handler = true
        // o parâmetro e o corpo do catch dividem UM escopo: `catch (e) { let e }` é erro
        sc := push_scope(p, false)
        if peek(p).kind == .LParen {
            advance(p)
            if k := peek(p).kind; k == .LBrace || k == .LBracket {
                n.callee = parse_pattern(p, binding = true) // catch ({ message }) / catch ([a])
                names: [dynamic]string
                pattern_names(n.callee, &names)
                for nm in names {
                    if _, dup := sc.lexical[nm]; dup do redeclared(p, nm)
                    sc.lexical[nm] = 4
                }
                delete(names)
            } else {
                n.name = binding_ident(p)
                if n.name != "" do sc.lexical[n.name] = 3
            }
            expect(p, .RParen)
        }
        n.right = parse_block_in(p, sc)
        pop_scope(p, sc)
    }
    if peek(p).kind == .Ident && peek(p).text == "finally" {
        advance(p)
        has_handler = true
        n.third = parse_block(p)
    }
    if !has_handler do syntax_error(p, "Missing catch or finally after try")
    return n
}

@(private = "file")
parse_block :: proc(p: ^Parser) -> ^Node {
    sc := push_scope(p, false)
    defer pop_scope(p, sc)
    return parse_block_in(p, sc)
}

// `{ ... }` num escopo já aberto pelo chamador (catch usa o do parâmetro).
@(private = "file")
parse_block_in :: proc(p: ^Parser, sc: ^Scope) -> ^Node {
    n := new(Node)
    n.kind = .Block
    if !expect(p, .LBrace) do return n
    // Corpo `{…}` é `[+In]`: um `for (var f = function(){ "a" in o }; …)` tem `in`
    // como OPERADOR dentro do corpo. Cobre corpo de função/método/arrow-com-chaves
    // de uma vez, porque todos passam por aqui. (M146 restaurou parênteses,
    // argumentos, índice, array e objeto — mas ESQUECEU corpo e template, e foi a
    // sonda [unresolved] que achou, vendo um Ident chamado `in` em react.dev/figma.)
    saved_no_in := p.no_in
    p.no_in = false
    defer p.no_in = saved_no_in
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        append(&n.body, parse_statement(p))
    }
    expect(p, .RBrace)
    return n
}

// ── expressões ────────────────────────────────────────────────────────────────

// Entrada pública de expressão (= atribuição, o nível mais baixo).
parse_expr :: proc(p: ^Parser) -> ^Node {
    return parse_assignment(p)
}

// O grupo [..]/{..} balanceado que começa em p.pos é seguido de `=`?
// (lookahead do destructuring-expressão; strings/regex/templates já viraram tokens)
@(private = "file")
destructuring_assign_ahead :: proc(p: ^Parser) -> bool {
    depth := 0
    for j := p.pos; j < len(p.toks); j += 1 {
        #partial switch p.toks[j].kind {
        case .LBracket, .LBrace, .LParen:
            depth += 1
        case .RBracket, .RBrace, .RParen:
            depth -= 1
            if depth == 0 {
                return j + 1 < len(p.toks) && p.toks[j + 1].kind == .Assign
            }
        case .EOF:
            return false
        }
    }
    return false
}

// Operador vírgula (sequência): `a, b, c` avalia todos e devolve o último.
// Usado APENAS onde a vírgula NÃO separa uma lista (grupo (…), return, statement)
// — args/array/objeto continuam parando na vírgula via parse_expr/parse_assignment.
@(private = "file")
parse_sequence :: proc(p: ^Parser) -> ^Node {
    left := parse_assignment(p)
    for peek(p).kind == .Comma {
        advance(p)
        s := new(Node)
        s.kind = .Seq
        s.left = left
        s.right = parse_assignment(p)
        left = s
    }
    return left
}

// Mapeia o token de atribuição para o operador binário do composto.
// `=` puro -> .Assign (sentinela "sem operação"); `+=` -> .Plus; etc.
@(private = "file")
assign_op :: proc(k: Token_Kind) -> (op: Token_Kind, ok: bool) {
    #partial switch k {
    case .Assign:    return .Assign, true
    case .PlusEq:    return .Plus, true
    case .MinusEq:   return .Minus, true
    case .StarEq:    return .Star, true
    case .StarStarEq: return .StarStar, true
    case .SlashEq:   return .Slash, true
    case .PercentEq: return .Percent, true
    case .AmpEq:     return .Amp, true
    case .PipeEq:    return .Pipe, true
    case .CaretEq:   return .Caret, true
    case .ShlEq:     return .Shl, true
    case .ShrEq:     return .Shr, true
    case .UShrEq:    return .UShr, true
    case .AmpAmpEq:    return .AmpAmp, true    // a &&= b (curto-circuito no interp)
    case .PipePipeEq:  return .PipePipe, true  // a ||= b
    case .QQuestionEq: return .QQuestion, true // a ??= b
    }
    return .Assign, false
}

// A cadeia termina num elo OPCIONAL (`a?.b.c`)? Atribuir a ela, usá-la como alvo
// de ++, como callee de `new` ou como tag de template é SyntaxError.
is_optional_chain :: proc(n: ^Node) -> bool {
    for x := n; x != nil; {
        #partial switch x.kind {
        case .Member, .Index:
            if x.bval do return true
            x = x.left
        case .Call:
            if x.bval do return true
            x = x.callee
        case:
            return false
        }
    }
    return false
}

// Alvo simples de atribuição/++/--: identificador, `o.x` ou `o[k]` (não opcional).
@(private = "file")
check_simple_target :: proc(p: ^Parser, n: ^Node, msg: string) -> bool {
    if n == nil do return false
    #partial switch n.kind {
    case .Ident:
        if n.name == "this" || n.name == "super" || n.name == "new.target" {
            syntax_error(p, msg)
            return false
        }
        if p.ctx.strict && (n.name == "eval" || n.name == "arguments") {
            syntax_error(p, "Unexpected eval or arguments in strict mode")
            return false
        }
        return true
    case .Member, .Index:
        if is_optional_chain(n) {
            syntax_error(p, msg)
            return false
        }
        return true
    }
    syntax_error(p, msg)
    return false
}

// O token pode COMEÇAR uma expressão? (operando opcional de yield, await em script)
@(private = "file")
starts_expression :: proc(t: Token) -> bool {
    #partial switch t.kind {
    case .Number, .Str, .Regex, .TplStart, .LParen, .LBracket, .LBrace,
         .Plus, .Minus, .Bang, .Tilde, .PlusPlus, .MinusMinus, .DotDotDot:
        return true
    case .Ident:
        return t.text != "in" && t.text != "of" && t.text != "instanceof"
    }
    return false
}

// Arrow function: `x => corpo` ou `(a, b) => corpo`. Devolve nil se o que vem
// a seguir NÃO for uma arrow (aí o chamador parseia como expressão normal).
// Para o caso `( ... )`, olha adiante nos tokens: acha o ')' casado e verifica
// se o próximo token é '=>' — só então consome como lista de parâmetros.
@(private = "file")
try_parse_arrow :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    last := len(p.toks) - 1

    // prefixo async: `async x => ...` / `async (a, b) => ...` (na MESMA linha)
    is_async := false
    start_pos := p.pos
    if is_kw(t, "async") {
        nx := p.toks[min(p.pos + 1, last)]
        looks_arrow := !nx.nl_before && ((nx.kind == .Ident && p.toks[min(p.pos + 2, last)].kind == .Arrow) || nx.kind == .LParen)
        if looks_arrow {
            is_async = true
            advance(p)
            t = peek(p)
        }
    }

    // forma sem parênteses: x => ...
    if t.kind == .Ident && p.toks[min(p.pos + 1, last)].kind == .Arrow {
        arrow_tok := p.toks[min(p.pos + 1, last)]
        n := new(Node)
        n.kind = .Func
        n.bval = true // arrow: não vincula `this` próprio (herda léxico)
        n.aux = is_async
        // o nome do parâmetro obedece ao contexto EXTERNO também (`await` dentro de
        // função async, `yield` dentro de generator)
        check_binding_name(p, t.text)
        saved := enter_fn(p, .Arrow, is_async, false)
        nm := binding_ident(p) // ident
        if is_async && nm == "await" do syntax_error(p, "Unexpected reserved word")
        append(&n.params, nm)
        append(&n.param_pats, nil)
        append(&n.param_defaults, nil)
        if p.ctx.scope != nil do p.ctx.scope.params[nm] = true
        if arrow_tok.nl_before {
            unexpected(p)
        } else {
            advance(p) // =>
        }
        info: Params_Info
        append(&info.names, nm)
        info.formal = 1
        n.right = parse_arrow_body(p, &info)
        validate_params(p, &info, .Arrow, "")
        delete(info.names)
        exit_fn(p, saved)
        return n
    }

    // forma com parênteses: () => ... / (a, b) => ...
    if t.kind == .LParen {
        depth := 0
        for j := p.pos; j < len(p.toks); j += 1 {
            #partial switch p.toks[j].kind {
            case .LParen:
                depth += 1
            case .RParen:
                depth -= 1
                if depth == 0 {
                    arrow_tok := p.toks[min(j + 1, last)]
                    if arrow_tok.kind != .Arrow {
                        p.pos = start_pos // desfaz o `async` consumido (era só um ident)
                        return nil
                    }
                    advance(p) // (
                    n := new(Node)
                    n.kind = .Func
                    n.bval = true
                    n.aux = is_async
                    outer_async, outer_gen := p.ctx.in_async, p.ctx.in_gen
                    outer_static := p.ctx.in_static_block
                    saved := enter_fn(p, .Arrow, is_async, false)
                    info: Params_Info
                    // nos PARÂMETROS vale o contexto de fora: `(x = yield) => 1` dentro de
                    // generator é erro (o in_params já recusa a expressão)
                    p.ctx.in_gen = outer_gen
                    p.ctx.in_async = is_async || outer_async
                    p.ctx.in_static_block = outer_static
                    parse_params(p, n, &info)
                    p.ctx.in_gen = false
                    p.ctx.in_async = is_async
                    p.ctx.in_static_block = false
                    for nm in info.names {
                        if nm == "await" && (outer_async || outer_static) do syntax_error(p, "Unexpected reserved word")
                        if nm == "yield" && outer_gen do syntax_error(p, "Unexpected identifier 'yield'")
                    }
                    expect(p, .RParen)
                    if arrow_tok.nl_before {
                        unexpected(p)
                    } else {
                        expect(p, .Arrow)
                    }
                    if is_async do for nm in info.names do if nm == "await" do syntax_error(p, "Unexpected reserved word")
                    n.right = parse_arrow_body(p, &info)
                    validate_params(p, &info, .Arrow, "")
                    delete(info.names)
                    exit_fn(p, saved)
                    return n
                }
            case .EOF:
                p.pos = start_pos
                return nil
            }
        }
    }
    p.pos = start_pos // não era arrow: restaura (importa se consumimos `async`)
    return nil
}

// Corpo da arrow: bloco `{...}` como está; corpo-expressão vira açúcar para
// `{ return expr; }` — assim o eval/call_function não mudam nada.
@(private = "file")
parse_arrow_body :: proc(p: ^Parser, info: ^Params_Info) -> ^Node {
    // corpo CONCISO de arrow (`=> expr`) também é `[+In]`; a forma com chaves cai
    // no parse_fn_body, que já restaura.
    saved_no_in := p.no_in
    p.no_in = false
    defer p.no_in = saved_no_in
    if peek(p).kind == .LBrace do return parse_fn_body(p, info)
    blk := new(Node)
    blk.kind = .Block
    ret := new(Node)
    ret.kind = .Return
    ret.right = parse_assignment(p)
    append(&blk.body, ret)
    return blk
}

@(private = "file")
parse_assignment :: proc(p: ^Parser) -> ^Node {
    // yield / yield* — só é operador dentro do corpo de um generator.
    // Precedência de AssignmentExpression (bem baixa). Operando é opcional: um
    // `yield` sozinho pode ser seguido de ) ] } , ; : ou fim (ou quebra de linha).
    if p.ctx.in_gen && peek(p).kind == .Ident && peek(p).text == "yield" {
        if p.ctx.in_params {
            syntax_error(p, "Yield expression not allowed in formal parameter")
            return make_num(0)
        }
        advance(p) // yield
        y := new(Node)
        y.kind = .Yield
        if peek(p).kind == .Star && !peek(p).nl_before {
            advance(p)
            y.bval = true // yield* (delegação): operando obrigatório
            y.left = parse_assignment(p)
        } else if nx := peek(p); !nx.nl_before && (starts_expression(nx) || nx.kind == .Slash || nx.kind == .SlashEq) {
            if nx.kind == .Slash || nx.kind == .SlashEq {
                unexpected(p) // `yield /re/`: o lexer leu divisão (heurística de regex)
                return y
            }
            y.left = parse_assignment(p) // operando (associativo à direita)
        }
        return y
    }
    // destructuring em posição de EXPRESSÃO: `[a, b] = [b, a]` / `({ x } = o)`.
    // Lookahead: se o grupo [..]/{..} balanceado é seguido de `=`, é um padrão de
    // atribuição — parseia direto como Pattern (antes: avaliava só o RHS e o
    // swap sumia em silêncio).
    if k := peek(p).kind; k == .LBracket || k == .LBrace {
        if destructuring_assign_ahead(p) {
            pat := parse_pattern(p, binding = false)
            if !expect(p, .Assign) do return pat
            a := new(Node)
            a.kind = .Assign
            a.strict = p.ctx.strict
            a.op = .Assign
            a.left = pat
            a.right = parse_assignment(p)
            return a
        }
    }
    if a := try_parse_arrow(p); a != nil do return a
    left := parse_conditional(p)
    if op, ok := assign_op(peek(p).kind); ok {
        if left.kind == .ObjectLit || left.kind == .ArrayLit {
            syntax_error(p, "Invalid left-hand side in assignment") // `({a}) = 1`
            return left
        }
        if !check_simple_target(p, left, "Invalid left-hand side in assignment") do return left
        advance(p)
        right := parse_assignment(p) // associativo à direita
        a := new(Node)
        a.kind = .Assign
        a.strict = p.ctx.strict // escrita rejeitada / nome não declarado LANÇAM (ver strict_write_failed)
        a.op = op   // .Assign = simples; binário = composto (+=, -=, ...)
        a.left = left
        a.right = right
        return a
    }
    return left
}

// cond ? then : else   (mais baixo que os lógicos, mais alto que a atribuição)
@(private = "file")
parse_conditional :: proc(p: ^Parser) -> ^Node {
    cond := parse_logical_or(p)
    if peek(p).kind == .Question {
        advance(p)
        sv := p.no_in // o ramo "then" é `[+In]`
        p.no_in = false
        then_br := parse_assignment(p)
        p.no_in = sv
        expect(p, .Colon)
        n := new(Node)
        n.kind = .Ternary
        n.left = cond
        n.right = then_br
        n.third = parse_assignment(p)
        return n
    }
    return cond
}

@(private = "file")
make_logical :: proc(op: Token_Kind, left, right: ^Node) -> ^Node {
    n := new(Node)
    n.kind = .Logical
    n.op = op
    n.left = left
    n.right = right
    return n
}

// `&&`/`||` sem parênteses ao lado de `??` (`a || b ?? c`) é SyntaxError.
@(private = "file")
bare_and_or :: proc(p: ^Parser, n: ^Node) -> bool {
    return n != nil && n.kind == .Logical && (n.op == .AmpAmp || n.op == .PipePipe) && n != p.paren_node
}

@(private = "file")
parse_logical_or :: proc(p: ^Parser) -> ^Node {
    left := parse_logical_and(p)
    if peek(p).kind == .QQuestion {
        if bare_and_or(p, left) {
            unexpected(p)
            return left
        }
        for peek(p).kind == .QQuestion {
            advance(p)
            r := parse_bitwise_or(p)
            left = make_logical(.QQuestion, left, r)
        }
        if k := peek(p).kind; k == .PipePipe || k == .AmpAmp do unexpected(p)
        return left
    }
    for peek(p).kind == .PipePipe {
        advance(p)
        left = make_logical(.PipePipe, left, parse_logical_and(p))
    }
    if peek(p).kind == .QQuestion do unexpected(p)
    return left
}

@(private = "file")
parse_logical_and :: proc(p: ^Parser) -> ^Node {
    left := parse_bitwise_or(p)
    for peek(p).kind == .AmpAmp {
        advance(p)
        left = make_logical(.AmpAmp, left, parse_bitwise_or(p))
    }
    return left
}

// Bitwise, na precedência JS: | mais baixo que ^, que é mais baixo que &,
// todos entre os lógicos e a igualdade.
@(private = "file")
parse_bitwise_or :: proc(p: ^Parser) -> ^Node {
    left := parse_bitwise_xor(p)
    for peek(p).kind == .Pipe {
        advance(p)
        left = make_binary(.Pipe, left, parse_bitwise_xor(p))
    }
    return left
}

@(private = "file")
parse_bitwise_xor :: proc(p: ^Parser) -> ^Node {
    left := parse_bitwise_and(p)
    for peek(p).kind == .Caret {
        advance(p)
        left = make_binary(.Caret, left, parse_bitwise_and(p))
    }
    return left
}

@(private = "file")
parse_bitwise_and :: proc(p: ^Parser) -> ^Node {
    left := parse_equality(p)
    for peek(p).kind == .Amp {
        advance(p)
        left = make_binary(.Amp, left, parse_equality(p))
    }
    return left
}

@(private = "file")
parse_equality :: proc(p: ^Parser) -> ^Node {
    left := parse_comparison(p)
    for {
        k := peek(p).kind
        if k == .EqEq || k == .NotEq || k == .EqEqEq || k == .NotEqEq {
            op := advance(p).kind
            left = make_binary(op, left, parse_comparison(p))
        } else {
            break
        }
    }
    return left
}

@(private = "file")
parse_comparison :: proc(p: ^Parser) -> ^Node {
    // `#x in obj` (ES2022): o nome privado só vale como operando ESQUERDO de `in`
    left: ^Node
    if t := peek(p); t.kind == .Ident && len(t.text) > 1 && t.text[0] == '#' {
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if nx.kind == .Ident && nx.text == "in" && !p.no_in {
            priv_ref(p, t.text)
            advance(p)
            left = mk_ident(p, t.text, "private-in")
        } else {
            unexpected(p)
            return make_num(0)
        }
    } else {
        left = parse_shift(p)
    }
    for {
        t := peek(p)
        if t.kind == .Lt || t.kind == .Gt || t.kind == .LtEq || t.kind == .GtEq {
            op := advance(p).kind
            left = make_binary(op, left, parse_shift(p))
        } else if t.kind == .Ident && t.text == "instanceof" {
            advance(p)
            left = make_binary(.Instanceof, left, parse_shift(p))
        } else if t.kind == .Ident && t.text == "in" && !p.no_in {
            advance(p)
            left = make_binary(.In, left, parse_shift(p))
        } else {
            break
        }
    }
    return left
}

// deslocamentos << >> >>>  (mais alto que comparação, mais baixo que + -)
@(private = "file")
parse_shift :: proc(p: ^Parser) -> ^Node {
    left := parse_additive(p)
    for k := peek(p).kind; k == .Shl || k == .Shr || k == .UShr; k = peek(p).kind {
        advance(p)
        left = make_binary(k, left, parse_additive(p))
    }
    return left
}

@(private = "file")
parse_additive :: proc(p: ^Parser) -> ^Node {
    left := parse_term(p)
    for peek(p).kind == .Plus || peek(p).kind == .Minus {
        op := advance(p).kind
        left = make_binary(op, left, parse_term(p))
    }
    return left
}

@(private = "file")
parse_term :: proc(p: ^Parser) -> ^Node {
    left := parse_exponent(p)
    for peek(p).kind == .Star || peek(p).kind == .Slash || peek(p).kind == .Percent {
        op := advance(p).kind
        left = make_binary(op, left, parse_exponent(p))
    }
    return left
}

// exponenciação `**`: mais alta que * / %, e ASSOCIATIVA À DIREITA
// (2 ** 3 ** 2 == 2 ** 9 == 512). O expoente permite unário (2 ** -1), mas a BASE
// unária sem parênteses (`-2 ** 2`) é SyntaxError — a spec recusa adivinhar.
@(private = "file")
parse_exponent :: proc(p: ^Parser) -> ^Node {
    left := parse_unary(p)
    if peek(p).kind == .StarStar {
        #partial switch left.kind {
        case .Unary, .TypeOf, .Void, .Delete, .Await:
            if left != p.paren_node {
                syntax_error(p, "Unary operator used immediately before exponentiation expression. Parenthesis must be used to disambiguate operator precedence")
                return left
            }
        }
        advance(p)
        return make_binary(.StarStar, left, parse_exponent(p))
    }
    return left
}

// `await` é OPERADOR aqui? Em função async e no topo de módulo, sempre. ⚠️ desvio
// consciente: no TOPO de script clássico o motor também aceita `await x` (a spec
// faria de `await` um identificador) — o REPL e os chamadores contam com isso;
// fica restrito ao caso inequívoco (operando na mesma linha).
@(private = "file")
await_is_operator :: proc(p: ^Parser) -> bool {
    if p.ctx.in_async do return true
    if p.ctx.in_function || p.ctx.in_class_field || p.ctx.in_static_block do return false
    if p.is_module do return true
    if p.is_eval do return false
    nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
    if nx.nl_before do return false
    #partial switch nx.kind {
    case .Number, .Str, .Regex, .TplStart, .LBracket, .LBrace, .Bang, .Tilde:
        return true
    case .Ident:
        return nx.text != "in" && nx.text != "of" && nx.text != "instanceof"
    }
    return false
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> ^Node {
    k := peek(p).kind
    if escaped_keyword(p, peek(p)) do return make_num(0)
    if k == .Minus || k == .Bang || k == .Tilde || k == .Plus {
        op := advance(p).kind
        return make_unary(op, parse_unary(p))
    }
    if t := peek(p); t.kind == .Ident {
        switch t.text {
        case "typeof": // typeof x  (operador unário por palavra-chave)
            advance(p)
            n := new(Node)
            n.kind = .TypeOf
            n.left = parse_unary(p)
            return n
        case "void": // void x — avalia x (efeitos) e devolve undefined
            advance(p)
            n := new(Node)
            n.kind = .Void
            n.left = parse_unary(p)
            return n
        case "delete": // delete obj.prop / obj[k] — remove a propriedade
            advance(p)
            n := new(Node)
            n.kind = .Delete
            n.strict = p.ctx.strict // delete de não-configurável lança
            n.left = parse_unary(p)
            if n.left != nil && n.left.kind == .Ident && p.ctx.strict && n.left.name != "this" {
                syntax_error(p, "Delete of an unqualified identifier in strict mode.")
            } else if n.left != nil && n.left.kind == .Member && len(n.left.name) > 0 && n.left.name[0] == '#' {
                syntax_error(p, "Private fields can not be deleted")
            }
            return n
        case "await": // await expr  (suspende até a promise assentar; ver eval .Await)
            if await_is_operator(p) {
                if p.ctx.in_params {
                    syntax_error(p, "Illegal await-expression in formal parameters of async function")
                    return make_num(0)
                }
                advance(p)
                n := new(Node)
                n.kind = .Await
                n.left = parse_unary(p)
                return n
            }
        case "new":
            return parse_new(p)
        }
    }
    // pré-incremento/decremento: ++x / --x
    if k == .PlusPlus || k == .MinusMinus {
        advance(p)
        u := new(Node)
        u.kind = .Update
        u.strict = p.ctx.strict
        u.op = k       // .PlusPlus ou .MinusMinus
        u.bval = true  // prefixo
        u.left = parse_unary(p)
        check_simple_target(p, u.left, "Invalid left-hand side expression in prefix operation")
        return u
    }
    return parse_postfix(p)
}

// new Ctor(args) / new a.b.Ctor(args) / new Ctor  (parênteses opcionais)
@(private = "file")
parse_new :: proc(p: ^Parser) -> ^Node {
    advance(p) // new
    // meta-property `new.target`: undefined em chamada normal, o construtor
    // sob `new`. Detectado ANTES de parsear o callee (`new` seguido de `.`).
    if peek(p).kind == .Dot {
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if is_kw(nx, "target") {
            if !p.ctx.new_target_ok && !p.is_eval {
                syntax_error(p, "new.target expression is not allowed here")
                return make_num(0)
            }
            advance(p); advance(p) // consome `.` e `target`
            nt := new(Node)
            nt.kind = .NewTarget
            return parse_postfix_from(p, nt)
        }
        unexpected(p)
        return make_num(0)
    }
    n := new(Node)
    n.kind = .New
    callee: ^Node
    if t := peek(p); t.kind == .Ident && t.text == "new" {
        callee = parse_new(p) // new new X()()
    } else if t.kind == .Ident && t.text == "import" && p.toks[min(p.pos + 1, len(p.toks) - 1)].kind != .Dot {
        syntax_error(p, "Cannot use new with import")
        return n
    } else {
        callee = parse_primary(p)
    }
    for { // cadeia de membros ANTES dos args: new a.b.C(...) / new handlers[type](...)
        if peek(p).kind == .Dot {
            advance(p)
            m := new(Node)
            m.kind = .Member
            m.left = callee
            m.name = member_name(p)
            callee = m
        } else if peek(p).kind == .LBracket {
            advance(p)
            ix := new(Node)
            ix.kind = .Index
            ix.left = callee
            sv := p.no_in; p.no_in = false // índice é `[+In]`
            ix.right = parse_sequence(p) // índice é Expression completa: obj[a, b, c]
            p.no_in = sv
            expect(p, .RBracket)
            callee = ix
        } else if peek(p).kind == .TplStart {
            tg := new(Node)
            tg.kind = .Tagged
            tg.callee = callee
            tg.left = parse_template(p, tagged = true)
            callee = tg
        } else {
            break
        }
    }
    n.callee = callee
    if peek(p).kind == .QDot {
        syntax_error(p, "Invalid optional chain from new expression")
        return n
    }
    if peek(p).kind == .LParen {
        advance(p)
        parse_call_args(p, n)
    }
    return parse_postfix_from(p, n) // permite new X(...).membro(...)
}

// Nome depois de `.`/`?.`: IdentifierName (palavra reservada vale: `o.default`,
// `x.class`) ou nome privado `#p` (resolvido no fim da classe).
@(private = "file")
member_name :: proc(p: ^Parser) -> string {
    t := peek(p)
    if t.kind != .Ident {
        unexpected(p)
        return ""
    }
    advance(p)
    if len(t.text) > 0 && t.text[0] == '#' do priv_ref(p, t.text)
    return t.text
}

// Acesso a membro (obj.prop) e chamada (f(args)), encadeáveis.
@(private = "file")
parse_postfix :: proc(p: ^Parser) -> ^Node {
    return parse_postfix_from(p, parse_primary(p))
}

// Continua a cadeia de postfix a partir de um nó já parseado (usado também
// pelo `new`, p/ permitir `new Promise(...).catch(...)`).
@(private = "file")
parse_postfix_from :: proc(p: ^Parser, start: ^Node) -> ^Node {
    node := start
    in_optional := false // já passou por um `?.` nesta cadeia
    for {
        k := peek(p).kind
        if k == .Dot {
            advance(p)
            m := new(Node)
            m.kind = .Member
            m.left = node
            m.name = member_name(p)
            if node.kind == .Ident && node.name == "super" && len(m.name) > 0 && m.name[0] == '#' {
                syntax_error(p, "Unexpected private field")
            }
            node = m
        } else if k == .QDot { // optional chaining: a?.b / a?.[i] / a?.(args)  (bval=opcional)
            advance(p)
            in_optional = true
            nk := peek(p).kind
            if nk == .LParen {
                advance(p)
                call := new(Node); call.kind = .Call; call.callee = node; call.bval = true
                parse_call_args(p, call)
                node = call
            } else if nk == .LBracket {
                advance(p)
                sv := p.no_in; p.no_in = false // índice é `[+In]`
                idx := parse_sequence(p) // índice é Expression completa: obj?.[a, b, c]
                p.no_in = sv
                expect(p, .RBracket)
                m := new(Node); m.kind = .Index; m.left = node; m.right = idx; m.bval = true
                node = m
            } else if nk == .TplStart {
                syntax_error(p, "Invalid tagged template on optional chain")
                return node
            } else {
                m := new(Node); m.kind = .Member; m.left = node; m.bval = true
                m.name = member_name(p)
                node = m
            }
        } else if k == .LBracket {
            advance(p)
            sv := p.no_in; p.no_in = false // índice é `[+In]`
            idx := parse_sequence(p) // índice é Expression completa: obj[a, b, c]
            p.no_in = sv
            expect(p, .RBracket)
            m := new(Node)
            m.kind = .Index
            m.left = node
            m.right = idx
            node = m
        } else if k == .LParen {
            advance(p)
            call := new(Node)
            call.kind = .Call
            call.strict = p.ctx.strict // `eval(...)` direto herda a strictness do chamador
            call.callee = node
            parse_call_args(p, call)
            node = call
        } else if k == .TplStart {
            if in_optional {
                syntax_error(p, "Invalid tagged template on optional chain")
                return node
            }
            // tagged template: expressão seguida de template — tag`a${x}b`
            tg := new(Node)
            tg.kind = .Tagged
            tg.callee = node
            tg.left = parse_template(p, tagged = true)
            node = tg
        } else {
            break
        }
    }
    // pós-incremento/decremento: x++ / x-- (ASI: só na mesma linha; `a\n++b` é a; ++b)
    if k := peek(p).kind; (k == .PlusPlus || k == .MinusMinus) && !peek(p).nl_before {
        check_simple_target(p, node, "Invalid left-hand side expression in postfix operation")
        advance(p)
        u := new(Node)
        u.kind = .Update
        u.strict = p.ctx.strict
        u.op = k
        u.bval = false // sufixo
        u.left = node
        return u
    }
    return node
}

// { a: 1, "b": expr, ... }
// Chave de propriedade a partir do token: para literais NUMÉRICOS a chave é
// ToString(valor) canônico (spec), não o texto-fonte — `{0x1c6: v}` cria "454",
// não "0x1c6"; `{1.50: v}` cria "1.5"; `{1e3: v}` cria "1000". Ident/Str usam o
// texto direto. (Era a RAIZ do decoder-runtime _0x: tabelas de dispatch com
// chaves hex viravam texto cru e o lookup por `[454]` não casava.)
@(private = "file")
prop_key_from_token :: proc(p: ^Parser, t: Token) -> string {
    if t.kind == .Number {
        if t.is_big do return t.text
        sb := strings.builder_make()
        to_text(&sb, t.num)
        s := strings.to_string(sb)
        append(&p.owned_strings, s) // a AST referencia s; o vm assume a posse (vm_exec)
        return s
    }
    if t.kind == .Str do check_string_token(p, t)
    return t.text
}

// Literal de string em código strict: escape octal legado é SyntaxError; escape
// `\x`/`\u` malformado é SyntaxError sempre.
@(private = "file")
check_string_token :: proc(p: ^Parser, t: Token) {
    if t.bad_escape {
        syntax_error(p, "Invalid hexadecimal escape sequence")
    } else if t.legacy_octal && p.ctx.strict {
        syntax_error(p, "Octal escape sequences are not allowed in strict mode.")
    }
}

@(private = "file")
parse_object_literal :: proc(p: ^Parser) -> ^Node {
    advance(p) // {
    n := new(Node)
    n.kind = .ObjectLit
    saved_no_in := p.no_in // valores são `[+In]` (ver o grupo em parse_primary)
    p.no_in = false
    defer p.no_in = saved_no_in
    has_proto := false
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        if peek(p).kind == .DotDotDot { // {...obj, k: v}
            advance(p)
            s := new(Node)
            s.kind = .Spread
            s.left = parse_assignment(p)
            append(&n.params, "")  // chave placeholder; eval detecta pelo kind Spread
            append(&n.body, s)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        // PREFIXO `async` — reconhecido ANTES do generator e da chave computada,
        // porque `async` compõe com os dois: `{async *g(){}}` e `{async [k](){}}`.
        // "async" só é prefixo quando o que vem depois (na MESMA linha) COMEÇA uma
        // chave de método; senão continua sendo chave normal ({async:1} / {async(){}}).
        is_async := false
        if t := peek(p); is_kw(t, "async") {
            nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
            if !nx.nl_before && (nx.kind == .Star || is_member_name_start(nx)) {
                advance(p) // consome async
                is_async = true
            }
        }
        // método generator: `*k(params){...}` e `async *k(params){...}`
        is_gen := false
        if peek(p).kind == .Star {
            advance(p) // *
            is_gen = true
        }
        // getter/setter: `get k(){...}` / `set k(v){...}` — só quando "get"/"set"
        // é seguido de OUTRA chave (senão "get" é uma chave normal).
        if t := peek(p); !is_async && !is_gen && (is_kw(t, "get") || is_kw(t, "set")) {
            nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
            if is_member_name_start(nx) {
                is_get := advance(p).text == "get" // consome get/set
                kind := Fn_Kind.Getter if is_get else .Setter
                if peek(p).kind == .LBracket { // get [k](){...}: accessor com chave computada
                    advance(p)                 // [
                    ck := new(Node)
                    ck.kind = .ComputedKey
                    ck.left = parse_computed_key(p)
                    fn := parse_object_method_fn(p, kind)
                    fn.acc = 1 if is_get else 2
                    ck.right = fn
                    append(&n.params, "")
                    append(&n.body, ck)
                } else {
                    kt := advance(p)
                    if kt.kind == .Ident && len(kt.text) > 0 && kt.text[0] == '#' do unexpected(p)
                    acckey := prop_key_from_token(p, kt) // nome da propriedade (número → canônico)
                    fn := parse_object_method_fn(p, kind)
                    fn.acc = 1 if is_get else 2
                    append(&n.params, acckey)
                    append(&n.body, fn)
                }
                if peek(p).kind == .Comma { advance(p); continue } else do break
            }
        }
        // chave computada: `{[expr]: v}` ou método `{[expr](){}}`
        if peek(p).kind == .LBracket {
            advance(p) // [
            ck := new(Node)
            ck.kind = .ComputedKey
            ck.left = parse_computed_key(p) // expressão da chave
            if peek(p).kind == .LParen {
                ck.right = parse_object_method_fn_gen(p, is_gen, is_async) // [k](){} e async [k](){}
            } else {
                if is_gen || is_async { unexpected(p); return n }
                expect(p, .Colon)
                ck.right = parse_assignment(p)
            }
            append(&n.params, "")
            append(&n.body, ck)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        keytok := peek(p)
        if !is_member_name_start(keytok) || (keytok.kind == .Ident && len(keytok.text) > 0 && keytok.text[0] == '#') {
            note_recovery(p, "chave de literal de objeto não é Ident/Str/Número")
            return n
        }
        advance(p)
        key := prop_key_from_token(p, keytok) // Ident/Str: texto; Número: ToString canônico
        // método abreviado: `k(params){...}` — valor vira função
        if peek(p).kind == .LParen {
            append(&n.params, key)
            append(&n.body, parse_object_method_fn_gen(p, is_gen, is_async))
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        if is_gen || is_async {
            unexpected(p)
            return n
        }
        if peek(p).kind == .Colon {
            advance(p)
            if key == "__proto__" && keytok.kind != .Number {
                // `__proto__: v` duas vezes é SyntaxError (só a forma "chave: valor";
                // shorthand, método e computada não contam)
                if has_proto {
                    syntax_error(p, "Duplicate __proto__ fields are not allowed in object literals")
                    return n
                }
                has_proto = true
            }
            append(&n.params, key)
            append(&n.body, parse_assignment(p)) // valor: não consome a vírgula separadora
        } else {
            // shorthand {a} => {a: a}: a chave tem de ser IdentifierReference
            if keytok.kind != .Ident {
                unexpected(p)
                return n
            }
            check_identifier_reference(p, keytok.text)
            if peek(p).kind == .Assign {
                // `{a = 1}` só existe como PADRÃO (destructuring); em literal é erro
                syntax_error(p, "Invalid shorthand property initializer")
                return n
            }
            append(&n.params, key)
            append(&n.body, mk_ident(p, key, "object-shorthand"))
            if key == "arguments" || key == "eval" do p.saw_arguments = true
        }
        if peek(p).kind == .Comma {
            advance(p)
        } else {
            break
        }
    }
    expect(p, .RBrace)
    return n
}

// Identificador usado como REFERÊNCIA (`x`, `{x}`): não pode ser palavra reservada;
// strict proíbe as reservadas de strict; `yield`/`await` conforme o contexto.
@(private = "file")
check_identifier_reference :: proc(p: ^Parser, name: string) {
    if is_reserved_word(name) {
        syntax_errorf(p, "Unexpected token '%s'", name)
    } else if p.ctx.strict && is_strict_reserved(name) {
        syntax_error(p, "Unexpected strict mode reserved word")
    } else if name == "yield" && p.ctx.in_gen {
        syntax_error(p, "Unexpected identifier 'yield'")
    } else if name == "await" && (p.ctx.in_async || p.is_module || p.ctx.in_static_block) {
        syntax_error(p, "Unexpected reserved word")
    } else if name == "arguments" && p.ctx.in_class_field {
        syntax_error(p, "'arguments' is not allowed in class field initializer or static initialization block")
    }
}

// [ e0, e1, ... ]
@(private = "file")
parse_array_literal :: proc(p: ^Parser) -> ^Node {
    advance(p) // [
    n := new(Node)
    n.kind = .ArrayLit
    saved_no_in := p.no_in // elementos são `[+In]` (ver o grupo em parse_primary)
    p.no_in = false
    defer p.no_in = saved_no_in
    for peek(p).kind != .RBracket && peek(p).kind != .EOF {
        if peek(p).kind == .Comma { // buraco (elisão): [1, , 3]
            u := new(Node)
            u.kind = .Undef
            u.bval = true // marca de ELISÃO: o .ArrayLit deixa um buraco, não um undefined
            append(&n.body, u)
            advance(p)
            continue
        }
        append(&n.body, parse_arg(p)) // aceita ...spread
        if peek(p).kind == .Comma {
            advance(p)
        } else {
            break
        }
    }
    expect(p, .RBracket)
    return n
}

// Template literal estrutural (fluxo TplStart Str (TplExprStart expr TplExprEnd Str)* TplEnd):
// chunks literais em n.params (sempre len(body)+1, vazios inclusive), exprs em n.body.
// Escape inválido num chunk (`\x`, `\u` malformado, octal) só é tolerado em TAGGED.
@(private = "file")
parse_template :: proc(p: ^Parser, tagged := false) -> ^Node {
    advance(p) // .TplStart
    n := new(Node)
    n.kind = .Template
    // chunks CRUS: acumulados à parte e anexados ao FIM de n.params no final, para
    // que os N primeiros sigam sendo os cozidos (ver o comentário em Node.params).
    raws: [dynamic]string
    defer delete(raws)
    loop: for {
        if peek(p).kind == .Str {
            t := peek(p)
            if t.bad_escape && !tagged {
                syntax_error(p, "Invalid escape sequence in template")
                break loop
            }
            append(&n.params, t.text)
            append(&raws, t.flags) // chunk CRU (o lexer o guarda em `flags`)
            advance(p)
        } else {
            note_recovery(p, "template sem trecho literal onde esperado")
            append(&n.params, "")
            append(&raws, "")
            break loop
        }
        #partial switch peek(p).kind {
        case .TplEnd:
            advance(p)
            break loop
        case .TplExprStart:
            advance(p)
            sv := p.no_in // interpolação é `[+In]`, como o grupo `( … )`
            p.no_in = false
            append(&n.body, parse_sequence(p)) // ${} aceita vírgula, como um grupo
            p.no_in = sv
            if peek(p).kind == .TplExprEnd do advance(p)
            else do note_recovery(p, "interpolação de template sem fechamento")
        case:
            note_recovery(p, "token inesperado dentro de template")
            break loop
        }
    }
    for len(raws) < len(n.params) do append(&raws, "")
    for r in raws do append(&n.params, r) // crus na segunda metade
    return n
}

// Flags de regex: só d g i m s u v y, sem repetir, e `u` exclui `v`. O PADRÃO só é
// checado no que é inequivocamente inválido (parêntese desbalanceado, quantificador
// sem alvo): o motor de regex não implementa toda a sintaxe válida, e um padrão
// válido-mas-não-suportado tem de falhar SÓ quando executa, não matar o script.
@(private = "file")
check_regex_literal :: proc(p: ^Parser, pattern, flags: string) {
    seen: [128]bool
    for c in flags {
        ok := false
        switch c {
        case 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y': ok = true
        }
        if !ok || seen[c] {
            syntax_errorf(p, "Invalid regular expression flags")
            return
        }
        seen[c] = true
    }
    if seen['u'] && seen['v'] {
        syntax_error(p, "Invalid regular expression flags")
        return
    }
    depth := 0
    in_class := false
    class_depth := 0 // flag v: classes ANINHAM (`[[a-z]--[aeiou]]`)
    prev_atom := false // há algo p/ o quantificador repetir
    i := 0
    for i < len(pattern) {
        c := pattern[i]
        if c == '\\' {
            i += 2
            prev_atom = true
            continue
        }
        if in_class {
            if c == '[' && seen['v'] {
                class_depth += 1
            } else if c == ']' {
                class_depth -= 1
                if class_depth == 0 { in_class = false; prev_atom = true }
            }
            i += 1
            continue
        }
        switch c {
        case '[':
            in_class = true
            class_depth = 1
        case '(':
            depth += 1
            prev_atom = false
            // (?: (?= (?! (?<= (?<! (?<nome>
            if i + 1 < len(pattern) && pattern[i + 1] == '?' do i += 1
            i += 1
            continue
        case ')':
            depth -= 1
            if depth < 0 {
                syntax_errorf(p, "Invalid regular expression: /%s/%s: Unmatched ')'", pattern, flags)
                return
            }
            prev_atom = true
            i += 1
            continue
        case '|':
            prev_atom = false
            i += 1
            continue
        case '*', '+', '?':
            if !prev_atom {
                syntax_errorf(p, "Invalid regular expression: /%s/%s: Nothing to repeat", pattern, flags)
                return
            }
            // quantificador preguiçoso `*?` / possessivo não existe: `a**` é erro
            if i + 1 < len(pattern) && pattern[i + 1] == '?' do i += 1
            prev_atom = false
            if i + 1 < len(pattern) && (pattern[i + 1] == '*' || pattern[i + 1] == '+') {
                syntax_errorf(p, "Invalid regular expression: /%s/%s: Nothing to repeat", pattern, flags)
                return
            }
            i += 1
            continue
        case '^', '$':
            prev_atom = false
            i += 1
            continue
        }
        prev_atom = true
        i += 1
    }
    if depth > 0 {
        syntax_errorf(p, "Invalid regular expression: /%s/%s: Unterminated group", pattern, flags)
        return
    }
    // modificadores (`(?ii:)`, `(?-:)`, `(?I:)`) e classe da flag v (`[(]`, `[a&&b--c]`):
    // gramáticas que o motor implementa à risca, então o erro é early error de verdade
    if regex_early_error(pattern, flags) {
        syntax_errorf(p, "Invalid regular expression: /%s/%s: Invalid group or class", pattern, flags)
    }
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    if t.kind == .Ident {
        switch t.text {
        case "function": // função como expressão: var f = function(x) { ... }
            return parse_function(p)
        case "class": // classe como expressão: var C = class extends B { ... }
            return parse_class(p)
        case "async": // async function como expressão
            if nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]; nx.kind == .Ident && nx.text == "function" && !nx.nl_before && !t.bad_escape {
                advance(p) // async
                return parse_function(p, is_async = true)
            }
        }
    }
    if t.kind == .LBrace   do return parse_object_literal(p)
    if t.kind == .LBracket do return parse_array_literal(p)
    #partial switch t.kind {
    case .Number:
        if t.legacy_octal && p.ctx.strict {
            if strings.contains_any(t.text, "89") {
                syntax_error(p, "Decimals with leading zeros are not allowed in strict mode.")
            } else {
                syntax_error(p, "Octal literals are not allowed in strict mode.")
            }
            return make_num(0)
        }
        advance(p)
        if t.is_big { // literal BigInt 123n → nó .BigIntLit (str = dígitos)
            n := new(Node)
            n.kind = .BigIntLit
            n.str = t.text
            return n
        }
        return make_num(t.num)
    case .Str:
        check_string_token(p, t)
        advance(p)
        n := new(Node)
        n.kind = .Str
        n.str = t.text
        return n
    case .Regex:
        check_regex_literal(p, t.text, t.flags)
        advance(p)
        n := new(Node)
        n.kind = .Regex
        n.str = t.text    // padrão
        n.name = t.flags  // flags
        return n
    case .TplStart:
        return parse_template(p)
    case .Ident:
        if len(t.text) > 0 && t.text[0] == '#' { // nome privado solto (só vale em `#x in o`)
            unexpected(p)
            return make_num(0)
        }
        switch t.text {
        case "true":
            advance(p)
            n := new(Node); n.kind = .Bool; n.bval = true; return n
        case "false":
            advance(p)
            n := new(Node); n.kind = .Bool; n.bval = false; return n
        case "null":
            advance(p)
            n := new(Node); n.kind = .Null; return n
        case "undefined":
            advance(p)
            // `undefined` é um IDENTIFICADOR (não literal): atribuir a ele é legal em
            // sloppy (e inócuo). Como alvo, vira referência de verdade.
            if _, is_assign := assign_op(peek(p).kind); is_assign do return mk_ident(p, t.text, "primary")
            n := new(Node); n.kind = .Undef; return n
        case "this":
            advance(p)
            return mk_ident(p, t.text, "primary")
        case "super":
            nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
            ok := p.is_eval
            if nx.kind == .LParen do ok = ok || p.ctx.super_call
            else if nx.kind == .Dot || nx.kind == .LBracket do ok = ok || p.ctx.super_prop
            if !ok {
                syntax_error(p, "'super' keyword unexpected here")
                return make_num(0)
            }
            advance(p)
            return mk_ident(p, t.text, "primary")
        case "import":
            advance(p)
            // import(expr) dinâmico / import.meta — M109. (`import` estático nunca
            // chega aqui: parse_statement o desvia p/ parse_import quando o token
            // seguinte não é `(` nem `.`.)
            if peek(p).kind == .LParen {
                advance(p) // (
                n := new(Node); n.kind = .ImportCall
                n.str = p.src_url // referrer léxico (ver Parser.src_url)
                sv := p.no_in; p.no_in = false
                n.left = parse_assignment(p)
                if peek(p).kind == .Comma { // 2º arg (options): parseia e ignora
                    advance(p)
                    if peek(p).kind != .RParen {
                        free_ast(parse_assignment(p))
                        if peek(p).kind == .Comma do advance(p)
                    }
                }
                p.no_in = sv
                expect(p, .RParen)
                return n
            }
            if peek(p).kind == .Dot {
                advance(p) // .
                if is_kw(peek(p), "meta") {
                    if !p.is_module {
                        syntax_error(p, "Cannot use 'import.meta' outside a module")
                        return make_num(0)
                    }
                    advance(p)
                    n := new(Node); n.kind = .ImportMeta; n.str = p.src_url; return n
                }
            }
            unexpected(p)
            return make_num(0)
        }
        if is_reserved_word(t.text) {
            unexpected(p)
            return make_num(0)
        }
        check_identifier_reference(p, t.text)
        advance(p)
        // `arguments` (uso direto) e `eval` (que pode lê-lo no escopo do
        // chamador) obrigam a função envolvente a materializar o objeto.
        if t.text == "arguments" || t.text == "eval" do p.saw_arguments = true
        return mk_ident(p, t.text, "primary")
    case .LParen:
        advance(p)
        if peek(p).kind == .RParen { // `()` só existe como lista de params de arrow
            unexpected(p)
            return make_num(0)
        }
        // `[NoIn]` (o flag p.no_in do cabeçalho de for) vale só no NÍVEL DE TOPO
        // do init: a spec restaura `[+In]` dentro de parênteses
        // (`PrimaryExpression : ( Expression[+In] )`). Sem restaurar,
        // `for (var i = ("a" in o) ? 1 : 2; ...)` não via o `in` como operador e
        // a expressão inteira era despedaçada — era o que sobrava em slack e
        // weather no ranking de recuperações de parse.
        saved_no_in := p.no_in
        p.no_in = false
        inner := parse_sequence(p) // grupo aceita sequência: (a, b, c)
        p.no_in = saved_no_in
        expect(p, .RParen)
        p.paren_node = inner // `(-2) ** 2`, `(a || b) ?? c`, `delete (x)`
        return inner
    }
    note_recovery(p, "token inesperado em posição de expressão")
    return make_num(0)
}
