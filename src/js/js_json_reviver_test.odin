package js

import "core:testing"

@(test)
json_reviver_deletion_and_live_reads :: proc(t: ^testing.T) {
    cases := []string{
        `var a=JSON.parse('[1,2]',function(k,v){return k==='0'?undefined:v}); a.length===2 && !(0 in a) && !Object.hasOwn(a,'0') && Object.keys(a).join()==='1'`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){return k==='a'?undefined:v}); !Object.hasOwn(o,'a') && Object.keys(o).join()==='b'`,
        `var seen=''; JSON.parse('{"a":1,"b":2}',function(k,v){seen+=k+'|';if(k==='a')delete this.b;return v}); seen==='a|b||'`,
        `var seen, o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')delete this.b;if(k==='b'){seen=v;return 7}return v}); seen===undefined && o.b===7 && Object.hasOwn(o,'b')`,
        `var seen, a=JSON.parse('[1,2]',function(k,v){if(k==='0')delete this[1];if(k==='1'){seen=v;return 7}return v}); seen===undefined && a[1]===7 && Object.hasOwn(a,'1')`,
        `var seen, o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a'){delete this.b;Object.setPrototypeOf(this,{b:7})}if(k==='b')seen=v;return v}); seen===7 && Object.hasOwn(o,'b') && o.b===7`,
        `var seen, a=JSON.parse('[1,2]',function(k,v){if(k==='0'){delete this[1];Array.prototype[1]=7}if(k==='1')seen=v;return v}); seen===7 && Object.hasOwn(a,'1') && a[1]===7`,
        `var calls=0, receiver, o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{get:function(){calls++;receiver=this;return 7},configurable:true});return k==='b'?v+1:v}); calls===1 && receiver===o && o.b===8 && Object.getOwnPropertyDescriptor(o,'b').get===undefined`,
        `var calls=0, receiver, a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.defineProperty(this,'1',{get:function(){calls++;receiver=this;return 7},configurable:true});return k==='1'?v+1:v}); calls===1 && receiver===a && a[1]===8 && Object.getOwnPropertyDescriptor(a,'1').get===undefined`,
        `var calls=0, o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{get:function(){calls++;return 7},configurable:true});return k==='b'?undefined:v}); calls===1 && !Object.hasOwn(o,'b')`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{get:undefined,configurable:true});return k==='b'?undefined:v}); !Object.hasOwn(o,'b')`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_reviver_snapshots_and_array_mutations :: proc(t: ^testing.T) {
    cases := []string{
        `var seen='', a=JSON.parse('[1,2,3]',function(k,v){seen+=k+'|';if(k==='0')this.length=1;return v}); seen==='0|1|2||' && a.length===1 && !(1 in a) && !(2 in a)`,
        `var seen='', a=JSON.parse('[1,2,3]',function(k,v){seen+=k+'|';if(k==='0')this.length=1;return k==='2'?7:v}); seen==='0|1|2||' && a.length===3 && !(1 in a) && a[2]===7`,
        `var seen='', a=JSON.parse('[1,2]',function(k,v){seen+=k+'|';if(k==='0')this.push(3);return v}); seen==='0|1||' && a.length===3 && a[2]===3`,
        `var seen='', o=JSON.parse('{"a":1,"b":2}',function(k,v){seen+=k+'|';if(k==='a')this.c=3;return v}); seen==='a|b||' && o.c===3`,
        `var seen='', o=JSON.parse('{"a":1,"b":2}',function(k,v){seen+=k+'|';if(k==='a')Object.defineProperty(this,'b',{enumerable:false});return v}); seen==='a|b||' && Object.getOwnPropertyDescriptor(o,'b').enumerable`,
        `var seen='', o=JSON.parse('{"a":1,"b":{"old":2}}',function(k,v){seen+=k+'|';if(k==='a')this.b={fresh:7};return v}); seen==='a|fresh|b||' && o.b.fresh===7`,
        `var seen='', a=JSON.parse('[1,{"old":2}]',function(k,v){seen+=k+'|';if(k==='0')this[1]={fresh:7};return v}); seen==='0|fresh|1||' && a[1].fresh===7`,
        `var seen=''; JSON.parse('{"2":2,"1":1,"a":3}',function(k,v){seen+=k+'|';return v}); seen==='1|2|a||'`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')delete this.a;return v}); o.a===1 && Object.keys(o).join()==='b,a'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_reviver_property_constraints :: proc(t: ^testing.T) {
    cases := []string{
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{value:7,configurable:false});return k==='b'?9:v}); o.b===7 && !Object.getOwnPropertyDescriptor(o,'b').configurable`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{value:7,configurable:false});return k==='b'?undefined:v}); o.b===7`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{get:function(){return 7},configurable:false});return k==='b'?9:v}); o.b===7 && typeof Object.getOwnPropertyDescriptor(o,'b').get==='function'`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{get:function(){return 7},configurable:false});return k==='b'?undefined:v}); o.b===7`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.defineProperty(this,'1',{value:7,configurable:false});return k==='1'?9:v}); a[1]===7`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.defineProperty(this,'1',{value:7,configurable:false});return k==='1'?undefined:v}); a[1]===7`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.freeze(this);return typeof v==='number'?v*10:v}); o.a===1 && o.b===2 && Object.isFrozen(o)`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.freeze(this);return typeof v==='number'?v*10:v}); a[0]===1 && a[1]===2 && Object.isFrozen(a)`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a'){delete this.b;Object.preventExtensions(this)}return k==='b'?7:v}); !Object.hasOwn(o,'b') && !Object.isExtensible(o)`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0'){delete this[1];Object.preventExtensions(this)}return k==='1'?7:v}); !Object.hasOwn(a,'1') && a.length===2`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0'){this.length=1;Object.defineProperty(this,'length',{writable:false})}return k==='1'?7:v}); a.length===1 && !Object.hasOwn(a,'1')`,
        `var calls=0, o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{set:function(v){calls++},configurable:true});return k==='b'?7:v}); calls===0 && o.b===7`,
        `var calls=0, a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.defineProperty(this,'1',{set:function(v){calls++},configurable:true});return k==='1'?7:v}); calls===0 && a[1]===7`,
        `var o=JSON.parse('{"a":1,"b":2}',function(k,v){if(k==='a')Object.defineProperty(this,'b',{writable:false,enumerable:false,configurable:true});return k==='b'?7:v}); var d=Object.getOwnPropertyDescriptor(o,'b'); d.value===7 && d.writable && d.enumerable && d.configurable`,
        `var a=JSON.parse('[1,2]',function(k,v){if(k==='0')Object.defineProperty(this,'1',{writable:false,enumerable:false,configurable:true});return k==='1'?7:v}); var d=Object.getOwnPropertyDescriptor(a,'1'); d.value===7 && d.writable && d.enumerable && d.configurable`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_reviver_getter_errors_and_reentry :: proc(t: ^testing.T) {
    cases := []string{
        `var sentinel={}, caught=false, seen=''; try{JSON.parse('{"a":1,"b":2,"c":3}',function(k,v){seen+=k+'|';if(k==='a')Object.defineProperty(this,'b',{get:function(){throw sentinel}});return v})}catch(e){caught=e===sentinel} caught && seen==='a|'`,
        `var sentinel={}, caught=false, seen=''; try{JSON.parse('[1,2,3]',function(k,v){seen+=k+'|';if(k==='0')Object.defineProperty(this,'1',{get:function(){throw sentinel}});return v})}catch(e){caught=e===sentinel} caught && seen==='0|'`,
        `var seen='', o=JSON.parse('{"a":1,"b":2}',function(k,v){seen+=k+'|';if(k==='a')return JSON.parse('{"x":3}',function(k,v){return k==='x'?7:v});return v}); o.a.x===7 && o.b===2 && seen==='a|b||'`,
        `var o=JSON.parse('{"__proto__":1}',function(k,v){return k==='__proto__'?7:v}); Object.hasOwn(o,'__proto__') && o['__proto__']===7 && Object.getPrototypeOf(o)===Object.prototype`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_reviver_values_inserted_by_callbacks :: proc(t: ^testing.T) {
    cases := []string{
        `var seen='', holder, p=new Proxy({c:2},{}), o=JSON.parse('{"a":1,"b":0}',function(k,v){seen+=k+'|';if(k==='a')this.b=p;if(k==='c'){holder=this;return 7}return v}); seen==='a|c|b||' && holder===p && o.b.c===7`,
        `var p=new Proxy({c:2},{defineProperty:function(){return false}}), o=JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return k==='c'?7:v}); o.b.c===2`,
        `var p=new Proxy({c:2},{deleteProperty:function(){return false}}), o=JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return k==='c'?undefined:v}); o.b.c===2`,
        `var sentinel={}, caught=false, p=new Proxy({c:2},{defineProperty:function(){throw sentinel}}); try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return v})}catch(e){caught=e===sentinel} caught`,
        `var sentinel={}, caught=false, p=new Proxy({c:2},{deleteProperty:function(){throw sentinel}}); try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return k==='c'?undefined:v})}catch(e){caught=e===sentinel} caught`,
        `var r=Proxy.revocable({},{}), caught=false; r.revoke(); try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=r.proxy;return v})}catch(e){caught=e instanceof TypeError} caught`,
        `var p=new Proxy([1,2],{}), o=JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return k==='0'?undefined:v}); o.b.length===2 && !Object.hasOwn(o.b,'0') && o.b[1]===2`,
        `var f=function(){}; f.x=1; var o=JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=f;return k==='x'?7:v}); o.b.x===7`,
        `var t={}; Object.defineProperty(t,'c',{value:2,enumerable:true,configurable:false}); var p=new Proxy(t,{defineProperty:function(){return true}}), caught=false; try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return v})}catch(e){caught=e instanceof TypeError} caught`,
        `var t={}; Object.defineProperty(t,'c',{value:2,enumerable:true,configurable:false}); var p=new Proxy(t,{deleteProperty:function(){return true}}), caught=false; try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;return k==='c'?undefined:v})}catch(e){caught=e instanceof TypeError} caught`,
        `var t={c:2}, p=new Proxy(t,{defineProperty:function(){return true}}), caught=false; try{JSON.parse('{"a":1,"b":0}',function(k,v){if(k==='a')this.b=p;if(k==='c'){delete t.c;Object.preventExtensions(t)}return v})}catch(e){caught=e instanceof TypeError} caught`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
