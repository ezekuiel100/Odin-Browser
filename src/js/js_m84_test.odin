package js

import "core:testing"

// ── M84: flags de regex `s` (dotAll) e `y` (sticky) ──────────────────────────
// Gaps abertos do roteiro. `s` faz `.` casar `\n` (comum em regex multi-linha);
// `y` ancora o casamento em lastIndex sem varrer adiante (lexers/tokenizers de
// bundlers usam muito, ex.: regex de tokens gerados por parser-generators).

// ── dotAll (s) ────────────────────────────────────────────────────────────────

// Sem s, `.` não casa `\n`; com s, casa.
@(test)
test_dotall_basico :: proc(t: ^testing.T) {
    testing.expect(t, !truthy(run(`/a.b/.test("a\nb")`)), "sem flag s, `.` não deve casar newline")
    testing.expect(t,  truthy(run(`/a.b/s.test("a\nb")`)), "com flag s, `.` deve casar newline")
}

// `.` com s casa qualquer char, inclusive newline, dentro de captura.
@(test)
test_dotall_captura :: proc(t: ^testing.T) {
    src := `var m = /a(.)c/s.exec("a\nc"); m[1] === "\n"`
    testing.expect(t, truthy(run(src)), "captura com `.` sob flag s deve pegar o newline")
}

// match multi-linha: `/<.+>/s` atravessa linhas (uso clássico de dotAll).
@(test)
test_dotall_multilinha :: proc(t: ^testing.T) {
    src := `
        var txt = "<p>\nlinha1\nlinha2\n</p>";
        var m = txt.match(/<p>(.+)<\/p>/s);
        m !== null && m[1].indexOf("linha1") >= 0 && m[1].indexOf("linha2") >= 0
    `
    testing.expect(t, truthy(run(src)), "/<p>(.+)</p>/s deve casar atravessando newlines")
}

// propriedade .dotAll reflete a flag.
@(test)
test_dotall_propriedade :: proc(t: ^testing.T) {
    testing.expect(t,  truthy(run(`/x/s.dotAll`)),  ".dotAll deve ser true com a flag s")
    testing.expect(t, !truthy(run(`/x/.dotAll`)),   ".dotAll deve ser false sem a flag s")
}

// ── sticky (y) ────────────────────────────────────────────────────────────────

// exec sticky casa SÓ na posição lastIndex, avançando-o em cada sucesso.
@(test)
test_sticky_exec_ancora :: proc(t: ^testing.T) {
    src := `
        var re = /\w+/y;
        var s = "foo bar";
        re.lastIndex = 0;
        var m1 = re.exec(s);         // "foo", lastIndex -> 3
        var li = re.lastIndex;
        var m2 = re.exec(s);         // pos 3 é espaço: \w+ não casa ali -> null, lastIndex -> 0
        m1[0] + ':' + li + ':' + (m2 === null ? 'null' : m2[0]) + ':' + re.lastIndex
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "foo:3:null:0", "sticky deve ancorar em lastIndex e resetar em falha")
}

// sticky casa quando lastIndex aponta exatamente para o casamento.
@(test)
test_sticky_lastindex_alvo :: proc(t: ^testing.T) {
    src := `
        var re = /bar/y;
        re.lastIndex = 4;
        re.test("foo bar") + ':' + re.lastIndex
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:7", "sticky em lastIndex=4 deve casar 'bar' e avançar p/ 7")
}

// sticky NÃO varre adiante: casamento existe mas não na posição -> falha.
@(test)
test_sticky_nao_varre :: proc(t: ^testing.T) {
    src := `
        var re = /bar/y;
        re.lastIndex = 0;            // 'bar' está em 4, não em 0
        re.test("foo bar")
    `
    testing.expect(t, !truthy(run(src)), "sticky não deve varrer adiante a partir de lastIndex")
}

// propriedade .sticky reflete a flag.
@(test)
test_sticky_propriedade :: proc(t: ^testing.T) {
    testing.expect(t,  truthy(run(`/x/y.sticky`)), ".sticky deve ser true com a flag y")
    testing.expect(t, !truthy(run(`/x/.sticky`)),  ".sticky deve ser false sem a flag y")
}

