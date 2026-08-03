package js

// M220 — a exceção que sobrava na PÁGINA DE REPOSITÓRIO do github, e a que estava
// ESCONDIDA atrás dela. Duas raízes, ambas da família "variante da union ignorada em
// silêncio" que já mordeu no M180 e no M208.
//
// (A) `Symbol.prototype` NÃO EXISTIA. Symbol era o último primitivo sem `.prototype`
//     — exatamente a falta que o M127 consertou no Boolean, e pelo mesmo motivo: o
//     padrão `uncurryThis` de biblioteca lê o método NO PROTÓTIPO:
//
//         const symbolToString = unapply(Symbol.prototype.toString)   ← DOMPurify
//
//     `reading 'toString' of undefined` derrubava o módulo do DOMPurify inteiro (é
//     ele que sanitiza o markdown do README).
//
// (B) Com (A) resolvido, a execução avançou e caiu na SEGUINTE:
//     `reading '__SLOT__' of undefined`. O `Object.assign` estreitava o DESTINO para
//     `^Object` (`dest, ok := arg.(^Object); if !ok do return arg`), então o idioma
//     mais comum de componente React composto
//
//         let W = Object.assign(PageLayout, {Header, Content, Pane, Sidebar, Footer})
//
//     devolvia `W` INTACTO — sem subcomponente nenhum — porque neste motor Function é
//     variante própria da union. Três módulos adiante o Primer lia
//     `a.M.Header.__SLOT__` e morria. O mesmo estreitamento estava na FONTE (função
//     não era copiada) e no spread `{...src}` de object literal, que tinha uma cópia
//     PRÓPRIA da lista de tipos e ficara só no `^Object` — `{...[9,10]}` dava `{}`.
//
// ⚠️ Lição do par: **a segunda exceção só existe depois de consertar a primeira.**
// Contar "quantas exceções a página tem" antes de consertar a primeira subestima o
// trabalho — elas estão em FILA, não em paralelo.

import "core:testing"

// ⚠️ `run(src).(string)` PANICA quando a expressão lança (o Value vem nil) — e um
// panic numa thread do runner PENDURA a suíte inteira em vez de reportar. Medido: a
// primeira rodada de sabotagem deste marco travou por isso, não por bug no motor.
// Aqui a exceção vira um valor comparável, e o teste FALHA como deveria.
@(private = "file")
run_s :: proc(src: string) -> string {
    v := run(src)
    s, ok := v.(string)
    if !ok do return "<excecao ou nao-string>"
    return s
}

// ── (A) Symbol.prototype ─────────────────────────────────────────────────────

