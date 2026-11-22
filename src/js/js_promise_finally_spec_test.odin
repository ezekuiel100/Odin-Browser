package js

// Promise.prototype.finally pela spec (27.2.5.3): tudo que é Invoke(_, "then") passa
// pelo `then` que o objeto TIVER (inclusive um Promise.prototype.then sobrescrito), e
// as funções que ele cria — e as resolving functions — são anônimas e não construtoras.

import "core:testing"

@(test)
finally_invoca_o_then_observavel :: proc(t: ^testing.T) {
    src := `
        var log = [];
        var then = Promise.prototype.then;
        Promise.prototype.then = function (a, b) {
            log.push(arguments.length + ":" + (typeof a === "function" ? a.length + a.name : typeof a));
            return then.apply(this, arguments);
        };
        Promise.resolve(1).finally(function () {});
        log.join(" ")
    `
    // a 1ª chamada é a do próprio finally: thenFinally/catchFinally, length 1, anônimas
    testing.expect_value(t, run(src).(string), "2:1")
    // finally sobre um thenable que não é Promise: Invoke(this, "then")
    testing.expect_value(t, run(`var got; var th = { then(a, b) { got = [typeof a, typeof b, a.length]; return 7 } }; var r = Promise.prototype.finally.call(th, function () {}); got.join() + "|" + r`).(string), "function,function,1|7")
    testing.expect_value(t, run(`var got; var th = { then(a, b) { got = [a, b]; return 1 } }; Promise.prototype.finally.call(th, 5); got.join()`).(string), "5,5")
    testing.expect_value(t, run(`var r = "nao lancou"; try { Promise.prototype.finally.call(1) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
}

@(test)
resolving_functions_nao_construtoras :: proc(t: ^testing.T) {
    src := `
        var res, rej;
        new Promise(function (a, b) { res = a; rej = b });
        var r = [res.length, rej.length, res.name === "", rej.name === ""];
        try { new res(); r.push("construiu") } catch (e) { r.push(e instanceof TypeError) }
        r.join()
    `
    testing.expect_value(t, run(src).(string), "1,1,true,true,true")
}

@(test)
finally_resultado_continua_igual :: proc(t: ^testing.T) {
    src := `
        var out = [];
        Promise.resolve(1).finally(function () { out.push("f1") }).then(function (v) { out.push("v" + v) });
        Promise.reject(2).finally(function () { out.push("f2") }).then(null, function (e) { out.push("e" + e) });
        Promise.resolve(3).finally(function () { throw 9 }).then(null, function (e) { out.push("t" + e) });
    `
    testing.expect_value(t, run_settled(src, `out.sort().join()`).(string), "e2,f1,f2,t9,v1")
}
