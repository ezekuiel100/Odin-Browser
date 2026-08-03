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

// Um ponto onde o parser "engoliu" algo inválido e seguiu em frente. Em sites
// reais isso é tolerância a sintaxe não suportada; em TESTES (JS sabidamente
// válido) é a assinatura de uma miscompilação silenciosa — run/run_with_dom
// entram em pânico se o fonte parseou com recuperação (ver check_parse_recoveries).
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
    gen_depth: int, // >0 enquanto parseia o corpo de um generator: `yield` é keyword
    saw_arguments: bool, // o corpo de função sendo parseado AGORA menciona `arguments`?
                         // Salvo/restaurado na fronteira de cada função NÃO-arrow
                         // (fn_args_enter/exit); arrows NÃO o zeram de propósito — o
                         // `arguments` dentro de uma arrow pertence à função envolvente.
    recoveries: int,               // total de recuperações silenciosas
    rec_notes: [8]Parse_Recovery,  // detalhe das primeiras (p/ diagnóstico)
    owned_strings: [dynamic]string, // strings que a AST referencia mas o parser
                                    // alocou (chaves numéricas canônicas): vm_exec
                                    // transfere p/ vm.owned_strings (posse do vm).
    src_url: string, // URL do módulo/script sendo parseado (M137). Carimbada nos nós
                     // ImportCall/ImportMeta: o referrer de um `import()` é LÉXICO
                     // (a spec captura o script ativo na compilação), não o módulo
                     // que estiver correndo na hora da chamada.
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

note_recovery :: proc(p: ^Parser, what: string) {
    if p.recoveries < len(p.rec_notes) {
        t := peek(p)
        snip := recovery_snippet(p) // DIAG: janela de tokens ao redor do desync
        p.rec_notes[p.recoveries] = Parse_Recovery{pos = p.pos, kind = t.kind, text = snip, what = what}
    }
    p.recoveries += 1
}

// DIAG temporário: reconstrói ~9 tokens ao redor de p.pos como texto para
// identificar a sintaxe real que causou o desync (o token que dispara o
// recovery costuma ser downstream). Marca o token disparador com «».
@(private = "file")
recovery_snippet :: proc(p: ^Parser) -> string {
    lo := max(0, p.pos - 12)
    hi := min(len(p.toks), p.pos + 4)
    sb := strings.builder_make()
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
    for peek(p).kind != .EOF {
        append(&prog.body, parse_statement(p))
    }
    return prog
}

@(private = "file")
parse_statement :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    if t.kind == .Semicolon { // statement VAZIO: `;` (if(x); / ;; de minifier)
        advance(p)
        n := new(Node)
        n.kind = .Undef // avaliar dá undefined, sem efeito
        return n
    }
    // labeled statement: `label: stmt`. Em posição de statement, `Ident :` só pode
    // ser um label (React minificado usa `a: switch(...)` + `break a`). Detecta
    // ANTES do switch de keywords (o label nunca é palavra reservada).
    if t.kind == .Ident && p.toks[min(p.pos + 1, len(p.toks) - 1)].kind == .Colon {
        label := advance(p).text // nome do label
        advance(p)               // ':'
        n := new(Node); n.kind = .Labeled
        n.name = label
        n.left = parse_statement(p)
        return n
    }
    if t.kind == .Ident {
        switch t.text {
        case "var", "let", "const":
            return parse_var_decl(p)
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
            f := parse_function(p)
            f.decl = true // declaração: o nome binda no escopo externo
            return f
        case "class":
            c := parse_class(p)
            c.decl = true
            return c
        case "async":
            // async function nome() {} — declaração; async arrows caem no
            // fluxo de expressão abaixo (try_parse_arrow reconhece o prefixo)
            if nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]; nx.kind == .Ident && nx.text == "function" {
                advance(p) // async
                f := parse_function(p)
                f.aux = true
                f.decl = true
                return f
            }
        case "return":
            return parse_return(p)
        case "break":
            advance(p)
            n := new(Node); n.kind = .Break
            // ASI: label só na MESMA linha (`break\nfoo()` é break + chamada)
            if tk := peek(p); tk.kind == .Ident && !tk.nl_before do n.name = advance(p).text
            if peek(p).kind == .Semicolon do advance(p)
            return n
        case "continue":
            advance(p)
            n := new(Node); n.kind = .Continue
            if tk := peek(p); tk.kind == .Ident && !tk.nl_before do n.name = advance(p).text // ASI, como o break
            if peek(p).kind == .Semicolon do advance(p)
            return n
        case "throw":
            advance(p)
            n := new(Node); n.kind = .Throw
            // ASI: `throw\nexpr` é SyntaxError na spec; aqui vira throw undefined
            // em vez de engolir a expressão da linha seguinte
            if !peek(p).nl_before do n.right = parse_sequence(p)
            if peek(p).kind == .Semicolon do advance(p)
            return n
        case "try":
            return parse_try(p)
        case "export":
            return parse_export(p)
        case "import":
            // `import(...)` / `import.meta` são EXPRESSÕES — deixa p/ o fluxo normal.
            if nx := p.toks[min(p.pos + 1, len(p.toks) - 1)].kind; nx != .LParen && nx != .Dot {
                return parse_import(p) // import estático: ignorado (bundle já inlina)
            }
        }
    }
    if t.kind == .LBrace {
        return parse_block(p)
    }
    // expression statement (aceita sequência: `a, b, c;`)
    expr := parse_sequence(p)
    if peek(p).kind == .Semicolon do advance(p)
    s := new(Node)
    s.kind = .ExprStmt
    s.left = expr
    return s
}

