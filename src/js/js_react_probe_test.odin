package js

// PROBES do caminho de render do React 19 (investigação da "árvore vazia").
// Cada teste isola uma semântica que o reconciler exige. Falha = culpado.

import "core:testing"

// O CRUX: reconcileChildFibers faz `switch (newChild.$$typeof) { case REACT_ELEMENT_TYPE: ... }`.
// REACT_ELEMENT_TYPE = Symbol.for("react.transitional.element"). Se esse switch com
// discriminante Symbol não casar, cai no default → apaga filhos → árvore VAZIA.
@(test)
test_probe_symbol_for_switch :: proc(t: ^testing.T) {
    src := `
        var S1 = Symbol.for("react.transitional.element");
        var S2 = Symbol.for("react.transitional.element");
        var d = S1;
        var out = "none";
        switch (d) { case S2: out = "matched"; break; default: out = "default"; }
        out
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "matched", "switch com Symbol.for deve casar (senão reconciler apaga tudo)")
}

@(test)
test_probe_symbol_for_identity :: proc(t: ^testing.T) {
    v, _ := run(`Symbol.for("x") === Symbol.for("x")`).(bool)
    testing.expect(t, v, "Symbol.for interna: mesma chave = mesmo símbolo")
}

@(test)
test_probe_symbol_distinct :: proc(t: ^testing.T) {
    v, _ := run(`Symbol.for("a") === Symbol.for("b")`).(bool)
    testing.expect(t, !v, "Symbol.for de chaves distintas deve diferir")
}

@(test)
test_probe_typeof_symbol :: proc(t: ^testing.T) {
    v, _ := run(`typeof Symbol.for("x") === "symbol"`).(bool)
    testing.expect(t, v, "typeof de símbolo deve ser 'symbol'")
}

// Elemento React em miniatura: objeto com $$typeof + type + props.children.
@(test)
test_probe_element_shape :: proc(t: ^testing.T) {
    src := `
        var EL = Symbol.for("react.transitional.element");
        function jsx(type, props){ return { $$typeof: EL, type: type, key: null, props: props }; }
        var e = jsx("div", { children: "oi" });
        var ok = e.$$typeof === EL;
        var out = "no";
        switch (e.$$typeof) { case EL: out = e.type + ":" + e.props.children; break; }
        (ok ? "T" : "F") + "|" + out
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "T|div:oi", "elemento deve preservar $$typeof e casar no switch")
}

@(test)
test_probe_isarray :: proc(t: ^testing.T) {
    a, _ := run(`Array.isArray([1,2])`).(bool)
    b, _ := run(`Array.isArray("ab")`).(bool)
    c, _ := run(`Array.isArray({length:2})`).(bool)
    testing.expect(t, a && !b && !c, "Array.isArray deve distinguir arrays")
}

// children como array (React itera): reconcileChildrenArray
@(test)
test_probe_children_array :: proc(t: ^testing.T) {
    src := `
        var EL = Symbol.for("react.transitional.element");
        var kids = [ {$$typeof:EL,type:"a"}, {$$typeof:EL,type:"b"} ];
        var s = "";
        if (Array.isArray(kids)) { for (var i=0;i<kids.length;i++) s += kids[i].type; }
        s
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "ab", "children array deve iterar")
}

// Object.assign preservando $$typeof (React copia props com frequência)
@(test)
test_probe_object_assign_symbol :: proc(t: ^testing.T) {
    src := `
        var EL = Symbol.for("react.transitional.element");
        var e = { $$typeof: EL, type: "div" };
        var c = Object.assign({}, e, { key: "k" });
        c.$$typeof === EL ? "keep" : "lost"
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "keep", "Object.assign deve preservar valor de símbolo")
}

