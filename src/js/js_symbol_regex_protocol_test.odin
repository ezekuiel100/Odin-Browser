package js

// Symbol.match / matchAll / search / split — os símbolos não existiam, então
// String.prototype.match/matchAll/search/split só aceitavam ^Regex ou string e
// ignoravam qualquer objeto-padrão; e o RegExp.prototype não tinha os @@métodos.

import "core:testing"

@(test)
regex_symbols_existem_e_sao_distintos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[Symbol.match, Symbol.matchAll, Symbol.search, Symbol.split].map(s => typeof s).join()`).(string), "symbol,symbol,symbol,symbol")
    testing.expect_value(t, run(`new Set([Symbol.match, Symbol.matchAll, Symbol.search, Symbol.split, Symbol.replace]).size`).(f64), 5)
    testing.expect_value(t, run(`String(Symbol.matchAll) + Symbol.split.description`).(string), "Symbol(Symbol.matchAll)Symbol.split")
    testing.expect_value(t, run(`Object.getOwnPropertyDescriptor(Symbol, "search").writable`).(bool), false)
}

// O core-js testa exatamente isto (DELEGATES_TO_SYMBOL) antes de trocar o método.
@(test)
string_methods_delegam_ao_simbolo :: proc(t: ^testing.T) {
    src := `
        var log = [];
        function mk(sym) { var o = {}; o[sym] = function (s, x) { log.push(this === o, s, arguments.length); return 7 }; return o }
        var r = ["ab".match(mk(Symbol.match)), "ab".matchAll(mk(Symbol.matchAll)),
                 "ab".search(mk(Symbol.search)), "ab".split(mk(Symbol.split), 3)];
        r.join() + "|" + log.join()
    `
    testing.expect_value(t, run(src).(string), "7,7,7,7|true,ab,1,true,ab,1,true,ab,1,true,ab,2")
    // limit chega INTACTO ao @@split (sem ToUint32 antes)
    testing.expect_value(t, run(`var o={[Symbol.split](s,l){return typeof l+l}}; "x".split(o,"5")`).(string), "string5")
    // receptor não-string chega sem ToString
    testing.expect_value(t, run(`var o={[Symbol.search](s){return typeof s}}; String.prototype.search.call(12, o)`).(string), "number")
    // @@x não chamável é TypeError; null/undefined cai no caminho normal
    testing.expect_value(t, run(`var r="nao lancou"; try { "a".match({[Symbol.match]: 1}) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`"a,b".split({[Symbol.split]: null, toString(){return ","}}).length`).(f64), 2)
}

@(test)
regexp_prototype_tem_os_metodos_nativos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var p=RegExp.prototype; [p[Symbol.match], p[Symbol.matchAll], p[Symbol.search], p[Symbol.split], p[Symbol.replace]].map(f=>typeof f).join()`).(string), "function,function,function,function,function")
    testing.expect_value(t, run(`RegExp.prototype[Symbol.split].name + RegExp.prototype[Symbol.split].length`).(string), "[Symbol.split]2")
    testing.expect_value(t, run(`/b/[Symbol.search]("abc")`).(f64), 1)
    testing.expect_value(t, run(`/\d/g[Symbol.match]("a1b2").join()`).(string), "1,2")
    testing.expect_value(t, run(`/,/[Symbol.split]("a,b,c", 2).join("|")`).(string), "a|b")
    testing.expect_value(t, run(`[.../a(.)/g[Symbol.matchAll]("axay")].map(m=>m[1]+m.index).join()`).(string), "x0,y2")
    testing.expect_value(t, run(`/a/g[Symbol.replace]("aXa", "o")`).(string), "oXo")
    // sem a flag g, o @@matchAll direto dá só o 1º casamento
    testing.expect_value(t, run(`[.../a/[Symbol.matchAll]("aaa")].length`).(f64), 1)
    testing.expect_value(t, run(`var r="nao lancou"; try { RegExp.prototype[Symbol.match].call({}, "a") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
}

