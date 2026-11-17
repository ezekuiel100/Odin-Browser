package js

// EARLY ERRORS (SyntaxError precoce). Antes o parser recuperava em silêncio de
// sintaxe inválida e o script rodava miscompilado; agora o fonte inteiro é
// rejeitado ANTES de executar, com a mensagem no formato do V8.
//
// Três blocos: (1) inválido → SyntaxError com a mensagem certa; (2) VÁLIDO que um
// parser estrito demais rejeitaria (cada caso aqui foi um falso positivo real,
// achado no Test262 ou em bundle) → tem de rodar; (3) semântica do rejeite:
// nada executa, eval/Function lançam capturável, módulo falha.

import "core:testing"
import "core:strings"

// Roda `src` num vm novo e devolve a mensagem do SyntaxError de PARSE (rejected =
// o fonte foi recusado antes de executar). Usado também por outros testes.
early_error_of :: proc(src: string) -> (msg: string, rejected: bool) {
    vm := vm_create()
    defer vm_free(vm)
    _ = vm_exec(vm, src)
    if vm.syntax_errors == 0 || !vm.throwing do return "", false
    m := get_member(vm, vm.thrown, "message")
    vm.throwing = false
    vm.thrown = nil
    if s, ok := m.(string); ok do msg = strings.clone(s, context.temp_allocator)
    return msg, true
}

@(private = "file")
Bad_Case :: struct { src, msg: string }

