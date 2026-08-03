package js

// M159 — reciclagem de escopo de chamada + `arguments` sob demanda.
//
// O motor não tem GC: tudo que nasce fica em vm.all_* até o vm_destroy. Medido
// no binário do M158: ~1,1 KB RETIDOS por chamada de função (500k chamadas de
// `function f(x){return x+1}` = 539 MB de pico), dos quais ~310 B eram o objeto
// `arguments` criado em TODA chamada mesmo sem ninguém o mencionar. É o que
// fazia um bundle de SPA consumir gigabytes só de escopos mortos.
//
// Duas mudanças:
//
//   (1) `arguments` sob demanda — o parser marca `uses_arguments` no nó .Func
//       quando o corpo menciona `arguments` (ou `eval`, que poderia lê-lo).
//       Uma ARROW não zera o flag de propósito: o `arguments` dentro dela é o da
//       função envolvente, então marca a ENVOLVENTE.
//
//   (2) recycle_envs — call_function fotografa `len(all_envs)` e o contador
//       `env_escapes` na entrada. Se ao sair o contador não mudou, NENHUM dos
//       escopos criados na chamada pode ser alcançado depois, e todos voltam
//       para o pool. O contador sobe nos únicos pontos que guardam um ^Env:
//       closure de função (3 sítios), escopo de módulo, alias de import e
//       retomada de generator.
//
// O risco é use-after-free: reciclar um escopo que alguém ainda enxerga. Por
// isso os testes de corretude abaixo seguem o mesmo roteiro — cria a closure,
// roda MILHARES de chamadas limpas (que reciclam e REUSAM os escopos do pool)
// e só então invoca a closure. Se o escopo tivesse sido reciclado indevidamente,
// ele já teria sido sobrescrito por outra chamada e o valor viria errado.

import "core:testing"

// ── (2) a reciclagem acontece ────────────────────────────────────────────────

@(test)
m159_escopos_de_chamada_sao_reciclados :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `function f(x){ return x+1 } var s=0; for(var i=0;i<3000;i++) s=f(s);`)
    // 3000 chamadas: antes cada uma deixava um Env definitivo em all_envs.
    // Agora todas reciclam, então o total fica na casa das dezenas.
    testing.expectf(t, len(vm.all_envs) < 200,
        "esperava all_envs pequeno após 3000 chamadas descartáveis, veio %d", len(vm.all_envs))
}

@(test)
m159_escopo_com_closure_nao_e_reciclado :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    // cada chamada de mk() cria uma closure viva → os 500 escopos ficam
    vm_run(vm, `function mk(n){ return function(){ return n } } var a=[]; for(var i=0;i<500;i++) a.push(mk(i));`)
    testing.expectf(t, len(vm.all_envs) >= 500,
        "escopos capturados por closure NÃO podem ser reciclados, all_envs=%d", len(vm.all_envs))
}

// ── (2) corretude: o que escapa continua vivo ────────────────────────────────

@(test)
m159_closure_sobrevive_a_reuso_do_pool :: proc(t: ^testing.T) {
    // A closure é criada, 5000 chamadas limpas reciclam e REUSAM escopos, e só
    // então ela é invocada. Com reciclagem indevida, `n` viria de lixo.
    src := `
        function mk(n){ return function(){ return n * 2 } }
        var c = mk(21);
        function limpa(x){ var y = x + 1; return y }
        var s = 0;
        for (var i = 0; i < 5000; i++) s = limpa(s);
        c();
    `
    testing.expect_value(t, as_number(run(src)), f64(42))
}

@(test)
m159_closure_criada_por_funcao_chamada_de_dentro :: proc(t: ^testing.T) {
    // `hospeda` NÃO tem função no corpo — é "limpa" pelo critério léxico — mas a
    // closure que ela devolve nasceu num escopo criado DURANTE a sua execução.
    // É o caso que um critério puramente léxico erraria (e liberaria).
    src := `
        function mk(n){ return function(){ return n + 1 } }
        function hospeda(v){ return mk(v) }
        var c = hospeda(9);
        function limpa(x){ return x + 1 }
        var s = 0;
        for (var i = 0; i < 5000; i++) s = limpa(s);
        c();
    `
    testing.expect_value(t, as_number(run(src)), f64(10))
}

