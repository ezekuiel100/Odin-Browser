package js

import "core:testing"

// Buracos em array (bitmap Array.holes): `[1,,3]`, `new Array(n)`, `delete a[i]`,
// `a[9]=x` além do fim e `a.length = n` maior criam índices AUSENTES.
@(test)
array_holes_creation :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1,,3]; a.length===3 && !(1 in a) && Object.keys(a).join()==='0,2' && a[1]===undefined`,
        `var b=new Array(3); b.length===3 && !(0 in b) && Object.keys(b).length===0`,
        `var c=[1,2,3]; delete c[1]; c.length===3 && !(1 in c) && c.join('-')==='1--3'`,
        `var d=[]; d[5]=1; d.length===6 && !(0 in d) && Object.keys(d).join()==='5'`,
        `var e=[1]; e.length=4; !(3 in e) && e.length===4 && Object.keys(e).join()==='0'`,
        `var f=[1,,3,,]; f.length===4 && Object.keys(f).join()==='0,2'`,
        `var g=[...[1,2],,3]; g.length===4 && !(2 in g) && g[3]===3`,
        `var big=[]; big[70]=1; !(69 in big) && (70 in big) && Object.keys(big).join()==='70'`,
        // undefined ESCRITO não é buraco
        `var u=[1,undefined,3]; 1 in u && Object.keys(u).length===3`,
        `var s=[]; s[2]=1; s[0]=undefined; Object.keys(s).join()==='0,2'`,
        `var r=Array(3); for (var i=0;i<3;i++) r[i]=i===1?undefined:i; Object.keys(r).join()==='0,1,2'`,
        `var p=new Array(3); p.length=0; p.push(undefined); 0 in p && p.length===1`,
        `var k=Array(2).fill(0); Object.keys(k).join()==='0,1'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_holes_observers :: proc(t: ^testing.T) {
    cases := []string{
        `var n=0; [1,,3].forEach(function(){ n++ }); n===2`,
        `var m=[1,,3].map(function(){ return 7 }); m.length===3 && !(1 in m) && JSON.stringify(m)==='[7,null,7]'`,
        `[1,,3].filter(function(){ return true }).length===2 && [1,,3].reduce(function(s){ return s+1 },0)===2`,
        `[1,,3].indexOf(undefined)===-1 && [1,,3].includes(undefined) && [1,,3].findIndex(function(v){ return v===undefined })===1`,
        `![,].some(function(){ return true }) && [,].every(function(){ return false })`,
        `var k=[]; for (var i in [1,,3]) k.push(i); k.join()==='0,2'`,
        `var k=[]; for (var i in 'ab') k.push(i); k.join()==='0,1'`,
        `![1,,3].hasOwnProperty(1) && [1,,3].hasOwnProperty('2') && !Object.hasOwn([,1],0)`,
        `Object.getOwnPropertyDescriptor([1,,3],1)===undefined && Object.getOwnPropertyDescriptor([1,,3],0).value===1`,
        `var d=Object.getOwnPropertyDescriptor([1,2],'length'); d.value===2 && d.writable && !d.enumerable && !d.configurable`,
        `Object.keys(Object.getOwnPropertyDescriptors([5,,6])).join()==='0,2,length'`,
        `Object.values([1,,3]).join()==='1,3' && JSON.stringify(Object.entries([1,,3]))==='[["0",1],["2",3]]'`,
        // leitura densa: spread/Array.from/join/JSON veem undefined
        `Array.from(Array(2)).hasOwnProperty(0) && [...Array(2)].length===2 && Array(3).join('-')==='--'`,
        `JSON.stringify([,1])==='[null,1]' && String([,1])===',1'`,
        `Object.keys(Array(3).map(function(){ return 1 })).length===0`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_holes_structural :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[3,,1]; a.sort(); a.length===3 && Object.keys(a).join()==='0,1' && a[0]===1 && a[1]===3`,
        `var b=[1,,3,,]; b.reverse(); Object.keys(b).join()==='1,3'`,
        `var g=[1,,3]; g.shift(); Object.keys(g).join()==='1' && g.length===2`,
        `var h=[,1]; h.unshift(0); Object.keys(h).join()==='0,2'`,
        `var c=[1,,3].concat([4,,6]); c.length===6 && Object.keys(c).join()==='0,2,3,5'`,
        `var s=[]; s[70]=1; var t=s.slice(); t.length===71 && Object.keys(t).join()==='70'`,
        `[[1,,2],,[3]].flat().length===3`,
        `var x,z; [x,,z]=[1,2,3]; x===1 && z===3`,
        `var [p,,q]=[4,5,6]; p===4 && q===6`,
        `var fz=Object.freeze([1,2]), ok=false; try{ fz.pop() }catch(e){ ok=e instanceof TypeError } ok && fz.length===2`,
        // HasProperty de um Proxy passa pelo trap `has` (antes: todo índice "ausente";
        // reverse sobre length 2^53 iterava para sempre)
        `var seen=[]; var p=new Proxy({0:'a',2:'c',length:3},{has:function(t,k){ seen.push(k); return k in t }}); var n=0; Array.prototype.forEach.call(p,function(){ n++ }); n===2 && seen.join()==='0,1,2'`,
        `var Stop=function(){}; var o={0:'z', get 1(){ throw new Stop() }, length:Math.pow(2,53)}; var p=new Proxy(o,{}); var ok=false; try{ Array.prototype.reverse.call(p) }catch(e){ ok=e instanceof Stop } ok`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