@(test)
test_early_errors_mensagens :: proc(t: ^testing.T) {
    cases := []Bad_Case{
        {"var = ;", "Unexpected token '='"},
        {"(", "Unexpected end of input"},
        {"a b", "Unexpected identifier 'b'"},
        {"var a = 1 2;", "Unexpected number"},
        {"let a; let a;", "Identifier 'a' has already been declared"},
        {"let a; { var a; }", "Identifier 'a' has already been declared"},
        {"function f(a){ let a }", "Identifier 'a' has already been declared"},
        {"try {} catch (e) { let e }", "Identifier 'e' has already been declared"},
        {"let let = 1;", "let is disallowed as a lexically bound name"},
        {"const a;", "Missing initializer in const declaration"},
        {"let [a];", "Missing initializer in destructuring declaration"},
        {"break;", "Illegal break statement"},
        {"continue;", "Illegal continue statement: no surrounding iteration statement"},
        {"return 1;", "Illegal return statement"},
        {"break foo;", "Undefined label 'foo'"},
        {"x: x: 1;", "Label 'x' has already been declared"},
        {"a: { for(;;) continue a; }", "Illegal continue statement: 'a' does not denote an iteration statement"},
        {"1 = 2;", "Invalid left-hand side in assignment"},
        {"a?.b = 1;", "Invalid left-hand side in assignment"},
        {"++1;", "Invalid left-hand side expression in prefix operation"},
        {"f()++;", "Invalid left-hand side expression in postfix operation"},
        {"new a?.b();", "Invalid optional chain from new expression"},
        {"a?.b`x`;", "Invalid tagged template on optional chain"},
        {"-2 ** 2;", "Unary operator used immediately before exponentiation expression. Parenthesis must be used to disambiguate operator precedence"},
        {"a || b ?? c;", "Unexpected token '??'"},
        {"a ?? b && c;", "Unexpected token '&&'"},
        {"throw\n1;", "Illegal newline after throw"},
        {"try {}", "Missing catch or finally after try"},
        {"switch (1) { default: default: }", "More than one default clause in switch statement"},
        {"if (1) let x = 1;", "Lexical declaration cannot appear in a single-statement context"},
        {"while (1) function f(){}", "In non-strict mode code, functions can only be declared at top level, inside a block, or as the body of an if statement."},
        {"'use strict'; if (1) function f(){}", "In strict mode code, functions can only be declared at top level or inside a block."},
        {"function f(a, a){ 'use strict' }", "Duplicate parameter name not allowed in this context"},
        {"(a, a) => 1", "Duplicate parameter name not allowed in this context"},
        {"function f(a = 1){ 'use strict' }", "Illegal 'use strict' directive in function with non-simple parameter list"},
        {"function f(...a, b){}", "Rest parameter must be last formal parameter"},
        {"'use strict'; with ({}) {}", "Strict mode code may not include a with statement"},
        {"'use strict'; var x = 010;", "Octal literals are not allowed in strict mode."},
        {"'use strict'; var x = 09;", "Decimals with leading zeros are not allowed in strict mode."},
        {"'use strict'; var s = '\\101';", "Octal escape sequences are not allowed in strict mode."},
        {"'\\01'; 'use strict';", "Octal escape sequences are not allowed in strict mode."},
        {"'use strict'; delete x;", "Delete of an unqualified identifier in strict mode."},
        {"'use strict'; var eval;", "Unexpected eval or arguments in strict mode"},
        {"'use strict'; arguments = 1;", "Unexpected eval or arguments in strict mode"},
        {"'use strict'; var implements;", "Unexpected strict mode reserved word"},
        {"function f(){ 'use strict'; var static; }", "Unexpected strict mode reserved word"},
        {"class A { m(){ var let; } }", "Unexpected strict mode reserved word"},
        {"class A { constructor(){} constructor(){} }", "A class may only have one constructor"},
        {"class A { get constructor(){} }", "Class constructor may not be an accessor"},
        {"class A { *constructor(){} }", "Class constructor may not be a generator"},
        {"class A { constructor = 1 }", "Classes may not have a field named 'constructor'"},
        {"class A { static prototype(){} }", "Classes may not have a static property named 'prototype'"},
        {"class A { #x; #x; }", "Identifier '#x' has already been declared"},
        {"class A { m(){ this.#y } }", "Private field '#y' must be declared in an enclosing class"},
        {"class A { #x; m(){ delete this.#x } }", "Private fields can not be deleted"},
        {"class A { m(){ super() } }", "'super' keyword unexpected here"},
        {"function f(){ super.x }", "'super' keyword unexpected here"},
        {"class A { x = arguments }", "'arguments' is not allowed in class field initializer or static initialization block"},
        {"new.target", "new.target expression is not allowed here"},
        {"({ get a(x){} })", "Getter must not have any formal parameters."},
        {"({ set a(){} })", "Setter must have exactly one formal parameter."},
        {"({ __proto__: 1, __proto__: 2 })", "Duplicate __proto__ fields are not allowed in object literals"},
        {"({ a = 1 })", "Invalid shorthand property initializer"},
        {"function* g(){ function* h(a = yield){} }", "Yield expression not allowed in formal parameter"},
        {"async function f(){ var await; }", "Unexpected reserved word"},
        {"function f(){ await 1 }", "Unexpected number"},
        {"for (let x of [], []);", "Unexpected token ','"},
        {"for (const x = 1 in {});", "for-in loop variable declaration may not have an initializer."},
        {"for (async of []);", "The left-hand side of a for-of loop may not be 'async'."},
        {"/a/gg", "Invalid regular expression flags"},
        {"/(/", "Invalid regular expression: /(/: Unterminated group"},
        {"/a)/", "Invalid regular expression: /a)/: Unmatched ')'"},
        {"/*a/", "Invalid or unexpected token"},
        {"/+a/", "Invalid regular expression: /+a/: Nothing to repeat"},
        {"0b2", "Invalid or unexpected token"},
        {"3in []", "Invalid or unexpected token"},
        {"1.5n", "Invalid or unexpected token"},
        {"'abc", "Invalid or unexpected token"},
        {"`abc", "Unterminated template literal"},
        {"`\\x`", "Invalid escape sequence in template"},
        {"/* sem fim", "Invalid or unexpected token"},
        {"a => {} ()", "Unexpected token '('"},
        {"\\u0069f (1) {}", "Keyword must not contain escaped characters"},
        {"import.meta", "Cannot use 'import.meta' outside a module"},
        {"function f(){ import x from 'y' }", "Cannot use import statement outside a module"},
    }
    for c in cases {
        msg, rejected := early_error_of(c.src)
        testing.expectf(t, rejected, "devia ser SyntaxError: %q", c.src)
        testing.expectf(t, msg == c.msg, "%q: mensagem %q, esperado %q", c.src, msg, c.msg)
    }
}

