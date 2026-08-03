package js

// M181 — ordem de inicialização de membros STATIC de classe.
//
// A spec (ClassDefinitionEvaluation) instala TODOS os métodos — de protótipo e
// estáticos — ANTES de rodar qualquer inicializador de campo estático. O motor
// fazia uma passada só, em ordem de fonte, então um campo não enxergava método
// declarado DEPOIS dele:
//
//     class V { static BLACK = V.fromRGB({r:0}); static fromRGB(e){…} }
//
// Essa é literalmente a classe de cor do web player do open.spotify.com, e dava
// `TypeError: v.fromRGB is not a function`. Padrão comum: constantes derivadas
// (BLACK/WHITE/DEFAULT) declaradas no topo e as fábricas embaixo.
//
// Também entrou aqui `ArrayBuffer.isView`, que simplesmente não existia (o mesmo
// site chama ao normalizar entrada binária).

import "core:testing"

// O caso do spotify, reduzido.
@(test)
m181_campo_static_ve_metodo_declarado_depois :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class A {
            static BLACK = A.fromRGB(0);
            static fromRGB(x) { return "rgb" + x; }
        }
        A.BLACK
    `).(string), "rgb0")

    // a forma exata do site: campos de instância + ctor + 2 campos static + fábricas
    testing.expect_value(t, run(`
        class V {
            rgb; a;
            constructor(e, t) { this.rgb = e; this.a = t; }
            static BLACK = V.fromRGB({ r: 0 });
            static WHITE = V.fromRGB({ r: 255 });
            static fromRGBA(e) { return V.fromRGB(e); }
            static fromRGB(e, t) { return new V(e, t); }
        }
        (V.BLACK instanceof V) + "/" + V.BLACK.rgb.r + "/" + V.WHITE.rgb.r + "/" + V.fromRGBA({r:7}).rgb.r
    `).(string), "true/0/255/7")
}

// A ordem ENTRE campos static (e blocos) continua sendo a de fonte: o de baixo
// enxerga o valor do de cima. Se a fase 2 rodasse fora de ordem, isto quebraria.
@(test)
m181_ordem_entre_campos_static_preservada :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`class B { static X = 1; static Y = B.X + 1; } B.Y`).(f64), f64(2))
    testing.expect_value(t, run(`
        var log = [];
        class C {
            static A = (log.push("a"), 1);
            static { log.push("bloco"); }
            static B = (log.push("b"), 2);
        }
        log.join(",")
    `).(string), "a,bloco,b")
}

// Não-regressão: getter/setter static e método de protótipo seguem funcionando.
@(test)
m181_acessores_static_e_proto_intactos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class D {
            static get val() { return 42; }
            metodo() { return 5; }
            static I = new D();
        }
        D.val + "/" + D.I.metodo()
    `).(string), "42/5")
    // campo static que depende de getter static declarado depois
    testing.expect_value(t, run(`
        class E { static V = E.dobro; static get dobro() { return 8; } }
        E.V
    `).(f64), f64(8))
}

// ArrayBuffer.isView: só VIEWS contam — o buffer em si não é view.
@(test)
m181_arraybuffer_isview :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof ArrayBuffer.isView`).(string), "function")
    testing.expect_value(t, run(`ArrayBuffer.isView(new Uint8Array(4))`).(bool), true)
    testing.expect_value(t, run(`ArrayBuffer.isView(new DataView(new ArrayBuffer(8)))`).(bool), true)
    testing.expect_value(t, run(`ArrayBuffer.isView(new ArrayBuffer(8))`).(bool), false)
    testing.expect_value(t, run(`ArrayBuffer.isView([1,2]) || ArrayBuffer.isView({}) || ArrayBuffer.isView(null)`).(bool), false)
}
