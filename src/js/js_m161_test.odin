package js

// M161 — `const` imutável + Symbol.hasInstance / Symbol.toStringTag.
//
// Itens 5 e 6 da auditoria do M159.
//
//   (5) `const c = 1; c = 2` passava CALADO. Um bug que o browser real rejeita
//       corrompia estado aqui em silêncio — a pior classe, porque não deixa
//       rastro. Agora `Env.consts` marca os bindings declarados com const (mapa
//       à parte, nil em escopo sem const, para não tocar o caminho quente de
//       leitura) e `env_assign` lança TypeError ao acertar um deles.
//
//   (6) Os símbolos `Symbol.hasInstance` e `Symbol.toStringTag` já existiam e
//       eram distintos, mas NINGUÉM os consultava: `instanceof` ignorava o
//       primeiro e `Object.prototype.toString` o segundo. Ambos agora são lidos
//       pela chave-string guardada no vm (mesmo mecanismo do Symbol.toPrimitive).
//
// O grosso dos testes abaixo é do que NÃO pode lançar: `const` tem um punhado de
// casos legítimos de rebind (por iteração de laço, sombreamento em escopo interno,
// mutação do objeto apontado) e confundir um deles com reatribuição quebraria
// código real de forma espetacular.

import "core:strings"
import "core:testing"

// ── (5) const ────────────────────────────────────────────────────────────────

// Roda `corpo` e devolve o `.name` da exceção, ou "sem erro". NÃO usa o valor de
// conclusão do try/catch (que o nosso eval não produz) — o resultado sai por uma
// variável, senão o teste mede a coisa errada.
// ⚠️ NÃO montar este fonte com fmt.tprintf: o `{`/`}` do JS é lido como sintaxe de
// formatação do Odin e o resultado sai com "MISSING" no meio do código. O parser
// engole (é tolerante), o check_parse_recoveries entra em panic — e panic dentro de
// um teste TRAVA a suíte multi-thread inteira. Concatenação simples resolve.
@(private = "file")
erro_de :: proc(corpo: string) -> string {
    src := strings.concatenate({
        "var __r = \"sem erro\"; try { ", corpo, " } catch (e) { __r = e.name } __r",
    }, context.temp_allocator)
    v := run(src)
    s, _ := v.(string)
    return s
}

@(test)
m161_const_reatribuido_lanca :: proc(t: ^testing.T) {
    testing.expect_value(t, erro_de(`const c = 1; c = 2`), "TypeError")
    testing.expect_value(t, erro_de(`const c = 1; c += 1`), "TypeError")
    testing.expect_value(t, erro_de(`const c = 1; c++`), "TypeError")
    testing.expect_value(t, erro_de(`const c = 1; --c`), "TypeError")
    testing.expect_value(t, erro_de(`const {a} = {a:1}; a = 2`), "TypeError")
    testing.expect_value(t, erro_de(`const [x] = [1]; x = 2`), "TypeError")
    // de dentro de uma função, subindo a cadeia até o escopo do const
    testing.expect_value(t, erro_de(`const c = 1; (function(){ c = 2 })()`), "TypeError")
    // e a mensagem é a que o browser usa
    msg := run(`var __m = ""; try { const c = 1; c = 2 } catch (e) { __m = e.message } __m`)
    testing.expect_value(t, msg.(string), "Assignment to constant variable.")
}

@(test)
m161_let_e_var_seguem_reatribuiveis :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`let a = 1; a = 2; a`)), f64(2))
    testing.expect_value(t, as_number(run(`var b = 1; b = 2; b`)), f64(2))
    testing.expect_value(t, as_number(run(`let c = 1; c += 5; c`)), f64(6))
    testing.expect_value(t, as_number(run(`var d = 1; d++; d`)), f64(2))
    testing.expect_value(t, as_number(run(`let {e} = {e:1}; e = 9; e`)), f64(9))
    testing.expect_value(t, as_number(run(`semDeclaracao = 7; semDeclaracao`)), f64(7)) // global implícito
}

@(test)
m161_const_permite_mutar_o_valor_apontado :: proc(t: ^testing.T) {
    // O binding é imutável, o OBJETO não. Confundir os dois quebraria tudo.
    testing.expect_value(t, as_number(run(`const o = {a:1}; o.a = 2; o.a`)), f64(2))
    testing.expect_value(t, as_number(run(`const arr = [1]; arr.push(2); arr.length`)), f64(2))
    testing.expect_value(t, as_number(run(`const arr = [1]; arr[0] = 9; arr[0]`)), f64(9))
    testing.expect_value(t, as_number(run(`const m = new Map(); m.set("k", 3); m.get("k")`)), f64(3))
}

@(test)
m161_const_rebinda_por_iteracao_de_laco :: proc(t: ^testing.T) {
    // `for (const x of ...)` cria um binding NOVO por iteração — não é
    // reatribuição. Se isto lançasse, qualquer laço moderno morreria.
    testing.expect_value(t, as_number(run(`var s = 0; for (const x of [1,2,3]) s += x; s`)), f64(6))
    testing.expect_value(t, as_number(run(`var s = 0; for (const k in {a:1,b:2}) s += 1; s`)), f64(2))
    testing.expect_value(t, as_number(run(`var s = 0; for (const [a,b] of [[1,2],[3,4]]) s += a*b; s`)), f64(14))
    // e reatribuir DENTRO do corpo continua sendo erro
    testing.expect_value(t, erro_de(`for (const x of [1]) { x = 9 }`), "TypeError")
}

