package js

// M140 — REGRESSÃO caçada: npmjs.com voltou a BLANK depois do M136.
//
// A mineração pós-M139 acusou BLANK 5→7 com o npmjs de volta na lista (ele tinha
// sido corrigido no M127). Bissectei por flag de compilação: o gatilho foi honrar o
// `newTarget` do `Reflect.construct` (M136) — mas o CULPADO era outro, só estava
// escondido.
//
// Cadeia completa:
//   1. Honrar newTarget fez o feature-detect do Babel (`_isNativeReflectConstruct`,
//      que constrói `Boolean` com um newTarget) passar a dar TRUE.
//   2. Com isso o `_createSuper` trocou o caminho `Super.apply(this, args)` pelo
//      `Reflect.construct(Super, args, NewTarget)`.
//   3. E aí apareceu o bug antigo: **`Object.setPrototypeOf` era NO-OP quando o alvo
//      é uma FUNÇÃO**. O `_inherits` do Babel emite exatamente
//      `Object.setPrototypeOf(Filha, Pai)`, então `_getPrototypeOf(Derived)` devolvia
//      Function.prototype — um objeto comum — e o construct morria com "target is
//      not a constructor". O React captura no error boundary e desmonta a árvore:
//      página em branco, sem erro visível.
//
// Ou seja: o M136 não introduziu o defeito, só parou de contorná-lo.

import "core:testing"

// ── o elo que faltava: setPrototypeOf em função ──────────────────────────────

@(test)
m140_set_prototype_of_em_funcao :: proc(t: ^testing.T) {
    src := `
        function Pai(){} function Filha(){}
        Object.setPrototypeOf(Filha, Pai);
        (Object.getPrototypeOf(Filha) === Pai) + "|" + (typeof Object.getPrototypeOf(Filha))
    `
    testing.expect_value(t, run(src).(string), "true|function")
}

@(test)
m140_heranca_estatica_via_set_prototype_of :: proc(t: ^testing.T) {
    // Consequência do elo: membro estático do pai fica visível na filha, que é o
    // outro efeito que o `_inherits` do Babel espera.
    src := `
        function Pai(){} function Filha(){}
        Pai.estatico = 9;
        Object.setPrototypeOf(Filha, Pai);
        Filha.estatico
    `
    testing.expect_value(t, run(src).(f64), 9)
}

@(test)
m140_set_prototype_of_null_desliga :: proc(t: ^testing.T) {
    src := `
        function Pai(){} function Filha(){}
        Pai.estatico = 9;
        Object.setPrototypeOf(Filha, Pai);
        Object.setPrototypeOf(Filha, null);
        String(Filha.estatico)
    `
    testing.expect_value(t, run(src).(string), "undefined")
}

@(test)
m140_set_prototype_of_em_objeto_intacto :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o caminho de objeto (o único que existia) não mudou.
    src := `
        var base = { ola: function(){ return "oi" } };
        var o = {};
        Object.setPrototypeOf(o, base);
        o.ola() + "|" + (Object.getPrototypeOf(o) === base)
    `
    testing.expect_value(t, run(src).(string), "oi|true")
}

@(test)
m140_reflect_get_prototype_of_igual_ao_object :: proc(t: ^testing.T) {
    // Os dois divergiam: o Reflect só tratava ^Object e devolvia null p/ classe.
    src := `
        class A {} class B extends A {}
        function P(){} function F(){}
        Object.setPrototypeOf(F, P);
        (Reflect.getPrototypeOf(B) === A) + "|" + (Reflect.getPrototypeOf(F) === P)
    `
    testing.expect_value(t, run(src).(string), "true|true")
}

// ── o padrão do Babel, ponta a ponta ─────────────────────────────────────────

@(test)
m140_padrao_create_super_do_babel :: proc(t: ^testing.T) {
    // Reproduz `_inherits` + `_createSuper` como o Babel emite. Era isto que ficava
    // em branco no npmjs.
    src := `
        function Pai(nome){ this.nome = nome }
        Pai.prototype.ola = function(){ return "ola " + this.nome };
        function Filha(nome){
            var Super = Object.getPrototypeOf(Filha);
            var NewTarget = Object.getPrototypeOf(this).constructor;
            return Reflect.construct(Super, [nome], NewTarget);
        }
        Filha.prototype = Object.create(Pai.prototype);
        Filha.prototype.constructor = Filha;
        Object.setPrototypeOf(Filha, Pai);
        var f = new Filha("zé");
        f.ola() + "|" + (f instanceof Filha) + "|" + (f instanceof Pai)
    `
    testing.expect_value(t, run(src).(string), "ola zé|true|true")
}

// ── Reflect.construct passou a validar como a spec ───────────────────────────

@(test)
m140_construct_exige_lista_de_argumentos :: proc(t: ^testing.T) {
    // A spec exige um objeto como argumentsList. Aceitar undefined em silêncio não
    // era só frouxidão: o core-js DETECTA (`fails(function(){ Reflect.construct(fn) })`)
    // e, achando o nativo quebrado, instala o polyfill dele por cima.
    src := `
        var out = "sem erro";
        try { Reflect.construct(function(){}) } catch (e) { out = e instanceof TypeError ? "TypeError" : "outro" }
        out
    `
    testing.expect_value(t, run(src).(string), "TypeError")
}

@(test)
m140_construct_exige_new_target_construtor :: proc(t: ^testing.T) {
    src := `
        var out = "sem erro";
        try { Reflect.construct(function(){}, [], {}) } catch (e) { out = e instanceof TypeError ? "TypeError" : "outro" }
        out
    `
    testing.expect_value(t, run(src).(string), "TypeError")
}

@(test)
m140_construct_normal_continua_funcionando :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: as formas válidas seguem iguais.
    src := `
        function A(a, b){ this.soma = a + b }
        class B {}
        var x = Reflect.construct(A, [1, 2]);
        var y = Reflect.construct(A, [3, 4], B);
        x.soma + "|" + y.soma + "|" + (y instanceof B)
    `
    testing.expect_value(t, run(src).(string), "3|7|true")
}