// função componente: type é função, React chama type(props)
@(test)
test_probe_function_component :: proc(t: ^testing.T) {
    src := `
        var EL = Symbol.for("react.transitional.element");
        function App(props){ return { $$typeof: EL, type: "h1", props: { children: props.title } }; }
        var el = { $$typeof: EL, type: App, props: { title: "Hi" } };
        var out = "no";
        if (typeof el.type === "function") { var r = el.type(el.props); out = r.type + "/" + r.props.children; }
        out
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "h1/Hi", "componente-função deve ser chamável com props")
}

@(test)
test_probe_return_null :: proc(t: ^testing.T) {
    a, _ := run("function f(){ return null; } f() === null").(bool)
    testing.expect(t, a, "return null deve dar null (não undefined)")
}
@(test)
test_probe_null_vs_undef :: proc(t: ^testing.T) {
    a, _ := run("null !== undefined").(bool) // JS: true
    testing.expect(t, a, "null !== undefined deve ser true")
    b, _ := run("var o={r:null}; o.r === null").(bool)
    testing.expect(t, b, "prop setada como null deve ler como null")
    c, _ := run("var o={}; o.missing === undefined").(bool)
    testing.expect(t, c, "prop ausente deve ser undefined")
}
@(test)
test_probe_flushsync_loop :: proc(t: ^testing.T) {
    // simula do{d=d(true)}while(null!==d) com callback que retorna null
    src := "var calls=0; function cb(x){ calls++; return null; } var d=cb; do { d = d(true); } while (null !== d); calls"
    testing.expect_value(t, as_number(run(src)), f64(1))
}

@(test)
test_probe_arguments :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("function f(){ return arguments.length; } f(1,2,3)")), f64(3))
    testing.expect_value(t, as_number(run("function f(){ return arguments[1]; } f(10,20,30)")), f64(20))
}
@(test)
test_probe_forin_hasown :: proc(t: ^testing.T) {
    src := "var c={id:'x',cls:'y'}; var p={}; for(var k in c){ if(Object.prototype.hasOwnProperty.call(c,k)) p[k]=c[k]; } p.id + p.cls"
    v, _ := run(src).(string)
    testing.expect(t, v == "xy", "for-in + hasOwnProperty.call deve copiar props")
}

@(test)
test_probe_createElement_exact :: proc(t: ^testing.T) {
    // réplica EXATA do laço de cópia de props do React.createElement
    src := `
        var aa = Object.prototype.hasOwnProperty;
        var ba = {key:true,ref:true,__self:true,__source:true};
        var b = {id:'x', cls:'y'};
        var e = {};
        var f;
        for (f in b) { if (aa.call(b,f) && !ba.hasOwnProperty(f)) e[f] = b[f]; }
        (e.id || 'MISS') + (e.cls || 'MISS')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "xy", "réplica do copy-loop do React deve copiar id+cls")
}

@(test)
test_probe_seq_eval :: proc(t: ^testing.T) {
    a, _ := run("var o={id:1}; var r=(0,1,o); r===o").(bool)
    testing.expect(t, a, "sequência (0,1,o) deve resultar em o")
    // for-in com iterável entre parênteses simples (order-independent)
    c, _ := run("var o={id:1}; var e={}; for(var k in (o)) e[k]=1; e.id").(f64)
    testing.expect(t, c == 1, "for-in com (o)")
}

@(test)
test_probe_forin_seq_noparens :: proc(t: ^testing.T) {
    // caso REAL do React: for(f in A, B, b) SEM parênteses. Order-independent.
    src := "var o={id:1,cls:2}; var e={}; for (var k in 0, 1, o) e[k]=o[k]; (e.id||'M')+','+(e.cls||'M')"
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2", "for-in sobre sequência sem parênteses deve iterar o último operando")
}
@(test)
test_probe_forin_count :: proc(t: ^testing.T) {
    // for-in simples, order-independent (conta chaves copiadas)
    src := "var o={id:1,cls:2}; var e={}; for (var k in o) e[k]=o[k]; (e.id||'M')+','+(e.cls||'M')"
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2", "for-in básico deve copiar id+cls")
}

@(test)
test_probe_typeof_eq :: proc(t: ^testing.T) {
    // padrão exato de createFiberFromTypeAndProps do React
    src := "var a='h1'; var g=2; if('function'===typeof a) g=1; else if('string'===typeof a) g=5; else g=99; g"
    testing.expect_value(t, as_number(run(src)), f64(5))
    // com função
    src2 := "var a=function(){}; var g=2; if('function'===typeof a) g=1; else if('string'===typeof a) g=5; else g=99; g"
    testing.expect_value(t, as_number(run(src2)), f64(1))
    // typeof direto
    v, _ := run("'string' === typeof 'h1'").(bool)
    testing.expect(t, v, "'string' === typeof 'h1'")
}