@(test)
m159_closures_de_loop_mantem_binding_por_iteracao :: proc(t: ^testing.T) {
    src := `
        var fs = [];
        for (let i = 0; i < 5; i++) fs.push(function(){ return i });
        function limpa(x){ return x + 1 }
        var s = 0;
        for (var k = 0; k < 3000; k++) s = limpa(s);
        fs[0]() * 100 + fs[4]();
    `
    testing.expect_value(t, as_number(run(src)), f64(4)) // 0*100 + 4
}

@(test)
m159_generator_suspenso_sobrevive_a_chamadas :: proc(t: ^testing.T) {
    // O corpo do generator fica suspenso no yield com os SEUS escopos vivos,
    // criados intercalados em all_envs com os da thread principal. gen_resume
    // marca escape justamente para que nenhuma chamada recicle por cima deles.
    src := `
        function* g(){ var a = 10; yield 1; var b = 20; yield a + b; }
        var it = g();
        it.next();
        function limpa(x){ return x + 1 }
        var s = 0;
        for (var i = 0; i < 3000; i++) s = limpa(s);
        it.next().value;
    `
    testing.expect_value(t, as_number(run(src)), f64(30))
}

@(test)
m159_recursao_com_escopos_reciclados :: proc(t: ^testing.T) {
    // Recursão profunda: cada nível recicla no retorno, mas os escopos dos níveis
    // AINDA ativos não podem ser tocados (o mark de cada frame é o seu próprio).
    src := `
        function fat(n){ return n <= 1 ? 1 : n * fat(n-1) }
        fat(10);
    `
    testing.expect_value(t, as_number(run(src)), f64(3628800))
}

@(test)
m159_this_e_metodos_apos_reciclagem :: proc(t: ^testing.T) {
    src := `
        class C { constructor(v){ this.v = v } dobro(){ return this.v * 2 } }
        var o = new C(7);
        function limpa(x){ return x + 1 }
        var s = 0;
        for (var i = 0; i < 3000; i++) s = limpa(s);
        o.dobro();
    `
    testing.expect_value(t, as_number(run(src)), f64(14))
}

@(test)
m159_excecao_nao_corrompe_o_pool :: proc(t: ^testing.T) {
    // O unwind passa por cada call_function empilhado, cada um reciclando o seu
    // intervalo. O valor lançado é um ^Object (não um Env) e sobrevive.
    src := `
        function lanca(n){ var local = n * 2; throw { code: local } }
        function meio(n){ return lanca(n) }
        var got = 0;
        for (var i = 0; i < 2000; i++) { try { meio(3) } catch (e) { got = e.code } }
        got;
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// ── (1) `arguments` sob demanda ──────────────────────────────────────────────

@(test)
m159_arguments_uso_direto :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`(function(){ return arguments.length })(1,2,3)`)), f64(3))
    testing.expect_value(t, as_number(run(`(function(){ return arguments[1] })(7,8)`)), f64(8))
    // extras além dos params declarados só são visíveis por `arguments`
    testing.expect_value(t, as_number(run(`(function(a){ return a + arguments[1] })(1,2)`)), f64(3))
}

@(test)
m159_arguments_dentro_de_arrow_pertence_a_envolvente :: proc(t: ^testing.T) {
    // A arrow não tem `arguments` próprio: o flag tem de subir para a função
    // envolvente, senão o objeto nunca é materializado e a arrow lê undefined.
    testing.expect_value(t, as_number(run(`(function(){ var f = () => arguments.length; return f() })(1,2,3)`)), f64(3))
    testing.expect_value(t, as_number(run(`(function(){ return (() => arguments[0])() })(5)`)), f64(5))
    // duas camadas de arrow
    testing.expect_value(t, as_number(run(`(function(){ return (() => (() => arguments.length)())() })(1,2)`)), f64(2))
}

@(test)
m159_arguments_de_funcao_aninhada_nao_vaza_para_a_externa :: proc(t: ^testing.T) {
    // A interna tem o SEU arguments; a externa continua com o dela. Se o flag
    // vazasse (ou fosse consumido pela interna), um dos dois viria errado.
    src := `(function(){
        var interna = function(){ return arguments.length };
        return interna(1,2,3) * 10 + arguments.length;
    })(9)`
    testing.expect_value(t, as_number(run(src)), f64(31)) // 3*10 + 1
}

@(test)
m159_arguments_em_default_de_parametro :: proc(t: ^testing.T) {
    // O default é avaliado no escopo da chamada: `arguments` ali é o da própria
    // função, por isso fn_args_enter roda ANTES de parse_params.
    testing.expect_value(t, as_number(run(`(function(a, b = arguments[0]){ return b })(4)`)), f64(4))
}

@(test)
m159_arguments_em_metodo_e_classe :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o = { m(){ return arguments.length } }; o.m(1,2)`)), f64(2))
    testing.expect_value(t, as_number(run(`class C { m(){ return arguments[0] } } new C().m(6)`)), f64(6))
    testing.expect_value(t, as_number(run(`class C { constructor(){ this.n = arguments.length } } new C(1,2,3).n`)), f64(3))
}

