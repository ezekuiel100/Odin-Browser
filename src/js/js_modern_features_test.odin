package js

import "core:testing"

@(test)
modern_set_operations :: proc(t: ^testing.T) {
    cases := []string{
        `var a=new Set([3,1,2]),b=new Set([2,4]); Array.from(a.union(b)).join()==='3,1,2,4' && a.size===3`,
        `var a=new Set([3,1,2]),b=new Set([2,3]); Array.from(a.intersection(b)).join()==='2,3'`,
        `var a=new Set([3,1]),b=new Set([1,3,4]); Array.from(a.intersection(b)).join()==='3,1'`,
        `Array.from(new Set([3,1,2]).difference(new Set([2,4]))).join()==='3,1'`,
        `Array.from(new Set([3,1,2]).symmetricDifference(new Set([2,4]))).join()==='3,1,4'`,
        `new Set([1]).isSubsetOf(new Set([2,1])) && !new Set([1,3]).isSubsetOf(new Set([1,2]))`,
        `new Set([1,2]).isSupersetOf(new Set([1])) && !new Set([1,2]).isSupersetOf(new Set([3]))`,
        `new Set([1]).isDisjointFrom(new Set([2])) && !new Set([1,2]).isDisjointFrom(new Set([2]))`,
        `var m=new Map([[2,0],[4,0]]); Array.from(new Set([1,2]).union(m)).join()==='1,2,4'`,
        `var s={size:3,has:function(){throw 1},keys:function(){return [2,2,3][Symbol.iterator]()}}; Array.from(new Set([1,2]).symmetricDifference(s)).join()==='1,3'`,
        `var log=''; var s={get size(){log+='s';return 3},get has(){log+='h';return function(x){return x===1}},get keys(){log+='k';return function(){throw 1}}}; new Set([1]).isSubsetOf(s) && log==='shk'`,
        `var closed=false,s={size:1,has:function(){},keys:function(){return {next:function(){return {value:2,done:false}},return:function(){closed=true;return {}}}}}; !new Set([1]).isSupersetOf(s) && closed`,
        `var ok=false;try{new Set().union({size:NaN,has:function(){},keys:function(){}})}catch(e){ok=e instanceof TypeError}ok`,
        `var ok=false;try{new Set().union({size:-1,has:function(){},keys:function(){}})}catch(e){ok=e instanceof RangeError}ok`,
        `var ok=false;try{Set.prototype.union.call(new Map(),new Set())}catch(e){ok=e instanceof TypeError}ok`,
        `typeof Map.prototype.union==='undefined' && typeof WeakSet.prototype.union==='undefined' && typeof new Map().union==='undefined'`,
        `Set.prototype.union.name==='union' && Set.prototype.union.length===1 && !Object.getOwnPropertyDescriptor(Set.prototype,'union').enumerable`,
        `var a=new Set([NaN,0,{}]),b=new Set([NaN,-0]); a.intersection(b).size===2 && a.difference(b).size===1`,
        `var a=new Set([1,2]),seen='';var s={size:5,has:function(k){seen+=k;a.clear();a.add(9);return k===2},keys:function(){}}; Array.from(a.difference(s)).join()==='1' && seen==='12'`,
        `var a=new Set([1]);var s={size:1,has:function(){},keys:function(){a.add(2);return [3][Symbol.iterator]()}};Array.from(a.union(s)).join()==='1,2,3'`,
        `var a=new Set([1]);var s={size:1,has:function(){},keys:function(){a.add(2);return [2][Symbol.iterator]()}};Array.from(a.symmetricDifference(s)).join()==='1'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
modern_string_well_formed :: proc(t: ^testing.T) {
    cases := []string{
        `''.isWellFormed() && 'abc\u{1F600}'.isWellFormed() && '\uD83D\uDE00'.isWellFormed()`,
        `!'\uD800'.isWellFormed() && !'\uDC00'.isWellFormed() && !'a\uD800b'.isWellFormed()`,
        `'a\uD800b\uDC00'.toWellFormed()==='a\uFFFDb\uFFFD'`,
        `'\uD800\uD800\uDC00\uDC00'.toWellFormed()==='\uFFFD\uD800\uDC00\uFFFD'`,
        `!String.fromCharCode(0xD800).isWellFormed() && String.fromCharCode(0xD800).length===1 && String.fromCharCode(0xD800).charCodeAt(0)===0xD800`,
        `!String.fromCodePoint(0xDC00).isWellFormed() && String.fromCodePoint(0xDC00).toWellFormed()==='\uFFFD'`,
        `var s='\uD800'+'\uDC00'; s.isWellFormed() && s.toWellFormed()==='\uD800\uDC00'`,
        `!JSON.parse('"\\ud800"').isWellFormed() && JSON.parse('"\\ud800"').toWellFormed()==='\uFFFD'`,
        `JSON.stringify('\uD800')==='"\\ud800"' && JSON.parse('"\\ud83d\\ude00"')==='\uD83D\uDE00'`,
        `String.prototype.isWellFormed.call(123) && String.prototype.toWellFormed.call({toString:function(){return '\uD800'}})==='\uFFFD'`,
        `var n=0; for(var v of [null,undefined,Symbol()]) {try{String.prototype.isWellFormed.call(v)}catch(e){if(e instanceof TypeError)n++}}n===3`,
        `String.prototype.isWellFormed.length===0 && String.prototype.toWellFormed.name==='toWellFormed' && !Object.getOwnPropertyDescriptor(String.prototype,'toWellFormed').enumerable`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
modern_binding_function_names :: proc(t: ^testing.T) {
    cases := []string{
        `var f=function(){}; let g=()=>1; const h=async function(){}; f.name==='f' && g.name==='g' && h.name==='h'`,
        `var f=function*(){}; const g=async()=>1; f.name==='f' && g.name==='g'`,
        `var f; f=function(){}; f.name==='f'`,
        `var f; f||=()=>1; var g=null; g??=function(){}; var h=true; h&&=function*(){}; f.name==='f' && g.name==='g' && h.name==='h'`,
        `var f=function named(){}; var g;g=function other(){};f.name==='named' && g.name==='other'`,
        `var f=(0,function(){}),g=f; g.name==='' && f.name===''`,
        `var o={}; o.f=function(){}; o.f.name===''`,
        `function test(f=function(){},g=()=>0){return f.name==='f' && g.name==='g'}test()`,
        `const C=class {}; var D; D=class {}; C.name==='C' && D.name==='D'`,
        `var f=function(){}; var d=Object.getOwnPropertyDescriptor(f,'name'); d.value==='f' && !d.writable && !d.enumerable && d.configurable`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