// Cada caso aqui foi REJEITADO por engano numa versão intermediária (Test262 ou
// bundle real). Não pode voltar a ser SyntaxError.
@(test)
test_early_errors_validos_aceitos :: proc(t: ^testing.T) {
    valid := []string{
        "var o = {valueOf: function(){ return 4 }}; var r = {valueOf: function(){ return 4 }} / 2;", // `}` de objeto + `/` = divisão
        "var instance = 8, of = 2, g = 2; var r = instance/of/g;",     // `of` é identificador
        "if (1) {}\n/re/.test('re');",                                // `}` de bloco + `/` = regex
        "var x = 1; // fim\u2028x = 2;",                               // U+2028 encerra o comentário
        "#!/usr/bin/env node\nvar a = 1;",                            // hashbang
        "\uFEFFvar a = 1;",                                           // BOM no início
        "var\u00A0a = 1;",                                            // NBSP entre tokens
        "<!-- comentário html\nvar a = 1;\n--> outro\n",               // Annex B
        "for (var x in null) let\n{}",                                // `let` + ASI
        "if (0) let\nvar y = 1;",
        "class C { x = () => { arguments: for(;;) break arguments; } }", // label `arguments`
        "'use strict'; var r = delete this;",
        "var t = [], k = 'a', s = {}; [ {}[k], s.x ] = [1, 2];",       // alvo de atribuição genérico
        "function f(){ return {} } var o = {}; [f().y, o['z']] = [1, 2];",
        "class C { \\u0067et\n a = 1 }",                              // `get` escapado é nome de campo
        "var o = { \\u0069f: 1 }; o.\\u0069f;",                        // reservada escapada como NOME
        "var undefined = 1; undefined = 2;",
        "var let = 1; let = 2; var yield = 3, await = 4, async = 5, of = 6, get = 7, set = 8, static = 9;",
        "async function f(){ for await (const x of []) ; }",
        "label: function f(){}",                                      // Annex B (sloppy)
        "{ function f(){} function f(){} }",                          // Annex B (sloppy)
        "try {} catch (e) { var e = 1 }",                             // Annex B
        "function f(a, a){}",                                         // sloppy, params simples
        "var r = /[/]/.source + /a\\/b/g.flags;",
        "var x = 010 === 8 && '\\101' === 'A' && 08 === 8;",          // octal legado (sloppy)
        "var o = { async: 1, get: 2, set: 3, static: 4, await: 5, of: 6 };",
        "class A { static async *g(){} static get [Symbol.iterator](){} #p = 1; static #q(){} m(){ return #p in this } }",
        "var f = async x => x, g = async (a, b) => a, h = async function(){};",
        "x = 1\n;(function(){})()",
        "var a = 1, b = 2\n++b",
        "do ; while (0) var z = 1",                                   // `;` depois de do-while é opcional
        "var re = /(?<ano>\\d{4})-(?:x|y)*?(?=a)?/u;",
        "var n = 0x1_0 + 1_000 + .5e-3 + 0o17 + 0b1;",
        "function f(){ return new.target } class B { x = new.target; static { this.y = new.target } }",
        "class A extends Object { constructor(){ super(); () => super.toString } }",
        "var o = { m(){ return super.toString } };",
        "a: b: while (0) continue a;",
        "switch (1) { case 1: let q = 1; break; default: }",
        "var s = `a${1}b${`c${2}`}`;",
        "eval('1'); Function('return 1');",
    }
    for src in valid {
        msg, rejected := early_error_of(src)
        testing.expectf(t, !rejected, "VÁLIDO rejeitado: %q -> %s", src, msg)
    }
}

@(test)
test_early_error_nada_executa :: proc(t: ^testing.T) {
    // o erro está no FIM; o `var ran = 1` do começo não pode ter rodado
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var ran = 1;\nbreak;")
    testing.expect_value(t, vm.syntax_errors, 1)
    v := vm_run(vm, "typeof ran")
    testing.expect_value(t, v.(string), "undefined")
}

@(test)
test_early_error_eval_e_function_lancam :: proc(t: ^testing.T) {
    // eval/Function: SyntaxError CAPTURÁVEL (feature-detect por try/eval), e o
    // que vem depois do try segue rodando
    v := run(`
        var r = [];
        try { eval("a b"); r.push("no") } catch (e) { r.push(e instanceof SyntaxError, e.message) }
        try { new Function("return 1 2"); r.push("no") } catch (e) { r.push(e instanceof SyntaxError) }
        try { eval("return 1") } catch (e) { r.push(e.name) }
        r.push(eval("1 + 1"));
        r.join("|")`)
    testing.expect_value(t, v.(string), "true|Unexpected identifier 'b'|true|SyntaxError|2")
}
