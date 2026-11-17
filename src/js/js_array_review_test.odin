package js

import "core:testing"

@(test)
array_review_search :: proc(t: ^testing.T) {
    cases := []string{
        `var o={0:1,1:2,length:2}; Array.from(o,function(v,i){if(i===0)o[1]=9; return v}).join()==='1,9'`,
        `var closed=false; var i=0; var o={}; o[Symbol.iterator]=function(){return {next:function(){return {value:++i,done:false}},return:function(){closed=true;throw 9}}}; var ok=false; try{Array.from(o,function(){throw 7})}catch(e){ok=e===7} ok && closed && i===1`,
        `Array.from(new Set([1,2])).join()==='1,2' && Array.from('a😀').length===2`,
        `var a=[1,2]; var sep={toString:function(){a.pop();return ','}}; a.join(sep)==='1,'`,
        `var touched=false; var ok=false; try{[1,2].slice({valueOf:function(){throw 7}},{valueOf:function(){touched=true;return 2}})}catch(e){ok=e===7} ok && !touched`,
        `var o={length:1}; Object.defineProperty(o,'0',{get:function(){throw 7}}); var ok=false; try{Array.prototype.toSorted.call(o)}catch(e){ok=e===7} ok`,

        `[1,2,1].indexOf(1,1)===2 && [1,2,1].indexOf(1,Infinity)===-1`,
        `[1,2,1].includes(1,-1) && ![1,2,1].includes(2,-1)`,
        `Array.prototype.indexOf.call({length:2},undefined)===-1 && Array.prototype.includes.call({length:2},undefined)`,
        `[1,2,1].lastIndexOf(1)===2 && [1,2,1].lastIndexOf(1,undefined)===0 && [1,2,1].lastIndexOf(1,-2)===0`,
        `[1,2].slice(-Infinity,Infinity).join()==='1,2' && [1,2].at({valueOf:function(){return -1}})===2`,
        `var o={length:{valueOf:function(){return 2}},1:9}; Array.prototype.indexOf.call(o,9)===1`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_review_mutation :: proc(t: ^testing.T) {
    cases := []string{
        `var o={length:0}; var n=Array.prototype.push.call(o,'a','b'); n===2 && o[1]==='b' && Array.prototype.pop.call(o)==='b' && o.length===1 && !o.hasOwnProperty('1')`,
        `var o={0:'a',2:'c',length:3}; Array.prototype.shift.call(o)==='a' && o.length===2 && !o.hasOwnProperty('0') && o[1]==='c' && !o.hasOwnProperty('2')`,
        `var o={1:'b',length:2}; Array.prototype.unshift.call(o,'x')===3 && o[0]==='x' && !o.hasOwnProperty('1') && o[2]==='b'`,
        `var o={0:'a',length:3}; Array.prototype.reverse.call(o)===o && !o.hasOwnProperty('0') && o[2]==='a'`,
        `var o={0:1,1:2,2:3,3:4,length:4}; Array.prototype.copyWithin.call(o,1,0,3)===o && o[1]===1 && o[2]===2 && o[3]===3`,
        `var o={0:1,2:3,length:3}; Array.prototype.copyWithin.call(o,0,1)===o && !o.hasOwnProperty('0') && o[1]===3`,
        `var o={length:3}; Array.prototype.fill.call(o,7,-2)===o && !o.hasOwnProperty('0') && o[1]===7 && o[2]===7`,
        `var a=[1,2]; a.splice().length===0 && a.join()==='1,2' && a.toSpliced().join()==='1,2'`,
        `var o={0:'a',1:'b',2:'c',length:3}; var r=Array.prototype.splice.call(o,1,1,'x','y'); r.join()==='b' && o.length===4 && o[1]==='x' && o[3]==='c'`,
        `var o={0:'a',2:'c',length:3}; Array.prototype.splice.call(o,0,1); o.length===2 && !o.hasOwnProperty('0') && o[1]==='c' && !o.hasOwnProperty('2')`,
        `var o={length:1}; Object.defineProperty(o,'0',{value:1}); var ok=false; try{Array.prototype.fill.call(o,2)}catch(e){ok=e instanceof TypeError} ok && o[0]===1`,
        `var o={}; Object.defineProperty(o,'length',{value:0}); var ok=false; try{Array.prototype.pop.call(o)}catch(e){ok=e instanceof TypeError} ok`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_review_callbacks :: proc(t: ^testing.T) {
    cases := []string{
        `var o={0:'a',2:'c',length:3}; Array.prototype.reduceRight.call(o,function(a,v,i,s){return a+v+i+(s===o)},'')==='c2truea0true'`,
        `var ok=false; try{Array.prototype.reduceRight.call({length:3},function(){})}catch(e){ok=e instanceof TypeError} ok`,
        `var o={0:[1,2],2:[3],length:3}; Array.prototype.flat.call(o).join()==='1,2,3'`,
        `var o={0:2,2:4,length:3}; Array.prototype.flatMap.call(o,function(v,i,s){return [v*this.n,i,s===o]},{n:3}).join()==='6,0,true,12,2,true'`,
        `var o={}; Object.defineProperty(o,'length',{get:function(){throw 7}}); var caught=false; try{Array.prototype.map.call(o,null)}catch(e){caught=e===7} caught`,
        `var a=[1,2,3]; a.map(function(v,i){if(i===0)a.pop(); return v}).length===3`,
        `Array.from({0:2,1:3,length:2},function(v,i){return v*this.n+i},{n:4}).join()==='8,13'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_review_copies_sort :: proc(t: ^testing.T) {
    cases := []string{
        `var o={0:3,2:1,length:4}; Array.prototype.sort.call(o)===o && o[0]===1 && o[1]===3 && !o.hasOwnProperty('2') && !o.hasOwnProperty('3')`,
        `var n=0; var a=[undefined,2,1]; a.sort(function(a,b){if(a===undefined||b===undefined)n++; return a-b}); n===0 && a[0]===1 && a[2]===undefined`,
        `var ok=false; try{[].sort(null)}catch(e){ok=e instanceof TypeError} ok`,
        `var o={0:1,length:1}; Object.defineProperty(o,'0',{get:function(){throw 7}}); Array.prototype.with.call(o,0,9)[0]===9`,
        `var o={0:1,1:2,2:3,length:3}; Object.defineProperty(o,'1',{get:function(){throw 7}}); Array.prototype.toSpliced.call(o,1,1,9).join()==='1,9,3'`,
        `var log=''; var o={length:3}; Object.defineProperty(o,'0',{get:function(){log+='0';return 1}}); Object.defineProperty(o,'2',{get:function(){log+='2';return 3}}); var a=Array.prototype.toReversed.call(o); log==='20' && a[0]===3 && a[2]===1`,
        `var o={length:1}; Object.defineProperty(o,'0',{get:function(){throw 7}}); var ok=false; try{Array.prototype.toSorted.call(o,null)}catch(e){ok=e instanceof TypeError} ok`,
        `var o={length:1}; var a=Array.prototype.concat.call(o,2); a[0]===o && a[1]===2`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_review_iterators_errors :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1]; var it=a.values(); var v=it.next().value; a.push(2); v===1 && it.next().value===2 && it.next().done`,
        `var o={0:'a',length:1}; var it=Array.prototype.entries.call(o); o[0]='b'; var p=it.next().value; p[0]===0 && p[1]==='b'`,
        `var o={length:0}; var it=Array.prototype.keys.call(o); var d=it.next().done; o.length=2; d && it.next().done`,
        `var o={}; Object.defineProperty(o,'length',{get:function(){throw 7}}); var it=Array.prototype.values.call(o); var ok=false; try{it.next()}catch(e){ok=e===7} ok`,
        `var ok=false; try{new Array(-1)}catch(e){ok=e instanceof RangeError} ok`,
        `var ok=false; try{Array.prototype.join.call(null)}catch(e){ok=e instanceof TypeError} ok`,
        `[1,2].join(null)==='1null2' && [1,2].join(0)==='102'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
