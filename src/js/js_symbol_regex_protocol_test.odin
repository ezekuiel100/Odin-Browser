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
