package js

import "core:testing"

// `arr.length = N` (ArraySetLength). Antes a escrita era ignorada: `buf.length = 0`
// não limpava nada e `length = N` não estendia.
@(test)
array_length_assign :: proc(t: ^testing.T) {
    cases := []string{
        // truncar
        `var a=[1,2,3]; a.length=0; a.length===0 && a[0]===undefined && a.join()===''`,
        `var a=[1,2,3,4]; a.length=2; a.join()==='1,2' && !(2 in a)`,
        `var a=[1,2,3]; a.length=1; a.push(9); a.join()==='1,9'`,
        // estender (sem buracos no motor: os novos slots leem undefined)
        `var a=[1]; a.length=3; a.length===3 && a[2]===undefined && a[0]===1`,
        `var a=[1,2]; a.length=2; a.join()==='1,2'`,
        // por chave computada e por Reflect.set
        `var a=[1,2,3]; a['length']=1; a.length===1`,
        `var a=[1,2,3]; Reflect.set(a,'length',0); a.length===0`,
        // coerção: string numérica e valueOf (chamado DUAS vezes, como na spec)
        `var a=[1,2,3]; a.length='1'; a.length===1`,
        `var n=0; var a=[1,2,3]; a.length={valueOf:function(){n++; return 2}}; a.length===2 && n===2`,
        // comprimento inválido → RangeError, array intacto
        `var r=[-1, 1.5, NaN, 4294967296, 'x'].map(function(v){ var a=[1,2]; try{ a.length=v; return 'no' }catch(e){ return (e instanceof RangeError) && a.length===2 } }); r.join()==='true,true,true,true,true'`,
        // freeze/seal: escrita ignorada (sloppy)
        `var a=Object.freeze([1,2,3]); a.length=0; a.length===3`,
        `var a=Object.seal([1,2,3]); a.length=1; a.length===3`,
        // subclasse de Array
        `class X extends Array {} var x=new X(); x.push(1,2,3); x.length=1; x.length===1 && x[0]===1 && x[1]===undefined`,
        // idioma de reuso de buffer dentro de método
        `var q={items:[1,2,3], clear:function(){ this.items.length=0 }}; q.clear(); q.items.length===0`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
