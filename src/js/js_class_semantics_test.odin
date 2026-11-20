package js

// Semântica de classe que o motor deixava passar em SILÊNCIO (20/11/2026):
//   - chamar a construtora de classe sem `new` não lançava;
//   - `class extends null` era tratada como classe BASE;
//   - `super` em método de LITERAL de objeto devolvia undefined;
//   - `super` em método STATIC procurava em Pai.prototype em vez de Pai;
//   - `new (f.bind(...))()` usava o boundThis em vez do objeto novo;
//   - argumento que lança NÃO abortava a chamada (a função rodava assim mesmo).
// Rodar: odin test src/js

import "core:testing"

@(test)
class_sem_new_lanca :: proc(t: ^testing.T) {
    src := `
        class A { constructor(){ this.x = 1; } }
        class E {}
        class D extends A {}
        const r = [];
        for (const f of [() => A(), () => E(), () => A.call({}), () => D(), () => A.bind(null)()]) {
            try { f(); r.push("nao"); } catch (e) { r.push(e instanceof TypeError ? "TE" : e.name); }
        }
        r.join(",")`
    testing.expect_value(t, run(src).(string), "TE,TE,TE,TE,TE")
}

@(test)
class_com_new_continua :: proc(t: ^testing.T) {
    // super(), Reflect.construct, extends builtin/ES5 e new.target no pai = derivada
    src := `
        class P { constructor(){ this.nt = new.target; } }
        class Q extends P {}
        class R extends P { constructor(){ super(); this.ok = 1; } }
        function F(){ this.f = new.target === G; }
        class G extends F {}
        class Er extends Error { constructor(m){ super(m); } }
        [new Q().nt === Q, new R().nt === R, Reflect.construct(P, []).nt === P,
         new G().f, new Er("m").message === "m"].join(",")`
    testing.expect_value(t, run(src).(string), "true,true,true,true,true")
}

@(test)
class_extends_null :: proc(t: ^testing.T) {
    src := `
        class N extends null {}
        class M extends null { constructor(){ return Object.create(M.prototype); } }
        class S extends null { constructor(){ super(); } }
        const r = [Object.getPrototypeOf(N.prototype) === null,
                   Object.getPrototypeOf(N) === Function.prototype];
        try { new N(); r.push("nao"); } catch (e) { r.push(e instanceof TypeError); }
        try { new S(); r.push("nao"); } catch (e) { r.push(e instanceof TypeError); }
        r.push(new M() instanceof M);
        r.join(",")`
    testing.expect_value(t, run(src).(string), "true,true,true,true,true")
}

@(test)
super_em_literal_de_objeto :: proc(t: ^testing.T) {
    src := `
        const p = { hi(){ return "p:" + this.n; }, v: 1 };
        const o = { n: "o", hi(){ return "o+" + super.hi(); }, get g(){ return super.v; },
                    ["c"](){ return super.v + 1; }, a(){ return (() => super.v + 2)(); } };
        Object.setPrototypeOf(o, p); // depois da criação: super é lido NA chamada
        const q = { __proto__: { w: 9 }, m(){ return super.w; } };
        [o.hi(), o.g, o.c(), o.a(), q.m()].join(",")`
    testing.expect_value(t, run(src).(string), "o+p:o,1,2,3,9")
}

@(test)
super_em_static :: proc(t: ^testing.T) {
    src := `
        class S { static s(){ return "S"; } static v = 4; static get who(){ return this.name; } }
        class T extends S { static s(){ return "T+" + super.s(); } static g(){ return super.v; }
                            static w(){ return super.who; } }
        class U extends T { static s(){ return "U+" + super.s(); } }
        [T.s(), T.g(), T.w(), U.s()].join(",")`
    testing.expect_value(t, run(src).(string), "T+S,4,T,U+T+S")
}

@(test)
new_de_bound_function :: proc(t: ^testing.T) {
    src := `
        class A { f = 5; constructor(){ this.x = 1; } }
        function Pt(x, y){ this.s = x + y; }
        const a = new (A.bind({lixo: 1}))();
        [a.x, a.f, a instanceof A, a.lixo === undefined, new (Pt.bind(null, 1))(2).s].join(",")`
    testing.expect_value(t, run(src).(string), "1,5,true,true,3")
}

@(test)
argumento_que_lanca_aborta_a_chamada :: proc(t: ^testing.T) {
    // a nativa (push) e a de usuário não podem rodar; o 2º argumento nem é avaliado
    src := `
        const log = [];
        function h(){ throw new TypeError("x"); }
        function sink(v){ log.push("sink:" + v); }
        class K { constructor(){ log.push("ctor"); } }
        try { log.push("a" + h()); } catch (e) {}
        try { sink(h(), log.push("efeito")); } catch (e) {}
        try { new K(h()); } catch (e) {}
        log.length + ":" + log.join(",")`
    testing.expect_value(t, run(src).(string), "0:")
}