// Sintaxe de módulo ES. O navegador roda o bundle como script único (imports já
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
        n.left = parse_assignment(p)
        // `export default function f(){}` / `class C{}`: o nome TAMBÉM binda no
        // escopo do módulo (spec) — trata como declaração.
        if n.left != nil && (n.left.kind == .Func || n.left.kind == .Class) && n.left.name != "" {
            n.left.decl = true
        }
        if peek(p).kind == .Semicolon do advance(p)
        return n
    }
    if t.kind == .LBrace { // export { a, b as c } [from "..."]
        advance(p) // {
        for peek(p).kind == .Ident {
            local := advance(p).text
            exported := local
            if peek(p).kind == .Ident && peek(p).text == "as" { advance(p); exported = advance(p).text }
            append(&n.body, make_module_name_pair(local, exported))
            if peek(p).kind == .Comma { advance(p) } else { break }
        }
        if peek(p).kind == .RBrace do advance(p)
        if peek(p).kind == .Ident && peek(p).text == "from" {
            advance(p)
            if peek(p).kind == .Str do n.str = advance(p).text // re-export
        }
        if peek(p).kind == .Semicolon do advance(p)
        return n
    }
    if t.kind == .Star { // export * [as ns] from "..."
        advance(p) // *
        n.aux = true
        if peek(p).kind == .Ident && peek(p).text == "as" { advance(p); n.name = advance(p).text }
        if peek(p).kind == .Ident && peek(p).text == "from" {
            advance(p)
            if peek(p).kind == .Str do n.str = advance(p).text
        }
        if peek(p).kind == .Semicolon do advance(p)
        return n
    }
    // export const/let/var/function/class/async — embrulha a declaração;
    // o eval a executa E registra os nomes declarados como exports.
    n.left = parse_statement(p)
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
        if peek(p).kind == .Semicolon do advance(p)
        return n
    }
    // default import: `import D [, ...] from`
    if peek(p).kind == .Ident && peek(p).text != "from" {
        n.name = advance(p).text
        if peek(p).kind == .Comma do advance(p)
    }
    if peek(p).kind == .Star { // * as ns
        advance(p)
        if peek(p).kind == .Ident && peek(p).text == "as" { advance(p); n.rest_param = advance(p).text }
    } else if peek(p).kind == .LBrace { // { a, b as c }
        advance(p)
        for peek(p).kind == .Ident {
            imported := advance(p).text
            local := imported
            if peek(p).kind == .Ident && peek(p).text == "as" { advance(p); local = advance(p).text }
            append(&n.body, make_module_name_pair(local, imported))
            if peek(p).kind == .Comma { advance(p) } else { break }
        }
        if peek(p).kind == .RBrace do advance(p)
    }
    if peek(p).kind == .Ident && peek(p).text == "from" {
        advance(p)
        if peek(p).kind == .Str do n.str = advance(p).text
    }
    // sintaxe inesperada: pula até `;`/EOF (robustez do parser antigo)
    if n.str == "" {
        for peek(p).kind != .Semicolon && peek(p).kind != .EOF do advance(p)
    }
    if peek(p).kind == .Semicolon do advance(p)
    return n
}

@(private = "file")
parse_var_decl :: proc(p: ^Parser) -> ^Node {
    is_var := peek(p).text == "var" // var = function-scoped; let/const = block-scoped
    is_const := peek(p).text == "const" // reatribuir lança TypeError (ver env_assign)
    advance(p) // var/let/const
    n := parse_one_declarator(p)
    n.aux = is_var
    n.is_const = is_const
    // múltiplos declaradores: `var a = 1, b = 2, c` — os extras vão em n.body,
    // avaliados no MESMO escopo (eval .VarDecl os percorre).
    for peek(p).kind == .Comma {
        advance(p)
        d := parse_one_declarator(p)
        d.aux = is_var
        d.is_const = is_const
        append(&n.body, d)
    }
    if peek(p).kind == .Semicolon do advance(p)
    return n
}

// Um único declarador: nome-simples ou padrão, com init opcional. Não consome
// vírgula nem ponto-e-vírgula (o chamador cuida da lista).
@(private = "file")
parse_one_declarator :: proc(p: ^Parser) -> ^Node {
    n := new(Node)
    n.kind = .VarDecl
    if k := peek(p).kind; k == .LBrace || k == .LBracket {
        n.left = parse_pattern(p) // destructuring: const {a,b} = x / [a,b] = arr
    } else {
        n.name = advance(p).text // Ident simples
    }
    if peek(p).kind == .Assign {
        advance(p)
        n.right = parse_assignment(p) // NÃO usa parse_expr: a vírgula separa declaradores
    }
    return n
}

@(private = "file")
parse_if :: proc(p: ^Parser) -> ^Node {
    advance(p) // if
    if peek(p).kind == .LParen do advance(p)
    cond := parse_sequence(p) // if(a, b, c) — condição pode ser sequência vírgula
    if peek(p).kind == .RParen do advance(p)
    n := new(Node)
    n.kind = .If
    n.left = cond
    n.right = parse_statement(p)
    if peek(p).kind == .Ident && peek(p).text == "else" {
        advance(p)
        n.third = parse_statement(p)
    }
    return n
}

// function nome(a, b) { ... }   — declaração (statement) ou expressão.
// O nome é opcional em contexto de expressão (função anônima).
@(private = "file")
parse_function :: proc(p: ^Parser) -> ^Node {
    advance(p) // function
    n := new(Node)
    n.kind = .Func
    if peek(p).kind == .Star { advance(p); n.is_generator = true } // function* = generator
    if peek(p).kind == .Ident {
        n.name = advance(p).text
    }
    saved_args := fn_args_enter(p)
    if peek(p).kind == .LParen do advance(p)
    parse_params(p, n)
    if peek(p).kind == .RParen do advance(p)
    n.right = parse_fn_body(p, n.is_generator) // corpo { ... } (yield só é keyword se generator)
    fn_args_exit(p, n, saved_args)
    return n
}

// Parseia o corpo `{...}` de uma função com o contexto de generator certo:
// `yield` é keyword só quando o corpo pertence a um generator. Salva/restaura
// gen_depth para que funções aninhadas (não-generator) NÃO tratem yield como keyword.
@(private = "file")
parse_fn_body :: proc(p: ^Parser, is_gen: bool) -> ^Node {
    saved := p.gen_depth
    p.gen_depth = 1 if is_gen else 0
    body := parse_block(p)
    p.gen_depth = saved
    return body
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

// class Nome extends Super { constructor(...){} metodo(...){} static m(){} }
// Açúcar sobre função-construtora + objeto prototype (montado no eval .Class).
@(private = "file")
parse_class :: proc(p: ^Parser) -> ^Node {
    advance(p) // class
    n := new(Node)
    n.kind = .Class
    if peek(p).kind == .Ident && peek(p).text != "extends" {
        n.name = advance(p).text
    }
    // extends Super  (Super pode ser Ident ou cadeia a.b.C)
    if peek(p).kind == .Ident && peek(p).text == "extends" {
        advance(p) // extends
        sup := parse_primary(p)
        for peek(p).kind == .Dot {
            advance(p)
            prop := advance(p)
            m := new(Node); m.kind = .Member; m.left = sup; m.name = prop.text
            sup = m
        }
        n.callee = sup
    }
    if peek(p).kind == .LBrace do advance(p)
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        if peek(p).kind == .Semicolon { advance(p); continue } // ; solto entre métodos
        append(&n.body, parse_class_method(p))
    }
    if peek(p).kind == .RBrace do advance(p)
    return n
}

// `(params){body}` de um método/getter/setter de object literal (o nome já foi lido).
@(private = "file")
parse_object_method_fn :: proc(p: ^Parser) -> ^Node {
    return parse_object_method_fn_gen(p, false)
}

