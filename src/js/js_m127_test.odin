package js

// M127 — a campanha do npmjs.com BLANK. A raiz final foi de SEMÂNTICA BÁSICA:
// uma chamada plana `f()` herdava o `this` de quem chamou em vez de cair no objeto
// global. O webpack invoca cada módulo com `this = module.exports`, então o shim de
// global (`g = (function(){ return this })()`) capturava o exports; depois o código
// fazia `g.location.pathname` e morria dentro do React, que capturava a exceção no
// error boundary e DESMONTAVA a árvore — página em branco, sem erro visível.
//
// No caminho até lá caíram outros 4 gaps reais da mesma família ("o lado construtor
// da cadeia de protótipos"), todos exercitados aqui.

import "core:testing"

// ── 1) `this` de chamada plana = objeto global, não o do chamador ──────────────

@(test)
m127_this_de_chamada_plana_nao_vaza_do_chamador :: proc(t: ^testing.T) {
    // Sem DOM não há window: o `this` global do --js262 é undefined, mas o que
    // importa é que NÃO seja o receptor de quem chamou.
    src := `
        var vazou = "nao-rodou";
        var receptor = { marca: 1, m: function(){ return (function(){ return this })(); } };
        var r = receptor.m();
        vazou = (r === receptor) ? "VAZOU" : "ok";
        vazou
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m127_this_de_chamada_plana_com_call_explicito :: proc(t: ^testing.T) {
    // Exatamente o shim do webpack: o módulo é chamado com .call(exports).
    src := `
        var exports = { e: 1 };
        function modulo(){ return (function(){ return this })(); }
        modulo.call(exports) === exports ? "VAZOU" : "ok"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m127_arrow_ainda_herda_this_lexicalmente :: proc(t: ^testing.T) {
    // Não-regressão: a correção acima NÃO pode afetar arrow functions, que por
    // spec herdam o `this` léxico.
    src := `
        var obj = { v: 42, m: function(){ return (() => this.v)(); } };
        obj.m()
    `
    testing.expect_value(t, run(src).(f64), 42)
}

@(test)
m127_metodo_ainda_recebe_seu_receptor :: proc(t: ^testing.T) {
    src := `
        var obj = { v: 7, m: function(){ return this.v } };
        obj.m()
    `
    testing.expect_value(t, run(src).(f64), 7)
}

// ── 2) construtor Function compila de verdade ─────────────────────────────────

@(test)
m127_function_ctor_compila_corpo :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Function("a", "b", "return a + b")(2, 3)`).(f64), 5)
}

@(test)
m127_function_ctor_sem_new_e_sem_params :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Function("return 41 + 1")()`).(f64), 42)
}

@(test)
m127_function_ctor_escopo_e_global_nao_lexico :: proc(t: ^testing.T) {
    // Spec: o corpo NÃO enxerga o léxico de quem criou a função.
    src := `
        var achou = "?";
        (function(){
            var local = "invisivel";
            try { Function("return typeof local")() === "undefined" ? (achou="ok") : (achou="VAZOU"); }
            catch (e) { achou = "throw"; }
        })();
        achou
    `
    testing.expect_value(t, run(src).(string), "ok")
}

// ── 3) Boolean: prototype + métodos ───────────────────────────────────────────

@(test)
m127_boolean_prototype_existe :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof Boolean.prototype`).(string), "object")
    testing.expect_value(t, run(`typeof Boolean.prototype.valueOf`).(string), "function")
}

@(test)
m127_boolean_metodos_no_primitivo :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`true.toString()`).(string), "true")
    testing.expect_value(t, run(`false.toString()`).(string), "false")
    testing.expect_value(t, run(`true.valueOf()`).(bool), true)
}

@(test)
m127_boolean_valueof_uncurried :: proc(t: ^testing.T) {
    // O padrão exato do helper _createSuper do Babel.
    testing.expect_value(t, run(`Boolean.prototype.valueOf.call(true)`).(bool), true)
}

// ── 4) getPrototypeOf do lado CONSTRUTOR ──────────────────────────────────────

@(test)
m127_getprototypeof_de_classe_derivada_e_a_super :: proc(t: ^testing.T) {
    src := `
        class A {}
        class B extends A {}
        Object.getPrototypeOf(B) === A
    `
    testing.expect_value(t, run(src).(bool), true)
}

@(test)
m127_getprototypeof_de_funcao_e_function_prototype :: proc(t: ^testing.T) {
    src := `
        function F(){}
        Object.getPrototypeOf(F) === Function.prototype
    `
    testing.expect_value(t, run(src).(bool), true)
}

@(test)
m127_createsuper_do_babel_ponta_a_ponta :: proc(t: ^testing.T) {
    // O helper real, reduzido: detecta Reflect.construct nativo e sobe a cadeia.
    src := `
        function _getPrototypeOf(o){ return Object.getPrototypeOf(o) }
        function _isNativeReflectConstruct(){
            try {
                Boolean.prototype.valueOf.call(Reflect.construct(Boolean, [], function(){}));
                return true;
            } catch (e) { return false; }
        }
        class Base { constructor(){ this.tag = "base" } }
        class Sub extends Base {}
        var Super = _getPrototypeOf(Sub);
        var nativo = _isNativeReflectConstruct();
        (Super === Base && nativo) ? "ok" : ("Super=" + (Super === Base) + " nativo=" + nativo)
    `
    testing.expect_value(t, run(src).(string), "ok")
}

// ── 5) herança de membros ESTÁTICOS ───────────────────────────────────────────

@(test)
m127_heranca_estatica_metodo :: proc(t: ^testing.T) {
    src := `
        class A { static criar(){ return "de-A" } }
        class B extends A {}
        B.criar()
    `
    testing.expect_value(t, run(src).(string), "de-A")
}

@(test)
m127_heranca_estatica_atravessa_dois_niveis :: proc(t: ^testing.T) {
    src := `
        class A { static qual(){ return "A" } }
        class B extends A {}
        class C extends B {}
        C.qual()
    `
    testing.expect_value(t, run(src).(string), "A")
}

@(test)
m127_estatico_proprio_vence_o_herdado :: proc(t: ^testing.T) {
    src := `
        class A { static qual(){ return "A" } }
        class B extends A { static qual(){ return "B" } }
        B.qual()
    `
    testing.expect_value(t, run(src).(string), "B")
}

@(test)
m127_heranca_estatica_nao_rouba_o_prototype :: proc(t: ^testing.T) {
    // `prototype` é de CADA função: herdar o da super quebraria `new B()`.
    src := `
        class A {}
        class B extends A {}
        B.prototype === A.prototype ? "ROUBOU" : "ok"
    `
    testing.expect_value(t, run(src).(string), "ok")
}