@(test)
test_probe_labeled_switch :: proc(t: ^testing.T) {
    // estrutura EXATA do createFiberFromTypeAndProps: else com label antes do switch
    src := `
        function rd(a){
            var g = 2;
            if ("function" === typeof a) g = 1;
            else if ("string" === typeof a) g = 5;
            else a: switch (a) { case 99: break a; default: g = 99; }
            return g;
        }
        rd("h1")
    `
    testing.expect_value(t, as_number(run(src)), f64(5))
}
@(test)
test_probe_labeled_loop :: proc(t: ^testing.T) {
    src := `
        var s='';
        outer: for (var i=0;i<3;i++){ for (var j=0;j<3;j++){ if (j===1) continue outer; s += ''+i+j; } }
        s
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "001020", "continue com label deve pular p/ o loop externo")
}

@(test)
test_labeled_break_outer :: proc(t: ^testing.T) {
    src := `
        var s='';
        outer: for (var i=0;i<3;i++){ for (var j=0;j<3;j++){ if (i===1 && j===1) break outer; s+=''+i+j; } }
        s
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "00010210", "break outer deve sair dos dois loops")
}
@(test)
test_labeled_plain_break_still_works :: proc(t: ^testing.T) {
    // break/continue SEM label continuam funcionando
    a, _ := run("var s=0; for(var i=0;i<5;i++){ if(i===3) break; s+=i; } s").(f64)
    testing.expect(t, a == 3, "break simples (0+1+2)")
    b, _ := run("var s=0; for(var i=0;i<5;i++){ if(i===2) continue; s+=i; } s").(f64)
    testing.expect(t, b == 8, "continue simples (0+1+3+4)")
}
@(test)
test_labeled_switch_break :: proc(t: ^testing.T) {
    // break de label saindo de um switch dentro de loop (padrão do React)
    src := `
        var out = 0;
        loop: for (var i=0;i<5;i++){
            switch(i){ case 2: break loop; default: out += 1; }
        }
        out
    `
    testing.expect_value(t, as_number(run(src)), f64(2))
}

@(test)
test_probe_array_ctor_n :: proc(t: ^testing.T) {
    // React.createElement usa Array(childrenLength) p/ >1 filho
    a, _ := run("var a = Array(3); a.length").(f64)
    testing.expect(t, a == 3, "Array(3).length deve ser 3")
    src := "var a = Array(3); a[0]=10; a[1]=20; a[2]=30; a[0]+a[1]+a[2]"
    testing.expect_value(t, as_number(run(src)), f64(60))
    // Array.isArray(Array(3))
    b, _ := run("Array.isArray(Array(3))").(bool)
    testing.expect(t, b, "Array(3) deve ser um array")
}

@(test)
test_probe_ce_children :: proc(t: ^testing.T) {
    src := `
        function ce(a, b){
            var d = {};
            var e = arguments[2];
            var l = arguments.length - 2;
            if (1 === l) d.children = e;
            else if (1 < l) { for (var f = Array(l), k = 0; k < l; k++) f[k] = arguments[k+2]; d.children = f; }
            return d;
        }
        var r = ce('div', null, 'a', 'b', 'c');
        (Array.isArray(r.children) ? 'A' : 'N') + (r.children ? r.children.length : 'X')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "A3", "children de 3 filhos deve ser array de len 3")
}

@(test)
test_probe_narrow :: proc(t: ^testing.T) {
    // A: index assignment num array de slots
    a, _ := run("var f=Array(3); for(var k=0;k<3;k++) f[k]=k*10; f[0]+','+f[1]+','+f[2]").(string)
    testing.expect(t, a == "0,10,20", "index-assign em Array(3)")
    // B: for-init com MÚLTIPLOS declaradores (var g=..., k=0)
    b, _ := run("var out; for(var g=Array(3), k=0; k<3; k++) g[k]=k+1; out=g; out[0]+','+out[1]+','+out[2]").(string)
    testing.expect(t, b == "1,2,3", "for-init multi-declarador com Array")
    // C: só a condição — o k do multi-declarador é lido na cond?
    c, _ := run("var n=0; for(var g=Array(3), k=0; k<3; k++) n++; n").(f64)
    testing.expect(t, c == 3, "cond do for lê k do 2º declarador")
}

@(test)
test_probe_forinit_bisect :: proc(t: ^testing.T) {
    a, _ := run("var s=''; for(var k=0;k<3;k++) s+=k; s").(string)
    testing.expect(t, a == "012", "1: for single declarator")
    b, _ := run("var s=''; for(var g=5, k=0; k<3; k++) s+=k; s").(string)
    testing.expect(t, b == "012", "2: for multi declarator (no array)")
    c, _ := run("var s=''; for(var g=Array(3), k=0; k<3; k++) s+=k; s").(string)
    testing.expect(t, c == "012", "3: for multi declarator + Array")
}

@(test)
test_map_iterator_protocol :: proc(t: ^testing.T) {
    // o padrão EXATO do React: for(b=m.entries(); !(y=b.next()).done; ) — deve TERMINAR
    src := `
        var m = new Map(); m.set('a',1); m.set('b',2);
        var out = '';
        for (var b = m.entries(); ; ) { var y = b.next(); if (y.done) break; out += y.value[0] + y.value[1]; }
        out
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "a1b2", "iterar Map.entries() via next()/done deve terminar")
}
@(test)
test_map_iterator_forof :: proc(t: ^testing.T) {
    a, _ := run("var m=new Map(); m.set('x',9); var s=''; for(var k of m.keys()) s+=k; s").(string)
    testing.expect(t, a == "x", "for-of sobre map.keys() (iterador)")
    b, _ := run("var s=new Set([1,2,3]); var t=0; for(var v of s.values()) t+=v; t").(f64)
    testing.expect(t, b == 6, "for-of sobre set.values()")
}
@(test)
test_iterator_spread :: proc(t: ^testing.T) {
    a, _ := run("var m=new Map(); m.set('a',1); m.set('b',2); var ks=[...m.keys()]; ks.length + ks[0] + ks[1]").(string)
    testing.expect(t, a == "2ab", "spread de map.keys()")
}