// Idem, mas parseia o corpo no contexto de generator dado (yield keyword se is_gen).
@(private = "file")
parse_object_method_fn_gen :: proc(p: ^Parser, is_gen: bool) -> ^Node {
    m := new(Node)
    m.kind = .Func
    saved_args := fn_args_enter(p)
    if peek(p).kind == .LParen do advance(p)
    parse_params(p, m)
    if peek(p).kind == .RParen do advance(p)
    m.right = parse_fn_body(p, is_gen)
    fn_args_exit(p, m, saved_args)
    return m
}

// Um membro de classe:
//   método: [static] [async] nome(params) { corpo }   -> nó .Func (stat/aux marcados)
//   campo:  [static] nome [= init] ;                   -> nó .ClassField (stat, right=init)
// Método vs campo é decidido pelo `(` que segue o nome.
@(private = "file")
parse_class_method :: proc(p: ^Parser) -> ^Node {
    is_static := false
    if peek(p).kind == .Ident && peek(p).text == "static" {
        // bloco de inicialização estática: `static { ... }` — roda com this=classe
        // no ponto do corpo (junto dos campos static, em ordem de fonte).
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        if nx.kind == .LBrace {
            advance(p) // consome `static`
            sb := new(Node)
            sb.kind = .StaticBlock
            sb.stat = true
            sb.right = parse_block(p)
            return sb
        }
        // "static" é modificador, A MENOS que o próximo token indique que "static"
        // é o PRÓPRIO nome do membro (static(){}, static = 1, static; static\n).
        if nx.kind != .LParen && nx.kind != .Assign && nx.kind != .Semicolon && nx.kind != .RBrace {
            advance(p)
            is_static = true
        }
    }
    // getter/setter: `get x(){}` / `set x(v){}` — só quando get/set é seguido de
    // um nome de membro e '(' (senão "get"/"set" é o PRÓPRIO nome: get(){}, get=1).
    if (peek(p).text == "get" || peek(p).text == "set") && peek(p).kind == .Ident {
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        nx2 := p.toks[min(p.pos + 2, len(p.toks) - 1)]
        if nx.kind == .LBracket { // get [k](){} — accessor com chave computada
            is_get := advance(p).text == "get" // consome get/set
            advance(p)                          // [
            m := new(Node)
            m.kind = .Func
            m.stat = is_static
            m.acc = 1 if is_get else 2
            m.left = parse_assignment(p) // chave computada (name fica "")
            if peek(p).kind == .RBracket do advance(p)
            if peek(p).kind == .LParen do advance(p)
            parse_params(p, m)
            if peek(p).kind == .RParen do advance(p)
            m.right = parse_block(p)
            return m
        }
        if (nx.kind == .Ident || nx.kind == .Str) && nx2.kind == .LParen {
            is_get := advance(p).text == "get" // consome get/set
            m := new(Node)
            m.kind = .Func
            m.stat = is_static
            m.acc = 1 if is_get else 2 // 1=getter, 2=setter
            m.name = advance(p).text
            advance(p) // (
            parse_params(p, m)
            if peek(p).kind == .RParen do advance(p)
            m.right = parse_block(p) // corpo
            return m
        }
    }
    is_async := false
    if peek(p).kind == .Ident && peek(p).text == "async" {
        // async só é modificador se seguido de nome de método + '(' (campos não são async;
        // {async: ...} não existe em classe, mas `async` como nome de método/campo pode).
        nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
        nx2 := p.toks[min(p.pos + 2, len(p.toks) - 1)]
        if (nx.kind == .Ident || nx.kind == .Str) && nx2.kind == .LParen {
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
        key_expr := parse_assignment(p)
        if peek(p).kind == .RBracket do advance(p)
        if peek(p).kind == .LParen {
            m := new(Node)
            m.kind = .Func
            m.stat = is_static
            m.aux = is_async
            m.is_generator = is_gen
            m.left = key_expr
            advance(p) // (
            saved_args := fn_args_enter(p)
            parse_params(p, m)
            if peek(p).kind == .RParen do advance(p)
            m.right = parse_fn_body(p, is_gen)
            fn_args_exit(p, m, saved_args)
            return m
        }
        f := new(Node)
        f.kind = .ClassField
        f.stat = is_static
        f.left = key_expr
        if peek(p).kind == .Assign {
            advance(p)
            f.right = parse_assignment(p)
        }
        if peek(p).kind == .Semicolon do advance(p)
        return f
    }

    name := advance(p).text // nome do membro (ou "constructor")

    // método: o nome é seguido de '('
    if peek(p).kind == .LParen {
        m := new(Node)
        m.kind = .Func
        m.stat = is_static
        m.aux = is_async
        m.is_generator = is_gen
        m.name = name
        advance(p) // (
        saved_args := fn_args_enter(p)
        parse_params(p, m)
        if peek(p).kind == .RParen do advance(p)
        m.right = parse_fn_body(p, is_gen) // corpo (yield é keyword se generator)
        fn_args_exit(p, m, saved_args)
        return m
    }

    // campo: nome [= AssignmentExpression] ; (o `;` é opcional — ASI implícito)
    f := new(Node)
    f.kind = .ClassField
    f.stat = is_static
    f.name = name
    if peek(p).kind == .Assign {
        advance(p) // =
        f.right = parse_assignment(p) // não consome vírgula nem `;`
    }
    if peek(p).kind == .Semicolon do advance(p)
    return f
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
            m.name = advance(p).text
            tgt = m
        } else if peek(p).kind == .LBracket {
            advance(p)
            ix := new(Node)
            ix.kind = .Index
            ix.left = tgt
            ix.right = parse_expr(p)
            if peek(p).kind == .RBracket do advance(p)
            tgt = ix
        } else {
            break
        }
    }
    return tgt
}

