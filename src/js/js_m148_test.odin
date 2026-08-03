package js

// M148 — `throw <expr>` DESTRUÍA o erro quando a própria expressão lançava.
//
// O eval de .Throw fazia `vm.thrown = nil` ANTES de avaliar a expressão e depois
// atribuía o retorno. Se a expressão lançasse (`throw new Foo()` com Foo
// indefinido, `throw f()` que estoura, `throw o.x` com o null), o eval já tinha
// preenchido vm.thrown com o erro REAL — e a atribuição do retorno (nil) apagava
// tudo. O catch recebia `undefined`.
//
// Não era só relatório feio: a SEMÂNTICA ficava errada (o handler não vê o erro).
// No gap-miner era o cluster `(lançou undefined)` em 5 sites — airbnb,
// stackoverflow, ebay, figma, theguardian —, cada um escondendo o erro de verdade.
//
// ⚠️ Nota de ESCRITA de teste: `run()` NÃO devolve o valor de conclusão de um
// try/catch (devolve nil), e `.(string)` sobre nil é PÂNICO que derruba o
// processo de teste inteiro. Por isso todo caso aqui guarda o resultado numa
// variável e termina COM ELA.

import "core:testing"

@(test)
m148_throw_de_construtor_inexistente :: proc(t: ^testing.T) {
    // o catch tem de receber o erro da CONSTRUÇÃO, não undefined.
    // (Era TypeError até o M150; virou ReferenceError quando o identificador
    // livre inexistente passou a lançar — o que importa aqui segue igual: o
    // erro REAL chega ao catch em vez de ser apagado por `throw`.)
    src := `
        var r = "?";
        try { throw new NaoExisteEsteConstrutor("x") }
        catch (e) { r = (e === undefined) ? "PERDEU" : e.name }
        r
    `
    testing.expect_value(t, run(src).(string), "ReferenceError")
}

@(test)
m148_throw_de_chamada_que_estoura :: proc(t: ^testing.T) {
    // (`naoDefinida` é nome livre: desde o M150 quem lança é o ReferenceError da
    // BASE, antes do acesso à prop. O que o teste guarda continua sendo o mesmo:
    // o erro nascido DENTRO da expressão do throw chega inteiro ao catch.)
    src := `
        var r = "?";
        function f() { return naoDefinida.prop }
        try { throw f() }
        catch (e) { r = (e === undefined) ? "PERDEU" : e.name }
        r
    `
    testing.expect_value(t, run(src).(string), "ReferenceError")
}

@(test)
m148_throw_de_membro_de_null :: proc(t: ^testing.T) {
    src := `
        var r = "?", o = null;
        try { throw o.qualquer }
        catch (e) { r = (e === undefined) ? "PERDEU" : e.name }
        r
    `
    testing.expect_value(t, run(src).(string), "TypeError")
}

@(test)
m148_mensagem_do_erro_real_preservada :: proc(t: ^testing.T) {
    // não basta o tipo: a MENSAGEM do erro real é o que torna o peel possível.
    src := `
        var r = "?", o = null;
        try { throw o.qualquer }
        catch (e) { r = (e.message.indexOf("null") >= 0) ? "tem-null" : e.message }
        r
    `
    testing.expect_value(t, run(src).(string), "tem-null")
}

@(test)
m148_throw_normal_intacto :: proc(t: ^testing.T) {
    // CONTRA-CASO 1: o caminho comum não pode ter mudado.
    src := `
        var r = "?";
        try { throw new TypeError("mensagem boa") }
        catch (e) { r = e.name + ": " + e.message }
        r
    `
    testing.expect_value(t, run(src).(string), "TypeError: mensagem boa")
}

@(test)
m148_throw_undefined_continua_undefined :: proc(t: ^testing.T) {
    // CONTRA-CASO 2: `throw undefined` é LEGÍTIMO e tem de continuar entregando
    // undefined — o fix não pode ter inventado um erro onde não há.
    src := `
        var r = "?";
        try { throw undefined } catch (e) { r = (e === undefined) ? "undef" : "erro" }
        r
    `
    testing.expect_value(t, run(src).(string), "undef")
    src2 := `
        var r = "?";
        try { throw null } catch (e) { r = (e === null) ? "null" : "erro" }
        r
    `
    testing.expect_value(t, run(src2).(string), "null")
}

@(test)
m148_throw_de_valores_primitivos_intacto :: proc(t: ^testing.T) {
    // CONTRA-CASO 3: lançar primitivo (idioma comum em lib) segue igual.
    src := `
        var r = "?";
        try { throw "texto" } catch (e) { r = e }
        r
    `
    testing.expect_value(t, run(src).(string), "texto")
    src2 := `
        var r = 0;
        try { throw 42 } catch (e) { r = e }
        r
    `
    testing.expect_value(t, as_number(run(src2)), f64(42))
}

@(test)
m148_rethrow_preserva_o_erro :: proc(t: ^testing.T) {
    // `throw e` dentro de um catch (re-lançar) é o caso mais comum de todos.
    src := `
        var r = "?";
        function f() { try { null.x } catch (e) { throw e } }
        try { f() } catch (e2) { r = (e2 === undefined) ? "PERDEU" : e2.name }
        r
    `
    testing.expect_value(t, run(src).(string), "TypeError")
}