// tokenização real: loop de exec sticky varre tokens consecutivos.
@(test)
test_sticky_tokenizer :: proc(t: ^testing.T) {
    src := `
        var re = /(\d+)|(\+)/y;
        var s = "12+34+5";
        var out = [];
        var m;
        while (re.lastIndex < s.length && (m = re.exec(s)) !== null) {
            out.push(m[0]);
        }
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "12,+,34,+,5", "loop de exec sticky deve emitir os tokens em ordem")
}

// flags string carrega s e y.
@(test)
test_flags_string_sy :: proc(t: ^testing.T) {
    v, _ := run(`/x/sy.flags`).(string)
    testing.expect(t, v == "sy", ".flags deve conter 's' e 'y'")
}

// new RegExp com flags s e y compila e funciona.
@(test)
test_new_regexp_sy :: proc(t: ^testing.T) {
    src := `
        var re = new RegExp("a.b", "s");
        re.dotAll + ':' + re.test("a\nb")
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:true", "new RegExp(pat, 's') deve ativar dotAll")
}

// ── TypedArray.prototype.sort ────────────────────────────────────────────────

// default é NUMÉRICO (Array.sort seria por string: [1,10,9]).
@(test)
test_ta_sort_numerico :: proc(t: ^testing.T) {
    v, _ := run(`new Uint8Array([10,9,1]).sort().join(',')`).(string)
    testing.expect(t, v == "1,9,10", "TypedArray.sort deve ordenar numericamente (não por string)")
}

// ordena in-place e devolve o MESMO objeto.
@(test)
test_ta_sort_inplace :: proc(t: ^testing.T) {
    src := `
        var a = new Int16Array([3,1,2]);
        var b = a.sort();
        (a === b) + ':' + a.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:1,2,3", "sort deve ser in-place e devolver this")
}

// comparador decrescente.
@(test)
test_ta_sort_comparador :: proc(t: ^testing.T) {
    v, _ := run(`new Float64Array([1,3,2,5,4]).sort(function(a,b){return b-a}).join(',')`).(string)
    testing.expect(t, v == "5,4,3,2,1", "sort com comparador deve respeitar a ordem dada")
}

// NaN vai para o fim (só floats têm NaN).
@(test)
test_ta_sort_nan_ao_fim :: proc(t: ^testing.T) {
    src := `
        var a = new Float64Array([3, NaN, 1, NaN, 2]);
        a.sort();
        a[0] + ',' + a[1] + ',' + a[2] + ',' + (a[3] !== a[3]) + ',' + (a[4] !== a[4])
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2,3,true,true", "NaN deve ser ordenado para o fim")
}

// ── structuredClone ──────────────────────────────────────────────────────────

// clona objeto profundamente e é INDEPENDENTE do original.
@(test)
test_sclone_objeto_independente :: proc(t: ^testing.T) {
    src := `
        var o = { a: 1, b: { c: 2 } };
        var d = structuredClone(o);
        d.b.c = 99;
        (o.b.c) + ':' + (d.b.c) + ':' + (o !== d) + ':' + (o.b !== d.b)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "2:99:true:true", "structuredClone deve ser cópia profunda independente")
}

// array aninhado.
@(test)
test_sclone_array :: proc(t: ^testing.T) {
    src := `
        var a = [1, [2, 3], 4];
        var b = structuredClone(a);
        b[1][0] = 9;
        a[1][0] + ':' + b[1][0] + ':' + b.length
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "2:9:3", "clone de array aninhado deve ser independente")
}

// Map e Set.
@(test)
test_sclone_map_set :: proc(t: ^testing.T) {
    src := `
        var m = new Map([['x',1],['y',2]]);
        var m2 = structuredClone(m);
        m2.set('x', 100);
        var s = new Set([1,2,3]);
        var s2 = structuredClone(s);
        m.get('x') + ':' + m2.get('x') + ':' + m2.get('y') + ':' + (s2.has(2)) + ':' + s2.size
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1:100:2:true:3", "clone de Map/Set deve copiar as entradas")
}

// Date preserva o instante mas é outro objeto.
@(test)
test_sclone_date :: proc(t: ^testing.T) {
    src := `
        var d = new Date(1234567890000);
        var c = structuredClone(d);
        (c.getTime() === d.getTime()) + ':' + (c !== d)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:true", "clone de Date preserva o tempo e é outro objeto")
}