// Padrão de desestruturação: { a, b: c, d = 5, e: {f} } ou [ x, , y = 1, [z] ].
// Devolve um nó .Pattern (bval = objeto?) com uma lista de .PatElem.
@(private = "file")
parse_pattern :: proc(p: ^Parser) -> ^Node {
    n := new(Node)
    n.kind = .Pattern
    if peek(p).kind == .LBrace {
        n.bval = true
        advance(p) // {
        for peek(p).kind != .RBrace && peek(p).kind != .EOF {
            if peek(p).kind == .DotDotDot { // {a, ...resto}
                advance(p)
                el := new(Node); el.kind = .PatElem; el.bval = true
                el.name = advance(p).text
                append(&n.body, el)
                break // rest é o último
            }
            el := new(Node)
            el.kind = .PatElem
            if peek(p).kind == .LBracket { // chave COMPUTADA: { [expr]: target } — expr vai em .third
                advance(p) // [
                el.third = parse_assignment(p)
                if peek(p).kind == .RBracket do advance(p)
                if peek(p).kind == .Colon do advance(p) // computada SEMPRE exige ':' + alvo
                if k := peek(p).kind; k == .LBrace || k == .LBracket {
                    el.left = parse_pattern(p)
                } else {
                    nm := advance(p).text
                    if k2 := peek(p).kind; k2 == .Dot || k2 == .LBracket {
                        el.left = parse_pattern_target_chain(p, nm)
                    } else {
                        el.name = nm
                    }
                }
                if peek(p).kind == .Assign { advance(p); el.right = parse_assignment(p) } // default
                append(&n.body, el)
                if peek(p).kind == .Comma do advance(p); else do break
                continue
            }
            el.str = advance(p).text // chave-fonte (Ident ou Str)
            if peek(p).kind == .Colon { // rename ou aninhado: {a: c} / {a: {b}} / {a: o.x}
                advance(p)
                if k := peek(p).kind; k == .LBrace || k == .LBracket {
                    el.left = parse_pattern(p)
                } else {
                    nm := advance(p).text
                    if k2 := peek(p).kind; k2 == .Dot || k2 == .LBracket {
                        el.left = parse_pattern_target_chain(p, nm) // alvo member/index
                    } else {
                        el.name = nm
                    }
                }
            } else {
                el.name = el.str // atalho {a} => bind "a" da chave "a"
            }
            if peek(p).kind == .Assign { // default: {a = 5}
                advance(p)
                el.right = parse_assignment(p)
            }
            append(&n.body, el)
            if peek(p).kind == .Comma do advance(p); else do break
        }
        if peek(p).kind == .RBrace do advance(p)
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
            if peek(p).kind == .DotDotDot { // [a, ...resto]
                advance(p)
                el := new(Node); el.kind = .PatElem; el.bval = true
                el.name = advance(p).text
                append(&n.body, el)
                break // rest é o último
            }
            el := new(Node)
            el.kind = .PatElem
            if k := peek(p).kind; k == .LBrace || k == .LBracket {
                el.left = parse_pattern(p)
            } else {
                nm := advance(p).text
                if k2 := peek(p).kind; k2 == .Dot || k2 == .LBracket {
                    el.left = parse_pattern_target_chain(p, nm) // alvo member/index: [a.x] = v
                } else {
                    el.name = nm
                }
            }
            if peek(p).kind == .Assign {
                advance(p)
                el.right = parse_assignment(p)
            }
            append(&n.body, el)
            if peek(p).kind == .Comma do advance(p); else do break
        }
        if peek(p).kind == .RBracket do advance(p)
    }
    return n
}

// Lista de parâmetros de função/arrow/método: preenche n.params (nome, ou "" se
// o parâmetro é um padrão) e n.param_pats (o padrão, ou nil), mantidos paralelos.
// Consome a lista até o ')' (exclusive); o chamador consome os parênteses.
@(private = "file")
parse_params :: proc(p: ^Parser, n: ^Node) {
    for peek(p).kind != .RParen && peek(p).kind != .EOF {
        if peek(p).kind == .DotDotDot { // ...xs — recolhe os args restantes
            advance(p)
            // O rest aceita um BindingPattern, não só um nome (spec:
            // BindingRestElement : ... BindingPattern) — `function j(e, ...[t]){}`
            // é o que o Babel emite ao compilar `[e, t]` desestruturado, e era o
            // topo das recuperações de parse em figma/angular: pegávamos o texto
            // do token `[` como se fosse o NOME e o resto do padrão virava lixo.
            if k := peek(p).kind; k == .LBracket || k == .LBrace {
                n.rest_pat = parse_pattern(p)
            } else {
                n.rest_param = advance(p).text
            }
            break // rest é sempre o último
        }
        if k := peek(p).kind; k == .LBrace || k == .LBracket {
            append(&n.params, "")
            append(&n.param_pats, parse_pattern(p))
        } else if k == .Ident {
            append(&n.params, advance(p).text)
            append(&n.param_pats, nil)
        } else {
            advance(p) // vírgulas e afins
            continue
        }
        // default: `(a = 5)` / `({a} = {})` — vale p/ param simples E padrão
        if peek(p).kind == .Assign {
            advance(p)
            append(&n.param_defaults, parse_assignment(p))
        } else {
            append(&n.param_defaults, nil)
        }
        if peek(p).kind == .Comma do advance(p)
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
        s.left = parse_expr(p)
        return s
    }
    return parse_expr(p)
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
    if peek(p).kind == .RParen do advance(p)
}

@(private = "file")
parse_return :: proc(p: ^Parser) -> ^Node {
    advance(p) // return
    n := new(Node)
    n.kind = .Return
    k := peek(p).kind
    // ASI: `return\nexpr` retorna undefined (produção restrita — newline encerra)
    if k != .Semicolon && k != .RBrace && k != .EOF && !peek(p).nl_before {
        n.right = parse_sequence(p) // `return a, b, c` devolve o último
    }
    if peek(p).kind == .Semicolon do advance(p)
    return n
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
        advance(p)
        is_await = true
    }
    if peek(p).kind == .LParen do advance(p)
    n := new(Node)
    n.kind = .For

    declared := false
    is_var := false // `var` no init: function-scoped (leak-out); let/const: block-scoped
    is_const_bind := false // `for (const x of ...)`: rebinda por iteração, mas atribuir no corpo lança
    bind_name: string
    bind_pat: ^Node
    has_binding := false

    // cabeçalho: pode ser `x of/in it`, `let x of/in it` ou o clássico `init;cond;upd`
    if peek(p).kind == .Semicolon {
        advance(p) // sem init
    } else if k := peek(p); k.kind == .Ident && (k.text == "var" || k.text == "let" || k.text == "const") {
        advance(p) // var/let/const
        declared = true
        is_var = k.text == "var"
        is_const_bind = k.text == "const"
        if kk := peek(p).kind; kk == .LBrace || kk == .LBracket {
            bind_pat = parse_pattern(p)
        } else {
            bind_name = advance(p).text
        }
        has_binding = true
    } else {
        // expressão: pode ser `x of it` (bare) ou o init de um for clássico.
        // no_in: no cabeçalho, `in` marca for-in — não deve virar operador.
        p.no_in = true
        expr := parse_sequence(p) // for(i=0, j=n; ...) — init pode ter vírgula
        p.no_in = false
        if t := peek(p); t.kind == .Ident && (t.text == "of" || t.text == "in") && expr.kind == .Ident {
            bind_name = expr.name
            has_binding = true
            free_ast(expr)
        } else {
            n.left = expr // init do for clássico
            if peek(p).kind == .Semicolon do advance(p)
            has_binding = false
        }
    }

    // for-of / for-in?  (só se ainda houver binding e o próximo for of/in)
    if has_binding {
        if t := peek(p); t.kind == .Ident && (t.text == "of" || t.text == "in") {
            fo := new(Node)
            fo.kind = .ForOf
            fo.bval = t.text == "of"
            fo.aux = declared
            fo.stat = is_var // `var` no loop-var: function-scoped (leak-out + hoisting)
            fo.is_const = is_const_bind // atribuir ao loop-var dentro do corpo lança
            fo.is_generator = is_await // for-await (drena iterável assíncrono)
            fo.name = bind_name
            fo.left = bind_pat
            advance(p) // of/in
            // iterável: em for-IN é uma Expression completa (aceita vírgula-sequência);
            // React faz `for(f in A,B,b)` onde a sequência resulta em b. parse_sequence
            // cobre isso (e para de forma inócua no `)` do for-of).
            fo.right = parse_sequence(p)
            if peek(p).kind == .RParen do advance(p)
            fo.callee = parse_statement(p) // corpo
            free(n) // não é um for clássico
            return fo
        }
        // era `var/let/const x = ...` de um for clássico: reconstrói o VarDecl.
        // no_in cobre os inits; múltiplos declaradores em .body (`for(var i=0,n=x;`)
        p.no_in = true
        decl := new(Node)
        decl.kind = .VarDecl
        decl.name = bind_name
        decl.left = bind_pat
        decl.aux = is_var // `var i` no for vaza p/ fora do loop (function-scoped)
        if peek(p).kind == .Assign {
            advance(p)
            decl.right = parse_assignment(p)
        }
        for peek(p).kind == .Comma {
            advance(p)
            d := parse_one_declarator(p)
            d.aux = is_var
            append(&decl.body, d)
        }
        p.no_in = false
        if peek(p).kind == .Semicolon do advance(p)
        n.left = decl
    }

    // clássico: cond (vírgula permitida; `in` já é operador normal aqui)
    if peek(p).kind != .Semicolon do n.right = parse_sequence(p)
    if peek(p).kind == .Semicolon do advance(p)

    // update
    if peek(p).kind != .RParen do n.third = parse_sequence(p)
    if peek(p).kind == .RParen do advance(p)

    n.callee = parse_statement(p) // corpo
    return n
}

