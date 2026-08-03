package js

// AST: a estrutura que o parser produz e o interpretador percorre.
// Mesma convenção do dom.Node: um `kind` + os campos usados por cada tipo.
//
// M2 acrescenta statements (VarDecl, If, While, Block, ...) além das
// expressões do M1.

Node_Kind :: enum {
    // ── expressões ──────────────────────────────
    Num,      // literal numérico          -> num
    BigIntLit,// literal BigInt (123n)     -> str (dígitos, sem o 'n'; pode ter 0x/0b/0o)
    Str,      // literal de string         -> str
    Regex,    // literal /padrão/flags     -> str(padrão), name(flags)
    Bool,     // true/false                -> bval
    Null,     // null
    Undef,    // undefined
    Ident,    // referência a variável     -> name
    Unary,    // op unário (-x, !x)        -> op, left
    Update,   // ++x / x-- etc.            -> op(++/--), left(alvo), bval(prefixo?)
    Binary,   // op binário (a op b)       -> op, left, right
    Logical,  // a && b / a || b           -> op(&&/||), left, right (curto-circuito)
    Ternary,  // cond ? a : b              -> left(cond), right(then), third(else)
    Seq,      // a, b, c (operador vírgula) -> left, right (avalia left, devolve right)
    TypeOf,   // typeof x                  -> left
    Void,     // void x                    -> left (avalia x, devolve undefined)
    Delete,   // delete obj.prop           -> left (Member/Index)
    Await,    // await expr                -> left
    Yield,    // yield expr / yield* expr  -> left(operando, opc), bval(é yield*?)
    Assign,   // alvo op= valor            -> op(.Assign ou binário p/ +=), left(alvo), right
    Member,   // obj.prop                  -> left(obj), name(prop)
    Index,    // obj[expr]                 -> left(obj), right(chave)
    Call,     // callee(args...)           -> callee, body(args)
    New,      // new Callee(args...)       -> callee, body(args)
    NewTarget,// new.target (meta-property) -> (sem campos)
    Func,     // function name(params) {}  -> name(opc), params, right(corpo Block); stat(método static)
    Class,    // class N extends S {...}    -> name, callee(superclasse, opc), body(métodos .Func e campos .ClassField)
    ClassField, // campo de classe: x = init -> name, stat(static?), right(init, opc; nil = undefined)
    StaticBlock,// bloco `static { ... }` de classe -> right(Block); stat sempre true
    Pattern,  // {a,b}= ou [a,b]=           -> bval(objeto?), body(lista de PatElem)
    PatElem,  // um alvo do padrão          -> str(chave-fonte, obj), name(bind), left(padrão aninhado), right(default), bval(é rest?)
    Spread,   // ...expr (em call/array/obj)-> left(expr)
    Template, // `a${x}b`                   -> params(chunks literais, sempre len(body)+1), body(exprs interpoladas)
    Tagged,   // tag`a${x}b`                -> callee(expressão da tag), left(o nó .Template)
    ObjectLit,// { k: v, ... }             -> params(chaves), body(valores)
    ComputedKey, // { [expr]: v } dentro de ObjectLit -> left(expr da chave), right(valor)
    ArrayLit, // [ e, ... ]                -> body(elementos)

    // ── módulos ES (M109) ───────────────────────
    ImportCall, // import(expr) dinâmico   -> left(expressão do especificador)
    ImportMeta, // import.meta             -> (sem campos; url resolvida no eval)
    ImportDecl, // import estático         -> str(especificador), name(default local ou ""),
                //                            rest_param(nome de `* as ns` ou ""),
                //                            body(nós .Ident: str=nome exportado, name=alias local)
    ExportDecl, // export ...              -> bval=true: default (left=expr)
                //                         -> left=declaração (export const/function/class)
                //                         -> body(nós .Ident: name=local, str=exportado) p/ export {a as b}
                //                         -> str=especificador de re-export ("" se local); aux=true p/ `export *`;
                //                            name=alias de `export * as ns from`

    // ── statements ──────────────────────────────
    ExprStmt, // expressão solta           -> left
    VarDecl,  // var/let/const x = init    -> name, right(init, opcional)
    Return,   // return expr               -> right(opcional)
    Break,    // break [label]           -> name(label, opcional)
    Continue, // continue [label]        -> name(label, opcional)
    Labeled,  // label: stmt             -> name(label), left(statement)
    Throw,    // throw expr                -> right
    Try,      // try/catch/finally         -> left(try), right(catch, opc), name(param), third(finally, opc)
    Block,    // { ... }                   -> body
    If,       // if(cond) then else        -> left(cond), right(then), third(else)
    While,    // while(cond) body          -> left(cond), right(body)
    DoWhile,  // do body while(cond)       -> left(cond), right(body)
    For,      // for(init;cond;upd) body   -> left(init), right(cond), third(upd), callee(body)
    ForOf,    // for(x of/in it) body       -> name(bind simples) OU left(padrão), right(iterável), callee(corpo); bval(of?), aux(declarado?), stat(é var? → function-scoped), is_generator(é `for await`?)
    Switch,   // switch(d) { cases }       -> left(d), body(lista de SwitchCase)
    SwitchCase, // case e: stmts / default -> left(teste; nil = default), body(stmts)
    Program,  // raiz: lista de statements -> body
}