@(test)
m220_symbol_prototype_existe :: proc(t: ^testing.T) {
    src := `
        (typeof Symbol.prototype === "object" && Symbol.prototype !== null
            && typeof Symbol.prototype.toString === "function"
            && typeof Symbol.prototype.valueOf === "function"
            && Symbol.prototype.constructor === Symbol) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_uncurry_this_do_dompurify :: proc(t: ^testing.T) {
    // a forma EXATA do bundle: unapply(Symbol.prototype.toString) e depois aplicar
    // num símbolo
    src := `
        function unapply(f){ return function(self){
            var n = arguments.length, r = Array(n > 1 ? n - 1 : 0), i = 1;
            for (; i < n; i++) r[i-1] = arguments[i];
            return f.apply(self, r);
        } }
        var symbolToString = "u" < typeof Symbol ? null : unapply(Symbol.prototype.toString);
        symbolToString(Symbol("abc"))
    `
    testing.expect_value(t, run_s(src), "Symbol(abc)")
}

@(test)
m220_metodo_da_instancia_e_o_MESMO_do_prototipo :: proc(t: ^testing.T) {
    // o %SymbolPrototype% é a fonte ÚNICA: `sym.toString` e `Symbol.prototype.toString`
    // têm de ser o MESMO objeto-função, senão as duas cópias divergem com o tempo
    src := `
        var s = Symbol("x");
        (s.toString === Symbol.prototype.toString
            && s.valueOf === Symbol.prototype.valueOf
            && s.toString() === "Symbol(x)"
            && Symbol.prototype.valueOf.call(s) === s) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_toString_de_this_nao_simbolo_lanca :: proc(t: ^testing.T) {
    // é o que a spec manda (thisSymbolValue) e o que o Chrome faz — quem depende
    // disso vê o mesmo dos dois lados.
    // ⚠️ Na prática é um CONTROLE: sem `Symbol.prototype` a leitura do `.toString`
    // já lança TypeError, então ele passa dos dois lados. Fica porque trava o TIPO
    // do erro (um `undefined is not a function` silencioso passaria despercebido).
    src := `
        var r = "nao lancou";
        try { Symbol.prototype.toString.call({}) } catch (e) { r = e.constructor.name }
        r
    `
    testing.expect_value(t, run_s(src), "TypeError")
}

@(test)
m220_symbol_continua_inteiro :: proc(t: ^testing.T) {
    // CONTROLE: o `.prototype` novo não pode ter mexido em identidade, descrição,
    // registro global nem nos símbolos bem-conhecidos
    src := `
        var a = Symbol("d"), b = Symbol("d");
        (a !== b && a.description === "d"
            && Symbol.for("k") === Symbol.for("k")
            && Symbol.for("k") !== Symbol("k")
            && typeof [][Symbol.iterator] === "function"
            && typeof Symbol.iterator === "symbol") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

// ── (B) Object.assign / spread com destino e fonte que não são `^Object` ─────

@(test)
m220_assign_em_FUNCAO_o_idioma_do_primer :: proc(t: ^testing.T) {
    // a cadeia inteira que quebrava: compor o componente, pendurar o __SLOT__ e ler.
    //
    // ⚠️ Sem asserção de ORDEM: `Object.keys` de uma FUNÇÃO percorre o mapa CRU de
    // props (o motor só mantém ordem de inserção em ^Object, via `own_enum_keys`),
    // então a ordem varia entre execuções. A 1ª versão deste teste travava
    // "Header,Content" e caiu numa rodada de sabotagem por motivo ERRADO — teste
    // flaky mascarado de teste que morde. Ordem de função é gap anotado, não garantia.
    // ⚠️ E o comentário fica AQUI, não dentro do literal ` ` do JS: crase dentro de
    // raw string do Odin FECHA a string (custou um Syntax Error).
    src := `
        function PageLayout(){}
        function Header(){}
        function Content(){}
        var W = Object.assign(PageLayout, { Header: Header, Content: Content });
        Header.__SLOT__ = Symbol("PageLayout.Header");
        (W === PageLayout && W.Header === Header && W.Content === Content
            && typeof W.Header.__SLOT__ === "symbol"
            && Object.keys(W).length === 2
            && Object.keys(W).sort().join(",") === "Content,Header") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_assign_em_ARRAY_indice_vira_item :: proc(t: ^testing.T) {
    // set_INDEX e não set_member: com _member a chave "0" iria para as props do
    // array em vez do item, e o array voltaria com o conteúdo velho
    src := `
        var a = [0, 0];
        var r = Object.assign(a, [7, 8]);
        var b = [1, 2];
        Object.assign(b, { marca: "x" });
        (r === a && a[0] === 7 && a[1] === 8 && a.length === 2
            && b.marca === "x" && b[0] === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_assign_de_FUNCAO_como_fonte :: proc(t: ^testing.T) {
    // props estáticas do componente são copiadas; `name`/`length`/`prototype` são
    // próprias mas NÃO-enumeráveis e ficam de fora (igual ao Chrome)
    src := `
        function Comp(a, b){}
        Comp.displayName = "Comp";
        Comp.__SLOT__ = 1;
        var o = Object.assign({}, Comp);
        (o.displayName === "Comp" && o.__SLOT__ === 1
            && o.name === undefined && o.length === undefined
            && o.prototype === undefined) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_spread_de_objeto_literal_cobre_os_mesmos_tipos :: proc(t: ^testing.T) {
    // `{...src}` tinha uma CÓPIA PRÓPRIA da lista de tipos e ficara só no ^Object
    src := `
        function C(){} C.z = 5;
        var r = [
            JSON.stringify({...C}),
            JSON.stringify({...[9,10]}),
            JSON.stringify({..."ab"}),
            JSON.stringify({...null, k: 1}),
            JSON.stringify({...undefined, k: 2})
        ].join("|");
        r
    `
    testing.expect_value(t, run_s(src),
        `{"z":5}|{"0":9,"1":10}|{"0":"a","1":"b"}|{"k":1}|{"k":2}`)
}

@(test)
m220_assign_de_null_lanca_e_primitivo_volta_intacto :: proc(t: ^testing.T) {
    // ToObject(undefined/null) → TypeError (spec). Primitivo a spec EMBRULHA e as
    // escritas se perdem no embrulho — aqui devolvemos o primitivo, mesmo efeito
    // observável (degradação anotada).
    src := `
        var lancou = "nao";
        try { Object.assign(null, { a: 1 }) } catch (e) { lancou = e.constructor.name }
        (lancou === "TypeError" && Object.assign(5, { a: 1 }) === 5) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_assign_de_objeto_continua_igual :: proc(t: ^testing.T) {
    // CONTROLE (passa dos dois lados): o caminho ^Object→^Object é o de 99% do
    // corpus e não pode ter mudado — inclusive invocar GETTER da fonte e preservar
    // a ordem de inserção
    src := `
        var fonte = { a: 1, get b(){ return 2 }, c: 3 };
        var d = Object.assign({ z: 0 }, fonte, { c: 9 });
        var so_dados = Object.assign({ z: 0 }, { a: 1, b: 2 }, { c: 3 });
        (d.a === 1 && d.b === 2 && d.c === 9 && d.z === 0
            && Object.keys(so_dados).join(",") === "z,a,b,c"
            && JSON.stringify({...{ a: 1, b: 2 }}) === '{"a":1,"b":2}') ? "ok" : "falhou"
    `
    testing.expect_value(t, run_s(src), "ok")
}

@(test)
m220_ordem_de_chave_com_ACCESSOR_diverge_do_chrome :: proc(t: ^testing.T) {
    // ⚠️ NÃO é regressão deste marco — medido nos DOIS binários. Este motor guarda
    // getters/setters num mapa à parte, então eles são enumerados DEPOIS das
    // propriedades de dado: `{a:1, get b(){}, c:3}` dá `a,c,b` aqui e `a,b,c` no
    // Chrome. O teste trava o comportamento REAL para que a divergência apareça se
    // alguém mexer na ordem — e para não ser redescoberta como "bug novo".
    src := `Object.keys({ a: 1, get b(){ return 2 }, c: 3 }).join(",")`
    testing.expect_value(t, run_s(src), "a,c,b")
}

// DEGRADAÇÃO CONHECIDA: `Object.assign` com destino Map/Set (`^Collection`) segue
// devolvendo o alvo intacto — `set_index` não sabe escrever nessa variante. É o mesmo
// estado de antes deste marco para esse tipo, e não aparece no corpus (ninguém pendura
// propriedade avulsa num Map).