@(private = "file")
parse_while :: proc(p: ^Parser) -> ^Node {
    advance(p) // while
    if peek(p).kind == .LParen do advance(p)
    cond := parse_sequence(p)
    if peek(p).kind == .RParen do advance(p)
    n := new(Node)
    n.kind = .While
    n.left = cond
    n.right = parse_statement(p)
    return n
}

// do corpo while (cond);
@(private = "file")
parse_do_while :: proc(p: ^Parser) -> ^Node {
    advance(p) // do
    n := new(Node)
    n.kind = .DoWhile
    n.right = parse_statement(p) // corpo
    if peek(p).kind == .Ident && peek(p).text == "while" do advance(p)
    if peek(p).kind == .LParen do advance(p)
    n.left = parse_sequence(p)
    if peek(p).kind == .RParen do advance(p)
    if peek(p).kind == .Semicolon do advance(p)
    return n
}

// switch (d) { case e: stmts ... default: stmts }
@(private = "file")
parse_switch :: proc(p: ^Parser) -> ^Node {
    advance(p) // switch
    if peek(p).kind == .LParen do advance(p)
    n := new(Node)
    n.kind = .Switch
    n.left = parse_sequence(p)
    if peek(p).kind == .RParen do advance(p)
    if peek(p).kind == .LBrace do advance(p)
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        t := peek(p)
        if t.kind == .Ident && t.text == "case" {
            advance(p)
            c := new(Node)
            c.kind = .SwitchCase
            c.left = parse_expr(p)
            if peek(p).kind == .Colon do advance(p)
            collect_case_stmts(p, c)
            append(&n.body, c)
        } else if t.kind == .Ident && t.text == "default" {
            advance(p)
            if peek(p).kind == .Colon do advance(p)
            c := new(Node)
            c.kind = .SwitchCase // left = nil => default
            collect_case_stmts(p, c)
            append(&n.body, c)
        } else {
            note_recovery(p, "token inesperado no corpo do switch (pulado)")
            advance(p)
        }
    }
    if peek(p).kind == .RBrace do advance(p)
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

// try { ... } catch (e) { ... } finally { ... }  — catch e finally opcionais.
@(private = "file")
parse_try :: proc(p: ^Parser) -> ^Node {
    advance(p) // try
    n := new(Node)
    n.kind = .Try
    n.left = parse_block(p)
    if peek(p).kind == .Ident && peek(p).text == "catch" {
        advance(p)
        if peek(p).kind == .LParen {
            advance(p)
            if k := peek(p).kind; k == .LBrace || k == .LBracket {
                n.callee = parse_pattern(p) // catch ({ message }) / catch ([a])
            } else if k == .Ident {
                n.name = advance(p).text
            }
            if peek(p).kind == .RParen do advance(p)
        }
        n.right = parse_block(p)
    }
    if peek(p).kind == .Ident && peek(p).text == "finally" {
        advance(p)
        n.third = parse_block(p)
    }
    return n
}