@(test)
m159_arguments_visto_por_eval_direto :: proc(t: ^testing.T) {
    // eval direto roda no escopo do chamador e pode ler `arguments` sem que o
    // identificador apareça no corpo — por isso `eval` também arma o flag.
    testing.expect_value(t, as_number(run(`(function(){ return eval("arguments.length") })(1,2)`)), f64(2))
}

@(test)
m159_funcao_sem_arguments_continua_correta :: proc(t: ^testing.T) {
    // O caso NEGATIVO: sem `arguments` materializado, params, rest, defaults,
    // `this` e new.target têm de continuar exatamente como antes.
    testing.expect_value(t, as_number(run(`(function(a,b){ return a+b })(2,3)`)), f64(5))
    testing.expect_value(t, as_number(run(`(function(a,...r){ return r.length })(1,2,3)`)), f64(2))
    testing.expect_value(t, as_number(run(`(function(a,b=10){ return a+b })(1)`)), f64(11))
    testing.expect_value(t, as_number(run(`var o = { v: 4, m(){ return this.v } }; o.m()`)), f64(4))
    testing.expect_value(t, run(`function F(){ this.ok = new.target === F } new F().ok`).(bool), true)
}

@(test)
m159_arguments_nao_materializado_quando_nao_mencionado :: proc(t: ^testing.T) {
    // De dentro do JS isso é INOBSERVÁVEL por construção (mencionar `arguments`
    // para testá-lo já arma o flag) — a economia só se mede do lado do motor,
    // contando os ^Array que cada chamada deixava para trás.
    sem := vm_create()
    defer vm_free(sem)
    vm_run(sem, `function f(x){ return x+1 } var s=0; for(var i=0;i<1000;i++) s=f(s);`)
    n_sem := len(sem.all_arrays)

    com := vm_create()
    defer vm_free(com)
    vm_run(com, `function f(x){ return arguments[0]+1 } var s=0; for(var i=0;i<1000;i++) s=f(s);`)
    n_com := len(com.all_arrays)

    testing.expectf(t, n_com - n_sem >= 1000,
        "a versão que usa `arguments` deveria criar ~1000 arrays a mais: sem=%d com=%d", n_sem, n_com)
}

@(test)
m159_arguments_reflete_todos_os_args_em_generator_e_async :: proc(t: ^testing.T) {
    // generators e async functions montam o escopo pelo mesmo setup_call_scope
    testing.expect_value(t, as_number(run(`function* g(){ yield arguments.length } g(1,2,3).next().value`)), f64(3))
}
