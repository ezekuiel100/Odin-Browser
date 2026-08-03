package js

// M176 — faltavam os DOIS últimos construtores de erro da spec: `EvalError` e
// `AggregateError`. Achado ao re-medir os sites BLANK: o bandcamp cuspia
// `ReferenceError: EvalError is not defined` EM LAÇO. `EvalError` quase não é
// lançado hoje (o `eval` moderno não o usa), mas é REFERENCIADO por polyfill e
// bundle que varrem os construtores nativos p/ montar tabelas.
//
// `AggregateError` é o erro de `Promise.any` — e ali o objeto já era montado à
// mão, SEM protótipo: `e instanceof AggregateError` nem chegava a ser falso,
// lançava ReferenceError porque o global não existia.

import "core:testing"

@(test)
m176_eval_error_existe :: proc(t: ^testing.T) {
    // o sintoma exato do bandcamp: só REFERENCIAR o construtor lançava
    testing.expect_value(t, run(`typeof EvalError`).(string), "function")
    testing.expect_value(t, run(`
        var e = new EvalError('x');
        (e instanceof EvalError) && (e instanceof Error) && !(e instanceof TypeError)
    `).(bool), true)
    testing.expect_value(t, run(`new EvalError('x').name`).(string), "EvalError")
    testing.expect_value(t, run(`String(new EvalError('boom'))`).(string), "EvalError: boom")
    // sem `new` também constrói (como os demais erros deste motor)
    testing.expect_value(t, run(`EvalError('y').message`).(string), "y")
}

@(test)
m176_aggregate_error_existe :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof AggregateError`).(string), "function")
    // ⚠️ assinatura DIFERENTE: (errors, message) — a mensagem é o 2o argumento
    testing.expect_value(t, run(`new AggregateError([1,2], 'falhou').message`).(string), "falhou")
    testing.expect_value(t, run(`new AggregateError([1,2], 'falhou').errors.length`).(f64), f64(2))
    testing.expect_value(t, run(`
        var e = new AggregateError([], 'x');
        (e instanceof AggregateError) && (e instanceof Error)
    `).(bool), true)
    // a lista de erros NÃO pode virar a mensagem (era o risco de reusar o ctor comum)
    testing.expect_value(t, run(`new AggregateError(['a']).message`).(string), "")
}

// O AggregateError que o `Promise.any` monta por dentro tem de ser o MESMO tipo
// que o construtor global — antes ele saía sem protótipo nenhum.
@(test)
m176_promise_any_rejeita_com_aggregate_de_verdade :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        Promise.any([Promise.reject(1), Promise.reject(2)]).catch(function(e){
            r = (e instanceof AggregateError) + '/' + (e instanceof Error) + '/' + e.errors.length;
        });
        r
    `).(string), "true/true/2")
}

// guarda: os construtores que já existiam seguem intactos e distintos entre si
@(test)
m176_familia_de_erros_intacta :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        [typeof Error, typeof TypeError, typeof RangeError, typeof SyntaxError,
         typeof ReferenceError, typeof URIError, typeof EvalError, typeof AggregateError]
            .every(function(x){ return x === 'function' })
    `).(bool), true)
    testing.expect_value(t, run(`
        var e = new EvalError('x');
        (e instanceof RangeError) || (e instanceof URIError)
    `).(bool), false)
}
