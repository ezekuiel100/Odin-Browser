package js

import "core:testing"

@(test)
array_symbols_symbols :: proc(t: ^testing.T) {
    cases := []string{
        `var species=Symbol.species; Symbol.species=7; Symbol.species===species && Object.keys(Symbol).indexOf('species')===-1`,
        `function F(){} Object.defineProperty(F,'x',{value:1}); Object.keys(F).indexOf('x')===-1 && !F.propertyIsEnumerable('x')`,
        `var ok=false; try{Object.defineProperty(Symbol,'isConcatSpreadable',{value:7})}catch(e){ok=e instanceof TypeError} ok`,

        `var d=Object.getOwnPropertyDescriptor(Array,Symbol.species); d.enumerable===false && d.configurable===true && d.set===undefined`,
        `var d=Object.getOwnPropertyDescriptor(Symbol,'species'); !d.writable && !d.enumerable && !d.configurable`,
        `Object.defineProperty(Array,Symbol.species,{value:null}); [1,2].slice().join()==='1,2'`,
        `function R(n){this.length=n} Object.defineProperty(Array,Symbol.species,{value:R}); var r=[1].map(function(x){return x+1}); r instanceof R && r[0]===2 && r.length===1`,
        `var a=[1,2]; function R(){} a.constructor={}; a.constructor[Symbol.species]=R; var r=a.splice(1,1); r instanceof R && r[0]===2 && r.length===1 && a.join()==='1'`,
        `var a=[1]; function R(){} a.constructor={}; a.constructor[Symbol.species]=R; var r=a.concat(2); r instanceof R && r[0]===1 && r[1]===2 && r.length===2`,
        `var a=[1]; var log=''; a.constructor={}; Object.defineProperty(a.constructor,Symbol.species,{get:function(){log+='s'; return Array}}); Object.defineProperty(Array.prototype,Symbol.isConcatSpreadable,{get:function(){log+='c';return true}}); a.concat(); log==='sc'`,

        `typeof Symbol.species==='symbol' && typeof Symbol.isConcatSpreadable==='symbol' && Symbol.species!==Symbol.isConcatSpreadable`,
        `Array[Symbol.species]===Array && classTest() ; function classTest(){ class A extends Array {} return A[Symbol.species]===A }`,
        `var d=Object.getOwnPropertyDescriptor(Array,Symbol.species); typeof d.get==='function' && d.set===undefined && d.get.call(Object)===Object`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_symbols_subclasses :: proc(t: ^testing.T) {
    cases := []string{
        `class A extends Array {} var a=new A(1,2); var r=a.map(function(x){return x*2}); r instanceof A && Array.isArray(r) && r.join()==='2,4'`,
        `class A extends Array {} var a=new A(1,2); var r=a.filter(function(x){return x>1}); r instanceof A && Array.isArray(r) && r.join()==='2'`,
        `class A extends Array {} var a=new A(1,2); var r=a.slice(1); r instanceof A && Array.isArray(r) && r.join()==='2'`,
        `class A extends Array {} var a=new A(1,2); var r=a.concat(3); r instanceof A && Array.isArray(r) && r.join()==='1,2,3'`,
        `class A extends Array {} var a=new A(1,2); var r=a.flat(); r instanceof A && Array.isArray(r) && r.join()==='1,2'`,
        `class A extends Array {} var a=new A(1,2); var r=a.flatMap(function(x){return [x,x]}); r instanceof A && Array.isArray(r) && r.join()==='1,1,2,2'`,
        `class A extends Array {} var a=new A(1,2); var r=a.splice(0,1); r instanceof A && Array.isArray(r) && r.join()==='1'`,
        `class A extends Array {} var a=new A(1,2); var same=true; a.map(function(v,i,s){same=same&&s===a}); same && a.reverse()===a && a.join()==='2,1'`,
        `class A extends Array {} var a=new A(1,2); a.push(3); a.length===3 && a.pop()===3 && a.length===2`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_symbols_custom :: proc(t: ^testing.T) {
    cases := []string{
        `function R(n){this.size=n} var a=[1,2]; a.constructor={}; a.constructor[Symbol.species]=R; var r=a.map(function(x){return x*2}); r instanceof R && r.size===2 && r[0]===2 && r[1]===4 && r.length===undefined`,
        `class A extends Array { static get [Symbol.species](){return Array} } var a=new A(1,2); var r=a.map(function(x){return x}); Array.isArray(r) && !(r instanceof A) && r.join()==='1,2'`,
        `class A extends Array { static get [Symbol.species](){return null} } var r=new A(1,2).slice(); Array.isArray(r) && !(r instanceof A)`,
        `var a=[1]; a.constructor=null; var ok=false; try{a.slice()}catch(e){ok=e instanceof TypeError} ok`,
        `var a=[1]; a.constructor={}; a.constructor[Symbol.species]=()=>({}); var ok=false; try{a.map(function(x){return x})}catch(e){ok=e instanceof TypeError} ok`,
        `var a=[1]; var n=0; a.constructor={}; Object.defineProperty(a.constructor,Symbol.species,{get:function(){throw 7}}); var ok=false; try{a.map(function(){n++})}catch(e){ok=e===7} ok && n===0`,
        `var o={0:1,length:1}; Object.defineProperty(o,'constructor',{get:function(){throw 7}}); Array.prototype.map.call(o,function(x){return x})[0]===1`,
        `function R(){return Object.freeze({})} var a=[1]; a.constructor={}; a.constructor[Symbol.species]=R; var ok=false; try{a.filter(function(){return true})}catch(e){ok=e instanceof TypeError} ok`,
        `var n=0; function R(){} Object.defineProperty(R.prototype,'0',{set:function(){n++}}); var a=[1]; a.constructor={}; a.constructor[Symbol.species]=R; var r=a.map(function(x){return x}); n===0 && r.hasOwnProperty('0') && r[0]===1`,
        `var a=[1,2]; a.constructor={}; Object.defineProperty(a.constructor,Symbol.species,{get:function(){throw 7}}); a.toReversed().join()==='2,1' && a.toSorted().join()==='1,2' && a.with(0,9)[0]===9 && a.toSpliced().length===2`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_symbols_spread :: proc(t: ^testing.T) {
    cases := []string{
        `var b=[2,3]; b[Symbol.isConcatSpreadable]=false; var r=[1].concat(b); r.length===2 && r[1]===b`,
        `var o={0:'a',1:'b',length:2}; o[Symbol.isConcatSpreadable]=true; [1].concat(o).join()==='1,a,b'`,
        `var o={0:2,length:1}; o[Symbol.isConcatSpreadable]=true; Array.prototype.concat.call(o,3).join()==='2,3'`,
        `var o={0:2,length:1}; o[Symbol.isConcatSpreadable]=false; var r=Array.prototype.concat.call(o); r.length===1 && r[0]===o`,
        `var p={}; p[Symbol.isConcatSpreadable]=true; var o=Object.create(p); o.length=2; o[1]=3; var r=[].concat(o); r.length===2 && r[1]===3`,
        `var o={length:1}; Object.defineProperty(o,Symbol.isConcatSpreadable,{get:function(){throw 7}}); var ok=false; try{[].concat(o)}catch(e){ok=e===7} ok`,
        `var log=''; var o={}; Object.defineProperty(o,Symbol.isConcatSpreadable,{get:function(){log+='s';return true}}); Object.defineProperty(o,'length',{get:function(){log+='l';return 1}}); Object.defineProperty(o,'0',{get:function(){log+='i';return 4}}); var r=[].concat(o); log==='sli' && r[0]===4`,
        `var o={}; o[Symbol.isConcatSpreadable]=true; Object.defineProperty(o,'length',{get:function(){throw 7}}); var ok=false; try{[].concat(o)}catch(e){ok=e===7} ok`,
        `var a=[1]; a[Symbol.isConcatSpreadable]=undefined; a.concat([2]).join()==='1,2'`,
        `var a=[1,2]; a[Symbol.isConcatSpreadable]=false; var r=a.concat(3); r[0]===a && r[1]===3`,
        `var o={0:9,length:1}; o[Symbol.isConcatSpreadable]=true; [o].flat()[0]===o && [o].flatMap(function(x){return x})[0]===o`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