// A regex nativa agora passa PELO protocolo: um @@x próprio da instância vence.
@(test)
regex_instancia_sobrescreve_o_simbolo :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var re=/a/; re[Symbol.split]=function(){return "meu"}; "bab".split(re)`).(string), "meu")
    testing.expect_value(t, run(`RegExp.prototype[Symbol.search]=function(){return 42}; "abc".search(/c/)`).(f64), 42)
}

// Os caminhos normais continuam iguais (regressão).
@(test)
regex_string_methods_comportamento_normal :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`"a1b22".match(/\d+/g).join()`).(string), "1,22")
    testing.expect_value(t, run(`var m="xaby".match(/a(b)/); m[1]+m.index+m.input`).(string), "b1xaby")
    testing.expect_value(t, run(`"a1b2".split(/(\d)/).join("|")`).(string), "a|1|b|2|")
    testing.expect_value(t, run(`"a-b-c".split("-", 2).join()`).(string), "a,b")
    testing.expect_value(t, run(`"abc".search("c")`).(f64), 2)
    testing.expect_value(t, run(`[..."a.b".matchAll(".")].length`).(f64), 3) // string vira regex com g
    testing.expect_value(t, run(`"aXa".replace(/a/g, "o") + "aXa".replace("a", "o")`).(string), "oXooXa")
}

@(test)
regex_string_methods_to_string_e_syntax_error :: proc(t: ^testing.T) {
    // padrão não-string passa por ToString (antes virava o padrão VAZIO)
    testing.expect_value(t, run(`"x1".match(1)[0] + "x1".match(1).index`).(string), "11")
    testing.expect_value(t, run(`"ab1".search(1)`).(f64), 2)
    testing.expect_value(t, run(`"x".match() !== null && "x".match()[0] === ""`).(bool), true)
    // receptor não-string passa por ToString
    testing.expect_value(t, run(`String.prototype.match.call(123, /2/)[0]`).(string), "2")
    // (Padrão inválido via string lança SyntaxError quando o compilador o recusa — mas
    // o compilador em runtime é brando: aceita "(", "a**", "[b-a]", "+", igual ao
    // `new RegExp`. Sem caso testável aqui.)
    testing.expect_value(t, run(`var r="nao lancou"; try { String.prototype.match.call(null, /a/) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    // match global deixa lastIndex em 0
    testing.expect_value(t, run(`var re=/a/g; re.lastIndex=2; "aaa".match(re).length*10 + re.lastIndex`).(f64), 30)
}

// IsRegExp: @@match decide se o argumento "é regex" para startsWith/includes/
// endsWith/matchAll/replaceAll.
@(test)
is_regexp_usa_symbol_match :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var re=/a/; re[Symbol.match]=false; "/a/x".startsWith(re)`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { "abc".includes({[Symbol.match]: true, toString(){return "a"}}) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { "abc".endsWith(/c/) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { "a".matchAll(/a/) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { "a".replaceAll(/a/, "b") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    // objeto IsRegExp sem g também é recusado pelo matchAll (pela prop flags)
    testing.expect_value(t, run(`var r="nao lancou"; try { "a".matchAll({[Symbol.match]:true, flags:"i", [Symbol.matchAll](){return 1}}) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`"a".matchAll({[Symbol.match]:true, flags:"g", [Symbol.matchAll](){return 1}})`).(f64), 1)
}

// `class R extends RegExp`: a instância é um ^Object com a ^Regex no slot `prim`, e
// o unwrap_prim não a entregava aos nativos — test dava false, exec null, match
// TypeError (e, antes do protocolo de símbolos, o padrão VAZIO).
@(test)
regex_subclasse_usa_a_regex_embrulhada :: proc(t: ^testing.T) {
    pre :: `class R extends RegExp {}; var r = new R("a","g"); `
    testing.expect_value(t, run(pre + `"aa".match(r).join()`).(string), "a,a")
    testing.expect_value(t, run(pre + `String(r.test("a")) + r.exec("ba")[0]`).(string), "truea")
    testing.expect_value(t, run(pre + `String(r) + r.source + r.flags + r.global`).(string), "/a/gagtrue")
    testing.expect_value(t, run(pre + `"bab".split(r).join() + "|" + "aXa".replace(r, "o") + "|" + "ba".search(r)`).(string), "b,b|oXo|1")
    testing.expect_value(t, run(pre + `[..."aa".matchAll(r)].length`).(f64), 2)
    testing.expect_value(t, run(pre + `String(r instanceof R) + (r instanceof RegExp)`).(string), "truetrue")
    // lastIndex é o estado da regex embrulhada (ler e escrever)
    testing.expect_value(t, run(pre + `r.lastIndex = 1; var m = r.exec("aa"); m.index + "," + r.lastIndex`).(string), "1,2")
}