// referência compartilhada preservada (o mesmo sub-objeto vira o mesmo clone).
@(test)
test_sclone_ref_compartilhada :: proc(t: ^testing.T) {
    src := `
        var shared = { n: 1 };
        var o = { a: shared, b: shared };
        var d = structuredClone(o);
        (d.a === d.b) + ':' + (d.a !== shared)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:true", "referências compartilhadas devem virar o mesmo clone")
}

// ciclo é preservado (sem loop infinito).
@(test)
test_sclone_ciclo :: proc(t: ^testing.T) {
    src := `
        var o = { name: 'x' };
        o.self = o;
        var d = structuredClone(o);
        (d.self === d) + ':' + (d.self.name) + ':' + (d !== o)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:x:true", "ciclo deve ser preservado sem recursão infinita")
}

// função não é clonável → DataCloneError.
@(test)
test_sclone_funcao_lanca :: proc(t: ^testing.T) {
    src := `
        var erro = '';
        try { structuredClone(function(){}); }
        catch (e) { erro = e.name; }
        erro
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "DataCloneError", "clonar função deve lançar DataCloneError")
}

// TypedArray clonado é independente do original.
@(test)
test_sclone_typedarray :: proc(t: ^testing.T) {
    src := `
        var a = new Uint8Array([1,2,3]);
        var b = structuredClone(a);
        b[0] = 9;
        a[0] + ':' + b[0] + ':' + b.length + ':' + (b instanceof Uint8Array)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1:9:3:true", "TypedArray clonado deve ser independente e do mesmo tipo")
}

// ── new.target ───────────────────────────────────────────────────────────────

// sob `new`, new.target é o construtor.
@(test)
test_new_target_com_new :: proc(t: ^testing.T) {
    src := `
        var c;
        function F(){ c = new.target; }
        new F();
        c === F
    `
    testing.expect(t, truthy(run(src)), "new.target deve ser o construtor sob `new`")
}

// chamada normal: new.target é undefined.
@(test)
test_new_target_sem_new :: proc(t: ^testing.T) {
    src := `
        var c = 'x';
        function F(){ c = new.target; }
        F();
        c === undefined
    `
    testing.expect(t, truthy(run(src)), "new.target deve ser undefined em chamada normal")
}

// idioma do guard: `if (!new.target) throw ...`.
@(test)
test_new_target_guard :: proc(t: ^testing.T) {
    src := `
        function F(){ if (!new.target) throw new Error('need new'); this.x = 1; }
        var ok = (new F()).x;
        var threw = false;
        try { F(); } catch(e) { threw = true; }
        ok + ':' + threw
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1:true", "guard com new.target deve permitir `new` e barrar chamada normal")
}

// arrow herda new.target léxico da função envolvente.
@(test)
test_new_target_arrow_lexico :: proc(t: ^testing.T) {
    src := `
        var c;
        function F(){ var g = () => { c = new.target; }; g(); }
        new F();
        c === F
    `
    testing.expect(t, truthy(run(src)), "arrow deve herdar new.target da função envolvente")
}

// chamada NORMAL aninhada dentro de um construtor vê new.target = undefined.
@(test)
test_new_target_normal_aninhada :: proc(t: ^testing.T) {
    src := `
        var inner = 'x';
        function helper(){ inner = new.target; }
        function F(){ helper(); }
        new F();
        inner === undefined
    `
    testing.expect(t, truthy(run(src)), "chamada normal dentro de construtor deve ter new.target undefined")
}

// classe: new.target no constructor é a classe.
@(test)
test_new_target_classe :: proc(t: ^testing.T) {
    src := `
        class C { constructor(){ this.t = new.target; } }
        new C().t === C
    `
    testing.expect(t, truthy(run(src)), "new.target no constructor de classe deve ser a classe")
}

// ── destructuring de iterável (não-array) ────────────────────────────────────

// desestrutura um Set posicionalmente.
@(test)
test_destr_set :: proc(t: ^testing.T) {
    src := `var [a,b,c] = new Set([10,20,30]); a + ':' + b + ':' + c`
    v, _ := run(src).(string)
    testing.expect(t, v == "10:20:30", "destructuring de Set deve dar os elementos em ordem")
}

// desestrutura pares de um Map (aninhado).
@(test)
test_destr_map_pares :: proc(t: ^testing.T) {
    src := `var [[k,val]] = new Map([['x',1],['y',2]]); k + ':' + val`
    v, _ := run(src).(string)
    testing.expect(t, v == "x:1", "destructuring de Map deve dar pares [chave,valor]")
}

// desestrutura um generator.
@(test)
test_destr_generator :: proc(t: ^testing.T) {
    src := `
        function* g(){ yield 5; yield 6; yield 7; }
        var [a,b] = g();
        a + ':' + b
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "5:6", "destructuring de generator deve puxar os primeiros valores")
}