@(test)
m161_const_por_escopo_nao_vaza :: proc(t: ^testing.T) {
    // A marca é POR ESCOPO: um `const x` interno não congela o `let x` externo,
    // e uma função chamada muitas vezes redeclara o seu const a cada chamada.
    testing.expect_value(t, as_number(run(`let x = 1; { const x = 2; } x = 5; x`)), f64(5))
    testing.expect_value(t, as_number(run(`function f(){ const y = 1; return y } f(); f(); f()`)), f64(1))
    testing.expect_value(t, as_number(run(`function f(n){ const y = n * 2; return y } f(1) + f(2)`)), f64(6))
    // param homônimo de um const externo continua atribuível
    testing.expect_value(t, as_number(run(`const p = 1; function f(p){ p = 9; return p } f(0)`)), f64(9))
}

@(test)
m161_const_sobrevive_a_reciclagem_de_escopo :: proc(t: ^testing.T) {
    // O mapa `consts` mora no Env, que o M159 devolve a um POOL. Se ele não fosse
    // limpo no recycle, um escopo reusado herdaria consts de outra chamada e
    // passaria a lançar em variável comum. Milhares de chamadas forçam o reuso.
    src := `
        function comConst(n){ const c = n + 1; return c }
        function semConst(n){ var v = n; v = v + 1; return v }
        var s = 0;
        for (var i = 0; i < 3000; i++) { s = comConst(s); s = semConst(s); }
        s;
    `
    testing.expect_value(t, as_number(run(src)), f64(6000))
}

// ── (6) Symbol.hasInstance ───────────────────────────────────────────────────

@(test)
m161_has_instance_customiza_instanceof :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var C = { [Symbol.hasInstance]: function(){ return true } }; ({}) instanceof C`).(bool), true)
    testing.expect_value(t, run(`var C = { [Symbol.hasInstance]: function(){ return false } }; ({}) instanceof C`).(bool), false)
    // recebe o operando esquerdo
    testing.expect_value(t, run(`var Par = { [Symbol.hasInstance]: function(n){ return n % 2 === 0 } }; 4 instanceof Par`).(bool), true)
    testing.expect_value(t, run(`var Par = { [Symbol.hasInstance]: function(n){ return n % 2 === 0 } }; 3 instanceof Par`).(bool), false)
    // o retorno passa por ToBoolean, não precisa ser bool
    testing.expect_value(t, run(`var C = { [Symbol.hasInstance]: function(){ return 1 } }; ({}) instanceof C`).(bool), true)
    testing.expect_value(t, run(`var C = { [Symbol.hasInstance]: function(){ return "" } }; ({}) instanceof C`).(bool), false)
}

@(test)
m161_has_instance_em_classe_static :: proc(t: ^testing.T) {
    src := `
        class Colecao {
            static [Symbol.hasInstance](x) { return Array.isArray(x) }
        }
        ([] instanceof Colecao) && !(({}) instanceof Colecao)
    `
    testing.expect_value(t, run(src).(bool), true)
}

@(test)
m161_instanceof_normal_nao_mudou :: proc(t: ^testing.T) {
    // Sem o símbolo, o caminho antigo (cadeia de prototype) tem de valer igual.
    testing.expect_value(t, run(`function F(){}; (new F()) instanceof F`).(bool), true)
    testing.expect_value(t, run(`function F(){}; function G(){}; (new F()) instanceof G`).(bool), false)
    testing.expect_value(t, run(`class A {}; class B extends A {}; (new B()) instanceof A`).(bool), true)
    testing.expect_value(t, run(`[] instanceof Array`).(bool), true)
    testing.expect_value(t, run(`(new Map()) instanceof Map`).(bool), true)
    testing.expect_value(t, run(`(new Error("x")) instanceof Error`).(bool), true)
    testing.expect_value(t, run(`1 instanceof Object`).(bool), false)
    testing.expect_value(t, run(`({}) instanceof 5`).(bool), false) // não-objeto à direita: false, sem crash
}

// ── (6) Symbol.toStringTag ───────────────────────────────────────────────────

@(test)
m161_tostring_tag_em_literal_e_classe :: proc(t: ^testing.T) {
    str :: proc(src: string) -> string {
        v := run(src)
        s, _ := v.(string)
        return s
    }
    testing.expect_value(t, str(`Object.prototype.toString.call({ [Symbol.toStringTag]: "Foo" })`), "[object Foo]")
    // herdada do prototype (idioma de classe) e via getter
    testing.expect_value(t, str(`class C { get [Symbol.toStringTag]() { return "C" } } Object.prototype.toString.call(new C())`), "[object C]")
    // String(obj) também passa pelo toString herdado
    testing.expect_value(t, str(`String({ [Symbol.toStringTag]: "Bar" })`), "[object Bar]")
    // tag não-string é ignorada (spec): cai no default
    testing.expect_value(t, str(`Object.prototype.toString.call({ [Symbol.toStringTag]: 42 })`), "[object Object]")
}

@(test)
m161_tostring_sem_tag_nao_mudou :: proc(t: ^testing.T) {
    str :: proc(src: string) -> string {
        v := run(src)
        s, _ := v.(string)
        return s
    }
    testing.expect_value(t, str(`Object.prototype.toString.call({})`), "[object Object]")
    testing.expect_value(t, str(`Object.prototype.toString.call([])`), "[object Array]")
    testing.expect_value(t, str(`Object.prototype.toString.call(null)`), "[object Null]")
    testing.expect_value(t, str(`Object.prototype.toString.call(undefined)`), "[object Undefined]")
    testing.expect_value(t, str(`Object.prototype.toString.call(1)`), "[object Number]")
    testing.expect_value(t, str(`Object.prototype.toString.call("s")`), "[object String]")
    testing.expect_value(t, str(`Object.prototype.toString.call(function(){})`), "[object Function]")
    // o [[Class]] interno (#class) continua valendo para Math/JSON
    testing.expect_value(t, str(`Object.prototype.toString.call(Math)`), "[object Math]")
}
