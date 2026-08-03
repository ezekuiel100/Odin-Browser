package js

import "core:testing"

// Change Array by Copy (ES2023): toReversed / toSorted / toSpliced / with.
//
// `toSorted` foi o que quebrou o x.com (`n.filter(...).map(...).toSorted is not
// a function`). Os quatro vieram na MESMA proposta e aparecem em cadeia no
// código de página, por isso entram juntos.
//
// ⚠️ O que cada teste tem de provar é a palavra "COPY": o receptor NÃO muda.
// Um teste que só olhasse o retorno passaria com uma implementação que muta —
// que é precisamente o bug que estes métodos existem para evitar.

@(test)
to_sorted_ordena_sem_mutar :: proc(t: ^testing.T) {
    r := run(`
        var a = [3, 1, 2];
        var b = a.toSorted();
        b.join() === '1,2,3' && a.join() === '3,1,2'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toSorted devolve ordenado e deixa o original INTACTO")
}

@(test)
to_sorted_usa_o_comparador :: proc(t: ^testing.T) {
    // Sem comparador, JS ordena como STRING: [10,9,1] → 1,10,9. Este caso
    // afirma as DUAS coisas, senão "ordenou" seria ambíguo.
    r := run(`
        var a = [10, 9, 1];
        var padrao = a.toSorted().join();
        var num    = a.toSorted(function(x, y){ return x - y; }).join();
        padrao === '1,10,9' && num === '1,9,10' && a.join() === '10,9,1'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toSorted: default é comparação de string; comparador numérico funciona")
}

@(test)
to_reversed_inverte_sem_mutar :: proc(t: ^testing.T) {
    r := run(`
        var a = [1, 2, 3];
        var b = a.toReversed();
        b.join() === '3,2,1' && a.join() === '1,2,3'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toReversed não muta o original")
}

@(test)
to_spliced_devolve_o_novo_nao_os_removidos :: proc(t: ^testing.T) {
    // ⚠️ a diferença fácil de errar: splice devolve os REMOVIDOS, toSpliced
    // devolve o array NOVO. Este caso mede as duas na mesma entrada.
    r := run(`
        var a = [1, 2, 3, 4];
        var novo = a.toSpliced(1, 2, 'x');
        var b = [1, 2, 3, 4];
        var removidos = b.splice(1, 2, 'x');
        novo.join() === '1,x,4' &&
        removidos.join() === '2,3' &&
        a.join() === '1,2,3,4' &&
        b.join() === '1,x,4'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toSpliced devolve o NOVO array; splice devolve os removidos e muta")
}

@(test)
with_troca_um_indice :: proc(t: ^testing.T) {
    r := run(`
        var a = [1, 2, 3];
        var b = a.with(1, 'x');
        var c = a.with(-1, 'z');   // índice negativo conta do fim
        b.join() === '1,x,3' && c.join() === '1,2,z' && a.join() === '1,2,3'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "with troca um índice (aceita negativo) sem mutar")
}

@(test)
with_fora_do_range_lanca_range_error :: proc(t: ^testing.T) {
    // Silêncio aqui seria pior que o erro: `arr[99]=v` não reclama, e é
    // justamente disso que o `with` difere.
    r := run(`
        var e = '';
        try { [1,2,3].with(99, 'x'); } catch (x) { e = x.name; }
        e
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "RangeError", "índice fora do range lança RangeError; veio %q", s)
}

@(test)
copy_methods_sao_genericos_em_array_like :: proc(t: ^testing.T) {
    // A spec faz estes métodos genéricos sobre array-like, e o `slice` daqui já
    // era. Sem isto, `Array.prototype.toSorted.call(arguments, ...)` quebraria.
    r := run(`
        var al = { length: 3, 0: 'c', 1: 'a', 2: 'b' };
        Array.prototype.toSorted.call(al).join() === 'a,b,c' &&
        Array.prototype.toReversed.call(al).join() === 'b,a,c'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toSorted/toReversed funcionam sobre array-like")
}

@(test)
cadeia_do_x_com_nao_lanca :: proc(t: ^testing.T) {
    // A forma exata que quebrava: filter → map → toSorted encadeados.
    r := run(`
        var n = [{v:3},{v:1},{v:2},{v:0}];
        n.filter(function(o){ return o.v > 0; })
         .map(function(o){ return o.v; })
         .toSorted(function(x,y){ return x - y; })
         .join()
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "1,2,3", "filter().map().toSorted() encadeia; veio %q", s)
}