// rest sobre um Set.
@(test)
test_destr_set_rest :: proc(t: ^testing.T) {
    src := `
        var [first, ...rest] = new Set([1,2,3,4]);
        first + ':' + rest.length + ':' + rest[0] + ':' + rest[2]
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1:3:2:4", "rest deve recolher o restante de um iterável")
}

// destructuring de iterável em parâmetro de função.
@(test)
test_destr_set_param :: proc(t: ^testing.T) {
    src := `
        function soma([a,b,c]){ return a+b+c; }
        soma(new Set([3,4,5]))
    `
    testing.expect_value(t, as_number(run(src)), f64(12))
}

// default aplica quando o iterável esgota.
@(test)
test_destr_iteravel_default :: proc(t: ^testing.T) {
    src := `var [a, b = 99] = new Set([7]); a + ':' + b`
    v, _ := run(src).(string)
    testing.expect(t, v == "7:99", "default deve entrar quando o iterável não tem o elemento")
}

// forma-expressão (sem declaração) também materializa.
@(test)
test_destr_iteravel_expr :: proc(t: ^testing.T) {
    src := `var a, b; [a, b] = new Set([8, 9]); a * 10 + b`
    testing.expect_value(t, as_number(run(src)), f64(89))
}

// ── brand check de campo privado (#x in obj) ─────────────────────────────────

// true para instância da classe, false para objeto alheio e para primitivo.
@(test)
test_private_in_basico :: proc(t: ^testing.T) {
    src := `
        class C {
            #x = 1;
            static check(o){ return (#x in o); }
        }
        var c = new C();
        C.check(c) + ':' + C.check({}) + ':' + C.check(5)
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:false:false", "#x in obj deve ser true só p/ instâncias com o slot")
}

// método privado também é detectável por brand check.
@(test)
test_private_in_metodo :: proc(t: ^testing.T) {
    src := `
        class C {
            #m(){ return 1; }
            static check(o){ return #m in o; }
        }
        C.check(new C()) + ':' + C.check({})
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "true:false", "#m in obj deve detectar método privado")
}

// idioma transpilado: brand check guardando acesso privado.
@(test)
test_private_in_guard :: proc(t: ^testing.T) {
    src := `
        class Box {
            #v = 7;
            static peek(o){ return (#v in o) ? o.#v : -1; }
        }
        var b = new Box();
        Box.peek(b) + ':' + Box.peek({})
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "7:-1", "brand check deve guardar acesso a campo privado com segurança")
}

// ── static blocks ────────────────────────────────────────────────────────────

// bloco static roda na definição da classe, com this = a classe.
@(test)
test_static_block_basico :: proc(t: ^testing.T) {
    src := `
        class C { static x; static { C.x = 42; } }
        C.x
    `
    testing.expect_value(t, as_number(run(src)), f64(42))
}

// `this` dentro do bloco é a própria classe.
@(test)
test_static_block_this :: proc(t: ^testing.T) {
    src := `
        class C { static { this.tag = 'hi'; } }
        C.tag
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "hi", "this no bloco static deve ser a classe")
}

// ordem de fonte: bloco vê campos static anteriores.
@(test)
test_static_block_ordem :: proc(t: ^testing.T) {
    src := `
        class C { static a = 1; static b; static { C.b = C.a + 5; } }
        C.b
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// múltiplos blocos rodam em ordem.
@(test)
test_static_block_multiplos :: proc(t: ^testing.T) {
    src := `
        class C {
            static log = [];
            static { C.log.push(1); }
            static { C.log.push(2); }
        }
        C.log.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2", "múltiplos blocos static devem rodar em ordem de fonte")
}

// bloco static pode acessar membro privado static.
@(test)
test_static_block_privado :: proc(t: ^testing.T) {
    src := `
        class C {
            static #n = 1;
            static val;
            static { C.val = C.#n + 10; }
        }
        C.val
    `
    testing.expect_value(t, as_number(run(src)), f64(11))
}