@(test)
regex_subclasse_metodo_proprio_e_super :: proc(t: ^testing.T) {
    src := `
        class R extends RegExp {
            exec(s) { var m = super.exec(s); if (m) m.tag = this instanceof R; return m }
            hello() { return "oi " + this.source }
        }
        var r = new R("b");
        var m = r.exec("abc");
        m[0] + m.index + m.tag + "|" + r.hello()
    `
    testing.expect_value(t, run(src).(string), "b1true|oi b")
}

// ── exec sobrescrito (RegExpExec) ────────────────────────────────────────────
// Os @@métodos e o test chamam o `exec` que o objeto TIVER; antes rodavam sempre
// o motor e ignoravam `re.exec = fn`.
@(test)
regex_exec_sobrescrito_e_respeitado :: proc(t: ^testing.T) {
    // o teste DELEGATES_TO_EXEC do core-js, para cada método. matchAll dá FALSE
    // pela spec: o @@matchAll constrói um matcher NOVO (new C(rx, flags)), que não
    // herda o `exec` próprio da instância — só o de uma subclasse (teste abaixo).
    src := `
        var out = [];
        for (var k of ["match", "search", "replace", "split", "matchAll"]) {
            var called = false, re = /a/;
            if (k === "split") { re = {}; re.constructor = {}; re.constructor[Symbol.species] = function () { return re }; re.flags = "" }
            if (k === "matchAll") re = /a/g;
            re.exec = function () { called = true; return null };
            if (k === "split") re[Symbol.split] = /./[Symbol.split];
            var m = k === "matchAll" ? RegExp.prototype[Symbol.matchAll].call(re, "") : re[Symbol[k]]("");
            if (k === "matchAll") [...m];
            out.push(k + ":" + called);
        }
        out.join()
    `
    testing.expect_value(t, run(src).(string), "match:true,search:true,replace:true,split:true,matchAll:false")
    testing.expect_value(t, run(`var re=/a/; re.exec=function(){return null}; String("a".match(re)) + re.test("a")`).(string), "nullfalse")
    // exec que devolve um resultado inventado: o match usa o que veio dele
    testing.expect_value(t, run(`var re=/x/; re.exec=function(s){var r=["zz"]; r.index=1; return r}; "abc".match(re)[0] + "abc".search(re)`).(string), "zz1")
    // exec que devolve primitivo é TypeError
    testing.expect_value(t, run(`var re=/a/; re.exec=function(){return 1}; var r="nao lancou"; try { re.test("a") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
}

@(test)
regex_subclasse_com_exec_proprio :: proc(t: ^testing.T) {
    src := `
        var calls = 0;
        class R extends RegExp { exec(s) { calls++; return super.exec(s) } }
        var r = new R("a", "g");
        var a = "banana".match(r).join("");
        var b = "banana".replace(r, "o");
        var c = "banana".split(new R("a")).join("|");
        var d = [..."banana".matchAll(r)].length;
        var e = new R("n").test("banana");
        [a, b, c, d, e, calls > 10].join()
    `
    testing.expect_value(t, run(src).(string), "aaa,bonono,b|n|n|,3,true,true")
}

// replace genérico: $-refs, grupos nomeados e função, com o resultado vindo do exec
@(test)
regex_replace_generico :: proc(t: ^testing.T) {
    pre :: `class R extends RegExp { exec(s) { return super.exec(s) } } `
    testing.expect_value(t, run(pre + `"john smith".replace(new R("([a-z]+) ([a-z]+)"), "$2, $1 [$&] $$ $0 $3")`).(string), "smith, john [john smith] $ $0 $3")
    testing.expect_value(t, run(pre + `"2020-05".replace(new R("(?<y>[0-9]+)-(?<m>[0-9]+)"), "$<m>/$<y> $<z>.")`).(string), "05/2020 .")
    testing.expect_value(t, run(pre + `"a1b2".replace(new R("([0-9])", "g"), function(m, d, pos, s) { return "[" + d + pos + s.length + "]" })`).(string), "a[114]b[234]")
    testing.expect_value(t, run(pre + "\"abc\".replace(new R(\"b\"), \"$`|$'\")").(string), "aa|cc")
    testing.expect_value(t, run(pre + `"aaa".replace(new R("", "g"), "-")`).(string), "-a-a-a-")
}

// ── getters do RegExp.prototype ──────────────────────────────────────────────
@(test)
regex_prototype_flags_e_getters :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`RegExp.prototype.flags`).(string), "")
    testing.expect_value(t, run(`String(RegExp.prototype.global) + RegExp.prototype.source`).(string), "undefined(?:)")
    testing.expect_value(t, run(`typeof Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get`).(string), "function")
    // o getter de flags é GENÉRICO: lê global/ignoreCase/... do this, em ordem canônica
    testing.expect_value(t, run(`Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get.call({sticky:1, global:true, hasIndices:"x", ignoreCase:0})`).(string), "dgy")
    testing.expect_value(t, run(`Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get.call(/a/gimsuy)`).(string), "gimsuy")
    testing.expect_value(t, run(`var r="nao lancou"; try { Object.getOwnPropertyDescriptor(RegExp.prototype, "global").get.call({}) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    // subclasse herda os getters
    testing.expect_value(t, run(`class R extends RegExp {}; var r = new R("a", "ig"); r.flags + r.global + r.source`).(string), "gitruea")
    testing.expect_value(t, run(`typeof RegExp[Symbol.species]`).(string), "function")
}

// `RegExp.prototype.exec = fn` vale para TODAS as regex (antes a instância devolvia
// o exec nativo fixo e ignorava o protótipo).
@(test)
regex_exec_sobrescrito_no_prototipo :: proc(t: ^testing.T) {
    src := `
        var orig = RegExp.prototype.exec, n = 0;
        RegExp.prototype.exec = function (s) { n++; return orig.call(this, s) };
        var a = "abc".match(/b/)[0] + /c/.test("abc") + "abc".replace(/a/, "x") + "a,b".split(/,/).length;
        a + n
    `
    testing.expect_value(t, run(src).(string), "btruexbc26") // split chama exec 3x (q=0,1,2), os outros 1x cada
}

// O @@matchAll genérico é PREGUIÇOSO: cada next() chama exec uma vez (antes coletava
// tudo na chamada do matchAll).
@(test)
regex_match_all_generico_e_preguicoso :: proc(t: ^testing.T) {
    src := `
        var calls = 0;
        class R extends RegExp { exec(s) { calls++; return super.exec(s) } }
        var it = "aaaa".matchAll(new R("a", "g"));
        var antes = calls;
        var first = it.next();
        var depois1 = calls;
        var rest = [...it].length;
        [antes, depois1, first.value[0], first.value.index, rest, calls, it.next().done].join()
    `
    testing.expect_value(t, run(src).(string), "0,1,a,0,3,5,true")
    // um exec que nunca devolve null não trava: o consumidor para quando quiser
    testing.expect_value(t, run(`class R extends RegExp { exec() { var r = ["x"]; r.index = 0; return r } } var it = "abc".matchAll(new R("x", "g")); it.next(); it.next().value[0]`).(string), "x")
    testing.expect_value(t, run(`class R extends RegExp { exec(s) { return super.exec(s) } } var it = "a".matchAll(new R("a", "g")); Object.prototype.toString.call(it) + (it[Symbol.iterator]() === it) + Object.keys(it).length`).(string), "[object RegExp String Iterator]true0")
    testing.expect_value(t, run(`class R extends RegExp { exec(s) { return super.exec(s) } } var it = "a".matchAll(new R("a", "g")); var r = "nao lancou"; try { it.next.call({}) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
}

// exec nativo com `this` que não é regex lança (RegExpBuiltinExec), e o test herdado
// por um objeto comum também.
@(test)
regex_exec_nativo_this_invalido_lanca :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var r="nao lancou"; try { Object.create(RegExp.prototype).test("a") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { RegExp.prototype.exec.call({}, "a") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`/a/.exec("ba").index`).(f64), 1)
}