@(private = "file")
parse_block :: proc(p: ^Parser) -> ^Node {
    advance(p) // {
    n := new(Node)
    n.kind = .Block
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
    if peek(p).kind == .RBrace do advance(p)
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

// Arrow function: `x => corpo` ou `(a, b) => corpo`. Devolve nil se o que vem
// a seguir NÃO for uma arrow (aí o chamador parseia como expressão normal).
// Para o caso `( ... )`, olha adiante nos tokens: acha o ')' casado e verifica
// se o próximo token é '=>' — só então consome como lista de parâmetros.
@(private = "file")
try_parse_arrow :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    last := len(p.toks) - 1

    // prefixo async: `async x => ...` / `async (a, b) => ...`
    is_async := false
    start_pos := p.pos
    if t.kind == .Ident && t.text == "async" {
        nx := p.toks[min(p.pos + 1, last)]
        looks_arrow := (nx.kind == .Ident && p.toks[min(p.pos + 2, last)].kind == .Arrow) || nx.kind == .LParen
        if looks_arrow {
            is_async = true
            advance(p)
            t = peek(p)
        }
    }

    // forma sem parênteses: x => ...
    if t.kind == .Ident && p.toks[min(p.pos + 1, last)].kind == .Arrow {
        n := new(Node)
        n.kind = .Func
        n.bval = true // arrow: não vincula `this` próprio (herda léxico)
        n.aux = is_async
        append(&n.params, t.text)
        advance(p) // ident
        advance(p) // =>
        n.right = parse_arrow_body(p)
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
                    if p.toks[min(j + 1, last)].kind != .Arrow {
                        p.pos = start_pos // desfaz o `async` consumido (era só um ident)
                        return nil
                    }
                    advance(p) // (
                    n := new(Node)
                    n.kind = .Func
                    n.bval = true
                    n.aux = is_async
                    parse_params(p, n)
                    if peek(p).kind == .RParen do advance(p)
                    if peek(p).kind == .Arrow do advance(p)
                    n.right = parse_arrow_body(p)
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
parse_arrow_body :: proc(p: ^Parser) -> ^Node {
    // arrow NÃO é generator: `yield` dentro do corpo não é keyword (pertenceria ao
    // generator externo, o que é erro de sintaxe no JS real).
    saved := p.gen_depth
    p.gen_depth = 0
    defer p.gen_depth = saved
    // corpo CONCISO de arrow (`=> expr`) também é `[+In]`; a forma com chaves cai
    // no parse_block, que já restaura.
    saved_no_in := p.no_in
    p.no_in = false
    defer p.no_in = saved_no_in
    if peek(p).kind == .LBrace do return parse_block(p)
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
    // yield / yield* — só é keyword dentro do corpo de um generator (gen_depth>0).
    // Precedência de AssignmentExpression (bem baixa). Operando é opcional: um
    // `yield` sozinho pode ser seguido de ) ] } , ; : ou fim.
    if p.gen_depth > 0 && peek(p).kind == .Ident && peek(p).text == "yield" {
        advance(p) // yield
        y := new(Node)
        y.kind = .Yield
        if peek(p).kind == .Star { advance(p); y.bval = true } // yield* (delegação)
        k := peek(p).kind
        if !(k == .RParen || k == .RBracket || k == .RBrace || k == .Comma || k == .Semicolon || k == .Colon || k == .EOF) {
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
            pat := parse_pattern(p)
            if peek(p).kind == .Assign {
                advance(p)
                a := new(Node)
                a.kind = .Assign
                a.op = .Assign
                a.left = pat
                a.right = parse_assignment(p)
                return a
            }
            note_recovery(p, "padrão de destructuring sem `=` após o lookahead (descartado)")
            free_ast(pat) // defensivo — o lookahead garantiu o `=`
        }
    }
    if a := try_parse_arrow(p); a != nil do return a
    left := parse_conditional(p)
    if op, ok := assign_op(peek(p).kind); ok {
        advance(p)
        right := parse_assignment(p) // associativo à direita
        if left.kind == .Ident || left.kind == .Member || left.kind == .Index {
            a := new(Node)
            a.kind = .Assign
            a.op = op   // .Assign = simples; binário = composto (+=, -=, ...)
            a.left = left
            a.right = right
            return a
        }
        // alvo inválido: a ATRIBUIÇÃO É DESCARTADA (só o RHS sobrevive)
        note_recovery(p, "alvo de atribuição inválido (atribuição descartada)")
        free_ast(left)
        return right
    }
    return left
}

// cond ? then : else   (mais baixo que os lógicos, mais alto que a atribuição)
@(private = "file")
parse_conditional :: proc(p: ^Parser) -> ^Node {
    cond := parse_logical_or(p)
    if peek(p).kind == .Question {
        advance(p)
        then_br := parse_assignment(p)
        if peek(p).kind == .Colon do advance(p)
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

@(private = "file")
parse_logical_or :: proc(p: ^Parser) -> ^Node {
    left := parse_logical_and(p)
    for k := peek(p).kind; k == .PipePipe || k == .QQuestion; k = peek(p).kind {
        advance(p)
        left = make_logical(k, left, parse_logical_and(p)) // || e ?? no mesmo nível
    }
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
    left := parse_shift(p)
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
// (2 ** 3 ** 2 == 2 ** 9 == 512). O expoente permite unário (2 ** -1).
@(private = "file")
parse_exponent :: proc(p: ^Parser) -> ^Node {
    left := parse_unary(p)
    if peek(p).kind == .StarStar {
        advance(p)
        return make_binary(.StarStar, left, parse_exponent(p))
    }
    return left
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> ^Node {
    k := peek(p).kind
    if k == .Minus || k == .Bang || k == .Tilde || k == .Plus {
        op := advance(p).kind
        return make_unary(op, parse_unary(p))
    }
    // typeof x  (operador unário por palavra-chave)
    if t := peek(p); t.kind == .Ident && t.text == "typeof" {
        advance(p)
        n := new(Node)
        n.kind = .TypeOf
        n.left = parse_unary(p)
        return n
    }
    // void x — avalia x (efeitos) e devolve undefined
    if t := peek(p); t.kind == .Ident && t.text == "void" {
        advance(p)
        n := new(Node)
        n.kind = .Void
        n.left = parse_unary(p)
        return n
    }
    // delete obj.prop / obj[k] — remove a propriedade
    if t := peek(p); t.kind == .Ident && t.text == "delete" {
        advance(p)
        n := new(Node)
        n.kind = .Delete
        n.left = parse_unary(p)
        return n
    }
    // await expr  (bloqueia até a promise assentar; ver eval .Await)
    if t := peek(p); t.kind == .Ident && t.text == "await" {
        advance(p)
        n := new(Node)
        n.kind = .Await
        n.left = parse_unary(p)
        return n
    }
    // new Ctor(args) / new a.b.Ctor(args) / new Ctor  (parênteses opcionais)
    if t := peek(p); t.kind == .Ident && t.text == "new" {
        advance(p)
        // meta-property `new.target`: undefined em chamada normal, o construtor
        // sob `new`. Detectado ANTES de parsear o callee (`new` seguido de `.`).
        if nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]; peek(p).kind == .Dot && nx.kind == .Ident && nx.text == "target" {
            advance(p); advance(p) // consome `.` e `target`
            nt := new(Node)
            nt.kind = .NewTarget
            return parse_postfix_from(p, nt)
        }
        n := new(Node)
        n.kind = .New
        callee := parse_primary(p)
        for { // cadeia de membros ANTES dos args: new a.b.C(...) / new handlers[type](...)
            if peek(p).kind == .Dot {
                advance(p)
                prop := advance(p)
                m := new(Node)
                m.kind = .Member
                m.left = callee
                m.name = prop.text
                callee = m
            } else if peek(p).kind == .LBracket {
                advance(p)
                ix := new(Node)
                ix.kind = .Index
                ix.left = callee
                sv := p.no_in; p.no_in = false // índice é `[+In]`
                ix.right = parse_sequence(p) // índice é Expression completa: obj[a, b, c]
                p.no_in = sv
                if peek(p).kind == .RBracket do advance(p)
                callee = ix
            } else {
                break
            }
        }
        n.callee = callee
        if peek(p).kind == .LParen {
            advance(p)
            parse_call_args(p, n)
        }
        return parse_postfix_from(p, n) // permite new X(...).membro(...)
    }
    // pré-incremento/decremento: ++x / --x
    if k == .PlusPlus || k == .MinusMinus {
        advance(p)
        u := new(Node)
        u.kind = .Update
        u.op = k       // .PlusPlus ou .MinusMinus
        u.bval = true  // prefixo
        u.left = parse_unary(p)
        return u
    }
    return parse_postfix(p)
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
    for {
        k := peek(p).kind
        if k == .Dot {
            advance(p)
            prop := advance(p) // Ident
            m := new(Node)
            m.kind = .Member
            m.left = node
            m.name = prop.text
            node = m
        } else if k == .QDot { // optional chaining: a?.b / a?.[i] / a?.(args)  (bval=opcional)
            advance(p)
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
                if peek(p).kind == .RBracket do advance(p)
                m := new(Node); m.kind = .Index; m.left = node; m.right = idx; m.bval = true
                node = m
            } else {
                prop := advance(p)
                m := new(Node); m.kind = .Member; m.left = node; m.name = prop.text; m.bval = true
                node = m
            }
        } else if k == .LBracket {
            advance(p)
            sv := p.no_in; p.no_in = false // índice é `[+In]`
            idx := parse_sequence(p) // índice é Expression completa: obj[a, b, c]
            p.no_in = sv
            if peek(p).kind == .RBracket do advance(p)
            m := new(Node)
            m.kind = .Index
            m.left = node
            m.right = idx
            node = m
        } else if k == .LParen {
            advance(p)
            call := new(Node)
            call.kind = .Call
            call.callee = node
            parse_call_args(p, call)
            node = call
        } else if k == .TplStart {
            // tagged template: expressão seguida de template — tag`a${x}b`
            tg := new(Node)
            tg.kind = .Tagged
            tg.callee = node
            tg.left = parse_template(p)
            node = tg
        } else {
            break
        }
    }
    // pós-incremento/decremento: x++ / x-- (ASI: só na mesma linha; `a\n++b` é a; ++b)
    if k := peek(p).kind; (k == .PlusPlus || k == .MinusMinus) && !peek(p).nl_before {
        advance(p)
        u := new(Node)
        u.kind = .Update
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
        sb := strings.builder_make()
        to_text(&sb, t.num)
        s := strings.to_string(sb)
        append(&p.owned_strings, s) // a AST referencia s; o vm assume a posse (vm_exec)
        return s
    }
    return t.text
}

@(private = "file")
parse_object_literal :: proc(p: ^Parser) -> ^Node {
    advance(p) // {
    n := new(Node)
    n.kind = .ObjectLit
    saved_no_in := p.no_in // valores são `[+In]` (ver o grupo em parse_primary)
    p.no_in = false
    defer p.no_in = saved_no_in
    for peek(p).kind != .RBrace && peek(p).kind != .EOF {
        if peek(p).kind == .DotDotDot { // {...obj, k: v}
            advance(p)
            s := new(Node)
            s.kind = .Spread
            s.left = parse_expr(p)
            append(&n.params, "")  // chave placeholder; eval detecta pelo kind Spread
            append(&n.body, s)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        // PREFIXO `async` — reconhecido ANTES do generator e da chave computada,
        // porque `async` compõe com os dois: `{async *g(){}}` e `{async [k](){}}`
        // são as duas formas que o ramo antigo (que exigia chave Ident/Str + '(')
        // NÃO cobria. Elas desincronizavam o parser: `async` era consumido como
        // chave SHORTHAND e virava `ReferenceError: async is not defined` —
        // medido, era 1 recuperação de parse cada.
        // "async" só é prefixo quando o que vem depois COMEÇA uma chave de método;
        // senão continua sendo chave normal ({async:1} / {async(){}}).
        is_async := false
        if peek(p).text == "async" && peek(p).kind == .Ident {
            nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
            nx2 := p.toks[min(p.pos + 2, len(p.toks) - 1)]
            if nx.kind == .Star || nx.kind == .LBracket ||
               ((nx.kind == .Ident || nx.kind == .Str || nx.kind == .Number) && nx2.kind == .LParen) {
                advance(p) // consome async
                is_async = true
            }
        }
        // método generator: `*k(params){...}` e `async *k(params){...}`
        if peek(p).kind == .Star {
            advance(p) // *
            gkey := prop_key_from_token(p, advance(p)) // nome da propriedade (número → canônico)
            fn := parse_object_method_fn_gen(p, true)
            fn.is_generator = true
            fn.aux = is_async // async generator: `for await` do consumidor depende disto
            append(&n.params, gkey)
            append(&n.body, fn)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        // método async de chave simples: `async k(params){...}`
        if is_async && peek(p).kind != .LBracket {
            akey := prop_key_from_token(p, advance(p)) // nome da propriedade (número → canônico)
            fn := parse_object_method_fn(p)
            fn.aux = true // método async (await funciona no corpo)
            append(&n.params, akey)
            append(&n.body, fn)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        // getter/setter: `get k(){...}` / `set k(v){...}` — só quando "get"/"set"
        // é seguido de OUTRA chave (ident/string/[computada]) e de '('
        // (senão "get" é uma chave normal).
        if (peek(p).text == "get" || peek(p).text == "set") && peek(p).kind == .Ident {
            nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]
            nx2 := p.toks[min(p.pos + 2, len(p.toks) - 1)]
            if nx.kind == .LBracket { // get [k](){...}: accessor com chave computada
                is_get := advance(p).text == "get" // consome get/set
                advance(p)                          // [
                ck := new(Node)
                ck.kind = .ComputedKey
                ck.left = parse_assignment(p)
                if peek(p).kind == .RBracket do advance(p)
                fn := parse_object_method_fn(p)
                fn.acc = 1 if is_get else 2
                ck.right = fn
                append(&n.params, "")
                append(&n.body, ck)
                if peek(p).kind == .Comma { advance(p); continue } else do break
            }
            if (nx.kind == .Ident || nx.kind == .Str) && nx2.kind == .LParen {
                is_get := advance(p).text == "get" // consome get/set
                acckey := prop_key_from_token(p, advance(p)) // nome da propriedade (número → canônico)
                fn := parse_object_method_fn(p)
                fn.acc = 1 if is_get else 2
                append(&n.params, acckey)
                append(&n.body, fn)
                if peek(p).kind == .Comma { advance(p); continue } else do break
            }
        }
        // chave computada: `{[expr]: v}` ou método `{[expr](){}}`
        if peek(p).kind == .LBracket {
            advance(p) // [
            ck := new(Node)
            ck.kind = .ComputedKey
            ck.left = parse_assignment(p) // expressão da chave
            if peek(p).kind == .RBracket do advance(p)
            if peek(p).kind == .LParen {
                mfn := parse_object_method_fn(p) // [k](){} e async [k](){}
                mfn.aux = is_async
                ck.right = mfn
            } else {
                if peek(p).kind == .Colon do advance(p)
                ck.right = parse_assignment(p)
            }
            append(&n.params, "")
            append(&n.body, ck)
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        keytok := advance(p)
        key := prop_key_from_token(p, keytok) // Ident/Str: texto; Número: ToString canônico
        // ⚠️ Chave VAZIA vinda de algo que não é uma string: o token era PONTUAÇÃO
        // (operadores não carregam `.text`), ou seja o parser já dessincronizou
        // ANTES daqui. Sem esta guarda o ramo shorthand lá embaixo criava um
        // `.Ident` de nome vazio, que chega ao usuário como
        // `ReferenceError:  is not defined` — uma mensagem que não diz nem o nome
        // nem a sintaxe, e que ABORTA o script. Registrar como recuperação é o que
        // torna o defeito ACHÁVEL: entra na contagem do `--diagnose` com o
        // snippet ao redor, e faz PÂNICO em build de teste.
        // `{"": v}` é legal (chave string vazia) e continua passando.
        if key == "" && (keytok.kind != .Str || peek(p).kind != .Colon) {
            note_recovery(p, "chave de literal de objeto não é Ident/Str/Número")
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        // método abreviado: `k(params){...}` — valor vira função
        if peek(p).kind == .LParen {
            append(&n.params, key)
            append(&n.body, parse_object_method_fn(p))
            if peek(p).kind == .Comma { advance(p); continue } else do break
        }
        shorthand := peek(p).kind != .Colon // {a} => {a: a}
        if peek(p).kind == .Colon do advance(p)
        append(&n.params, key)
        if shorthand { // valor = a própria variável
            append(&n.body, mk_ident(p, key, "object-shorthand"))
        } else {
            append(&n.body, parse_assignment(p)) // valor: não consome a vírgula separadora
        }
        if peek(p).kind == .Comma {
            advance(p)
        } else {
            break
        }
    }
    if peek(p).kind == .RBrace do advance(p)
    return n
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
        if peek(p).kind == .Comma { // buraco (elisão): [1, , 3] — vira undefined
            u := new(Node)
            u.kind = .Undef
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
    if peek(p).kind == .RBracket do advance(p)
    return n
}

// Template literal estrutural (fluxo TplStart Str (TplExprStart expr TplExprEnd Str)* TplEnd):
// chunks literais em n.params (sempre len(body)+1, vazios inclusive), exprs em n.body.
@(private = "file")
parse_template :: proc(p: ^Parser) -> ^Node {
    advance(p) // .TplStart
    n := new(Node)
    n.kind = .Template
    // chunks CRUS: acumulados à parte e anexados ao FIM de n.params no final, para
    // que os N primeiros sigam sendo os cozidos (ver o comentário em Node.params).
    raws: [dynamic]string
    defer delete(raws)
    loop: for {
        if peek(p).kind == .Str {
            append(&n.params, peek(p).text)
            append(&raws, peek(p).flags) // chunk CRU (o lexer o guarda em `flags`)
            advance(p)
        } else {
            note_recovery(p, "template sem trecho literal onde esperado")
            append(&n.params, "")
            append(&raws, "")
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
    for r in raws do append(&n.params, r) // crus na segunda metade
    return n
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> ^Node {
    t := peek(p)
    // função como expressão: var f = function(x) { ... }
    if t.kind == .Ident && t.text == "function" {
        return parse_function(p)
    }
    // classe como expressão: var C = class extends B { ... }
    if t.kind == .Ident && t.text == "class" {
        return parse_class(p)
    }
    // async function como expressão
    if t.kind == .Ident && t.text == "async" {
        if nx := p.toks[min(p.pos + 1, len(p.toks) - 1)]; nx.kind == .Ident && nx.text == "function" {
            advance(p) // async
            f := parse_function(p)
            f.aux = true
            return f
        }
    }
    if t.kind == .LBrace   do return parse_object_literal(p)
    if t.kind == .LBracket do return parse_array_literal(p)
    #partial switch t.kind {
    case .Number:
        advance(p)
        if t.is_big { // literal BigInt 123n → nó .BigIntLit (str = dígitos)
            n := new(Node)
            n.kind = .BigIntLit
            n.str = t.text
            return n
        }
        return make_num(t.num)
    case .Str:
        advance(p)
        n := new(Node)
        n.kind = .Str
        n.str = t.text
        return n
    case .Regex:
        advance(p)
        n := new(Node)
        n.kind = .Regex
        n.str = t.text    // padrão
        n.name = t.flags  // flags
        return n
    case .TplStart:
        return parse_template(p)
    case .Ident:
        advance(p)
        switch t.text {
        case "true":
            n := new(Node); n.kind = .Bool; n.bval = true; return n
        case "false":
            n := new(Node); n.kind = .Bool; n.bval = false; return n
        case "null":
            n := new(Node); n.kind = .Null; return n
        case "undefined":
            n := new(Node); n.kind = .Undef; return n
        case "import":
            // import(expr) dinâmico / import.meta — M109. (`import` estático nunca
            // chega aqui: parse_statement o desvia p/ parse_import quando o token
            // seguinte não é `(` nem `.`.)
            if peek(p).kind == .LParen {
                advance(p) // (
                n := new(Node); n.kind = .ImportCall
                n.str = p.src_url // referrer léxico (ver Parser.src_url)
                n.left = parse_assignment(p)
                for peek(p).kind == .Comma { // 2º arg (options): parseia e ignora
                    advance(p)
                    if peek(p).kind == .RParen do break
                    free_ast(parse_assignment(p))
                }
                if peek(p).kind == .RParen do advance(p)
                return n
            }
            if peek(p).kind == .Dot {
                advance(p) // .
                if peek(p).kind == .Ident && peek(p).text == "meta" {
                    advance(p)
                    n := new(Node); n.kind = .ImportMeta; n.str = p.src_url; return n
                }
            }
            return mk_ident(p, t.text, "primary")
        case:
            // `arguments` (uso direto) e `eval` (que pode lê-lo no escopo do
            // chamador) obrigam a função envolvente a materializar o objeto.
            if t.text == "arguments" || t.text == "eval" do p.saw_arguments = true
            return mk_ident(p, t.text, "primary")
        }
    case .LParen:
        advance(p)
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
        if peek(p).kind == .RParen do advance(p)
        return inner
    case .Plus, .Minus, .Star, .Slash, .Percent, .PlusPlus, .MinusMinus,
         .PlusEq, .MinusEq, .StarEq, .SlashEq, .PercentEq,
         .Assign, .EqEq, .NotEq, .EqEqEq, .NotEqEq, .Lt, .Gt, .LtEq, .GtEq,
         .Bang, .AmpAmp, .PipePipe, .Question, .Arrow,
         .RParen, .LBrace, .RBrace, .LBracket, .RBracket,
         .Semicolon, .Comma, .Dot, .DotDotDot, .Colon,
         .TplEnd, .TplExprStart, .TplExprEnd, .EOF:
        // Token inesperado. Devolvemos 0 para não travar (sites reais têm
        // sintaxe não suportada) — mas REGISTRAMOS: em teste isto é pânico.
        note_recovery(p, "token inesperado em posição de expressão (vira 0)")
        advance(p)
        return make_num(0)
    }
    note_recovery(p, "token inesperado em posição de expressão (vira 0, sem consumir)")
    return make_num(0)
}
