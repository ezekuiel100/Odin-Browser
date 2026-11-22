package js

import "core:testing"

@(test)
json_stringify_array_properties :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1]; Object.defineProperty(a,'0',{get:function(){return 7}}); JSON.stringify(a)==='[7]'`,
        `var a=[1]; a.tag=7; Object.defineProperty(a,'0',{get:function(){return this.tag},enumerable:false}); JSON.stringify(a)==='[7]'`,
        `var a=[1]; Object.defineProperty(a,'0',{set:function(v){}}); JSON.stringify(a)==='[null]'`,
        `var a=[1]; delete a[0]; Array.prototype[0]=7; JSON.stringify(a)==='[7]'`,
        `var a=[undefined]; Array.prototype[0]=7; JSON.stringify(a)==='[null]'`,
        `var a=[1]; delete a[0]; a.tag=7; Object.defineProperty(Array.prototype,'0',{get:function(){return this.tag}}); JSON.stringify(a)==='[7]'`,
        `var a=[1]; delete a[0]; Object.prototype[0]=7; JSON.stringify(a)==='[7]'`,
        `var a=[1,2]; a.extra=3; Object.defineProperty(a,'1',{enumerable:false}); JSON.stringify(a)==='[1,2]'`,
        `class X extends Array {} var a=new X(); a.push(1); a.tag=7; Object.defineProperty(a,'0',{get:function(){return this.tag}}); JSON.stringify(a)==='[7]'`,
        `class X extends Array {} var a=new X(); a.push(1); Object.defineProperty(X.prototype,'0',{get:function(){return 7}}); JSON.stringify(a)==='[1]'`,
        `class X extends Array {} var a=new X(); a.length=1; a.tag=7; Object.defineProperty(X.prototype,'0',{get:function(){return this.tag}}); JSON.stringify(a)==='[7]'`,
        `class X extends Array {} var a=new X(); a.push(1); Object.defineProperty(X.prototype,'length',{get:function(){return 2}}); JSON.stringify(a)==='[1]'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_stringify_array_mutations_and_errors :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1,2,3]; JSON.stringify(a,function(k,v){if(k==='0') a.length=1; return v})==='[1,null,null]'`,
        `var a=[1]; JSON.stringify(a,function(k,v){if(k==='0') a.push(2); return v})==='[1]'`,
        `var a=[1,2]; Object.defineProperty(a,'0',{get:function(){a[1]=7;return 1}}); JSON.stringify(a)==='[1,7]'`,
        `var a=[1,2]; Object.defineProperty(a,'0',{get:function(){delete a[1];return 1}}); Array.prototype[1]=7; JSON.stringify(a)==='[1,7]'`,
        `var a=[1,2,3]; Array.prototype[1]=7; JSON.stringify(a,function(k,v){if(k==='0') a.length=1; return v})==='[1,7,null]'`,
        `var a=[1], sentinel={}, caught=false; Object.defineProperty(a,'0',{get:function(){throw sentinel}}); try{JSON.stringify(a)}catch(e){caught=e===sentinel} caught`,
        `var a=[1], sentinel={}, caught=false; delete a[0]; Object.defineProperty(Array.prototype,'0',{get:function(){throw sentinel}}); try{JSON.stringify(a)}catch(e){caught=e===sentinel} caught`,
        `var a=[1,2], seen='', calls=0, caught=false, sentinel={}; Object.defineProperty(a,'0',{get:function(){throw sentinel}}); Object.defineProperty(a,'1',{get:function(){calls++;return 2}}); try{JSON.stringify(a,function(k,v){seen+=k+'|';return v})}catch(e){caught=e===sentinel} caught && calls===0 && seen==='|'`,
        `var a=[1], calls=0, caught=false, sentinel={}; Object.defineProperty(a,'toJSON',{get:function(){throw sentinel}}); try{JSON.stringify(a,function(k,v){calls++;return v})}catch(e){caught=e===sentinel} caught && calls===0`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_stringify_proxy_arrays :: proc(t: ^testing.T) {
    cases := []string{
        `JSON.stringify(new Proxy([1,2],{}))==='[1,2]'`,
        `JSON.stringify(new Proxy(new Proxy([1],{}),{}))==='[1]'`,
        `var p=new Proxy([1],{get:function(t,k){return k==='length'?3:t[k]}}); JSON.stringify(p)==='[1,null,null]'`,
        `var log='', p=new Proxy([1,2],{get:function(t,k){log+=k+'|';return k==='0'?7:t[k]},has:function(){throw 1},ownKeys:function(){throw 2}}); JSON.stringify(p)==='[7,2]' && log==='toJSON|length|0|1|'`,
        `var p=new Proxy([1,2],{get:function(t,k){return k==='length'?{valueOf:function(){return 1.9}}:t[k]}}); JSON.stringify(p)==='[1]'`,
        `var p=new Proxy([1],{get:function(t,k){return k==='length'?-1:t[k]}}); JSON.stringify(p)==='[]'`,
        `var p=new Proxy([1],{get:function(t,k){return k==='length'?NaN:t[k]}}); JSON.stringify(p)==='[]'`,
        `var a=[1], p=new Proxy(a,{}), holder; JSON.stringify(p,function(k,v){if(k==='0')holder=this;return v})==='[1]' && holder===p`,
        `var a=[1], p=new Proxy(a,{}), receiver; Object.defineProperty(a,'0',{get:function(){receiver=this;return 7}}); JSON.stringify(p)==='[7]' && receiver===p`,
        `var a=[1], p=new Proxy(a,{}), receiver; delete a[0]; Object.defineProperty(Array.prototype,'0',{get:function(){receiver=this;return 7}}); JSON.stringify(p)==='[7]' && receiver===p`,
        `JSON.stringify(new Proxy({0:1,length:1},{}))==='{"0":1,"length":1}'`,
        `function f(){return JSON.stringify(new Proxy(arguments,{}))} f(1,2)==='{"0":1,"1":2}'`,
        `class X extends Array {} var a=new X(); a.push(1,2); JSON.stringify(new Proxy(a,{}))==='[1,2]'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_get_with_receiver_inherited_indices :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1]; delete a[0]; Object.defineProperty(Array.prototype,'0',{get:function(){return this.tag}}); Reflect.get(a,'0',{tag:7})===7`,
        `var a=[undefined]; Object.defineProperty(Array.prototype,'0',{get:function(){throw 7}}); Reflect.get(a,'0',{})===undefined`,
        `var a=[1]; Object.defineProperty(a,'0',{get:function(){return this.tag}}); Reflect.get(new Proxy(a,{}),'0',{tag:7})===7`,
        `class X extends Array {} var a=new X(); a.length=1; Object.defineProperty(X.prototype,'0',{get:function(){return this.tag}}); Reflect.get(a,'0',{tag:7})===7`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_stringify_array_proxy_errors_and_cycles :: proc(t: ^testing.T) {
    cases := []string{
        `var r=Proxy.revocable([1],{}), caught=false, calls=0; r.revoke(); try{JSON.stringify(r.proxy,function(k,v){calls++;return v})}catch(e){caught=e instanceof TypeError} caught && calls===0`,
        `var r=Proxy.revocable([1],{}), caught=false; r.revoke(); try{JSON.stringify(0,function(){return r.proxy})}catch(e){caught=e instanceof TypeError} caught`,
        `var p=new Proxy([1],{get:function(t,k){if(k==='length')throw 7;return t[k]}}), caught=false; try{JSON.stringify(p)}catch(e){caught=e===7} caught`,
        `var p=new Proxy([1],{get:function(t,k){if(k==='0')throw 7;return t[k]}}), caught=false; try{JSON.stringify(p)}catch(e){caught=e===7} caught`,
        `var r=Proxy.revocable([1],{get:function(t,k){if(k==='length'){r.revoke();return 1}return t[k]}}), caught=false; try{JSON.stringify(r.proxy)}catch(e){caught=e instanceof TypeError} caught`,
        `var a=[]; a[0]=a; var caught=false; try{JSON.stringify(a)}catch(e){caught=e instanceof TypeError} caught`,
        `var a=[null], p=new Proxy(a,{}); a[0]=p; var caught=false; try{JSON.stringify(p)}catch(e){caught=e instanceof TypeError} caught`,
        // Proxy e alvo são objetos distintos, mesmo compartilhando o armazenamento.
        `var a=[null], p=new Proxy(a,{get:function(t,k){return k==='0'?7:t[k]}}); a[0]=p; JSON.stringify(a)==='[[7]]'`,
        `var a=[1], p=new Proxy(a,{}); JSON.stringify([a,p,p])==='[[1],[1],[1]]'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