Node :: struct {
    kind:   Node_Kind,
    num:    f64,            // Num
    str:    string,         // Str
    bval:   bool,           // Bool; Func: é arrow; Yield: é yield*
    aux:    bool,           // Func: é async
    decl:   bool,           // Func/Class: é DECLARAÇÃO (statement) — o nome binda no escopo
                            // externo. false = expressão nomeada: o nome só é visível DENTRO
                            // do próprio corpo (spec) — `un=class e{}` NÃO pode vazar `e`
                            // (clobberava import binding no sveltekit → crates.io BLANK).
    is_generator: bool,     // Func: é generator (function*)
    uses_arguments: bool,   // Func (não-arrow): o corpo MENCIONA `arguments` (ou `eval`,
                            // que poderia lê-lo no escopo do chamador). Decidido no parser
                            // (ver Parser.saw_arguments) para que setup_call_scope só
                            // materialize o objeto `arguments` quando alguém o observa —
                            // era um ^Array por chamada, em TODA chamada.
    is_const: bool,         // VarDecl: declarado com `const` — reatribuir lança TypeError
                            // (o binding é marcado em Env.consts; ver env_assign)
    stat:   bool,           // Func: é método static de uma classe
    acc:    u8,             // Func em object literal: 0=normal/método, 1=getter, 2=setter
    name:   string,         // Ident / VarDecl / Assign / Member(prop)
    rest_param: string,     // Func: nome do rest param (...xs); "" se não houver
    rest_pat: ^Node,        // Func: rest DESESTRUTURADO (`...[t]` / `...{length:n}`);
                            // nil = rest simples (usa rest_param) ou sem rest. A spec
                            // permite BindingPattern no rest, e o Babel emite isso.
    op:     Token_Kind,     // Unary / Binary
    left:   ^Node,
    right:  ^Node,
    third:  ^Node,          // If: ramo else
    callee: ^Node,          // Call: expressão chamada
    params: [dynamic]string, // Func: nomes dos parâmetros (fatias do source; "" se o param é padrão).
                            // Template: os N chunks COZIDOS seguidos dos N chunks CRUS
                            // (sem escapes decodificados), onde N = len(body)+1 — só um
                            // tagged template observa os crus, via `strings.raw`. Ficam no
                            // MESMO array de propósito: um campo dedicado custaria 40 B em
                            // TODO nó da AST (medido: +15% de memória de AST num fonte sem
                            // um único template) para servir a um punhado deles.
    param_pats: [dynamic]^Node, // Func: padrão por parâmetro (nil = param simples); paralelo a params
    param_defaults: [dynamic]^Node, // Func: valor default por parâmetro (nil = sem default); paralelo a params
    body:   [dynamic]^Node, // Block / Program: statements; Call: argumentos
}

make_num :: proc(v: f64) -> ^Node {
    n := new(Node)
    n.kind = .Num
    n.num = v
    return n
}

make_unary :: proc(op: Token_Kind, operand: ^Node) -> ^Node {
    n := new(Node)
    n.kind = .Unary
    n.op = op
    n.left = operand
    return n
}

make_binary :: proc(op: Token_Kind, left, right: ^Node) -> ^Node {
    n := new(Node)
    n.kind = .Binary
    n.op = op
    n.left = left
    n.right = right
    return n
}

// Libera a AST recursivamente (mesma ideia do free_tree do DOM).
free_ast :: proc(n: ^Node) {
    if n == nil do return
    free_ast(n.left)
    free_ast(n.right)
    free_ast(n.third)
    free_ast(n.callee)
    for c in n.body do free_ast(c)
    delete(n.body)
    for pp in n.param_pats do free_ast(pp)
    delete(n.param_pats)
    for pd in n.param_defaults do free_ast(pd)
    delete(n.param_defaults)
    delete(n.params)
    free(n)
}