// ── protocolo Symbol.iterator em objeto custom (for-of / spread) ──────────────

// Iterável definido pelo usuário: método [Symbol.iterator]() devolve um iterador.
ITERABLE_RANGE :: `
    var range = {
        from: 1, to: 4,
        [Symbol.iterator]: function() {
            var cur = this.from, last = this.to;
            return { next: function() {
                if (cur <= last) return { value: cur++, done: false };
                return { value: undefined, done: true };
            }};
        }
    };
`

@(test)
test_custom_iterable_forof :: proc(t: ^testing.T) {
    src := ITERABLE_RANGE + "var s=0; for (var x of range) s+=x; s"
    testing.expect_value(t, as_number(run(src)), f64(10)) // 1+2+3+4
}

@(test)
test_custom_iterable_spread :: proc(t: ^testing.T) {
    src := ITERABLE_RANGE + "var a=[...range]; a.length + ':' + a[0] + a[3]"
    v, _ := run(src).(string)
    testing.expect(t, v == "4:14", "spread de iterável custom deve materializar [1,2,3,4]")
}

@(test)
test_custom_iterable_spread_in_call :: proc(t: ^testing.T) {
    src := ITERABLE_RANGE + "function sum(a,b,c,d){ return a+b+c+d; } sum(...range)"
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
test_string_spread :: proc(t: ^testing.T) {
    a, _ := run(`var a=[..."abc"]; a.length + a[0] + a[2]`).(string)
    testing.expect(t, a == "3ac", "spread de string deve dar um item por code point")
}

// for-in e Object.keys NÃO devem enumerar a chave-símbolo Symbol.iterator.
@(test)
test_symbol_key_not_enumerated :: proc(t: ^testing.T) {
    // ordem do for-in é instável (map), então conta em vez de comparar string
    fin, _ := run(ITERABLE_RANGE + "var n=0,sym=0; for (var k in range){ n++; if(k.indexOf('Symbol')===0) sym++; } n+':'+sym").(string)
    testing.expect(t, fin == "2:0", "for-in vê from+to e NÃO a chave Symbol.iterator")
    n := as_number(run(ITERABLE_RANGE + "Object.keys(range).length"))
    testing.expect_value(t, n, f64(2))
}

// iterável cujo Symbol.iterator retorna o PRÓPRIO objeto (padrão comum de classes).
@(test)
test_self_iterable :: proc(t: ^testing.T) {
    src := `
        var it = {
            i: 0, n: 3,
            next: function(){ return this.i < this.n ? {value:this.i++,done:false} : {value:undefined,done:true}; },
            [Symbol.iterator]: function(){ return this; }
        };
        var s=''; for (var x of it) s+=x; s
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "012", "objeto que é seu próprio iterador deve iterar via for-of")
}
