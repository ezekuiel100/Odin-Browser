package js

import "core:testing"

// JSON.stringify seguindo SerializeJSONProperty: replacer (função e lista), getters,
// escape de controle. Antes o 2º argumento era ignorado, getters sumiam e controles
// < 0x20 saíam crus (JSON inválido).
@(test)
json_stringify_spec :: proc(t: ^testing.T) {
    cases := []string{
        // escape de controle: o resultado tem de voltar pelo JSON.parse
        `JSON.stringify(String.fromCharCode(1))==='"\\u0001"'`,
        `JSON.stringify('\b\f\x1f')==='"\\b\\f\\u001f"'`,
        `var s=''; for(var i=0;i<32;i++) s+=String.fromCharCode(i); JSON.parse(JSON.stringify(s))===s`,
        `JSON.stringify('\x7f')==='"\x7f"'`,
        // replacer lista
        `JSON.stringify({a:1,b:2,c:3},['c','a'])==='{"c":3,"a":1}'`,
        `JSON.stringify({1:'x',b:2},[1,'1','b','b'])==='{"1":"x","b":2}'`,
        `JSON.stringify({a:{a:1,z:2},z:3},['a'])==='{"a":{"a":1}}'`,
        `JSON.stringify({a:1},[])==='{}' && JSON.stringify([1,{a:1}],['b'])==='[1,{}]'`,
        // replacer função: holder como this, chave '' no topo, undefined omite
        `JSON.stringify({a:1,b:'x'},function(k,v){ return typeof v==='number'? v*2 : v })==='{"a":2,"b":"x"}'`,
        `JSON.stringify({a:1,b:2},function(k,v){ return k==='a'? undefined : v })==='{"b":2}'`,
        `var ks=[]; JSON.stringify({a:[5]},function(k,v){ ks.push(k); return v }); ks.join('|')==='|a|0'`,
        `var top; JSON.stringify(1,function(k,v){ top=this; return v }); top['']===1`,
        `var o={a:1}; var th; JSON.stringify(o,function(k,v){ if(k==='a') th=this; return v }); th===o`,
        `JSON.stringify([1,2],function(k,v){ return k==='0'? undefined : v })==='[null,2]'`,
        `JSON.stringify({a:1},function(){ return undefined })===undefined`,
        `JSON.stringify({a:1},function(k,v){ return k===''? {z:1} : v })==='{"z":1}'`,
        // getters rodam
        `JSON.stringify({get a(){ return 1 }, b:2})==='{"a":1,"b":2}'`,
        `var ok=false; try{ JSON.stringify({get a(){ throw 7 }}) }catch(e){ ok=e===7 } ok`,
        // toJSON recebe a chave; devolver undefined omite
        `JSON.stringify({x:{toJSON:function(k){ return k+'!' }}})==='{"x":"x!"}'`,
        `JSON.stringify({x:{toJSON:function(){ return undefined }}, y:1})==='{"y":1}'`,
        `JSON.stringify(new Date(0))==='"1970-01-01T00:00:00.000Z"'`,
        // undefined/função/símbolo
        `JSON.stringify({a:undefined,b:function(){},c:Symbol('s'),d:1})==='{"d":1}'`,
        `JSON.stringify([undefined,function(){},Symbol('s')])==='[null,null,null]'`,
        `JSON.stringify(undefined)===undefined && JSON.stringify(function(){})===undefined`,
        // indentação com chaves omitidas não deixa vírgula sobrando
        `JSON.stringify({a:undefined,b:1,c:undefined},null,1)==='{\n "b": 1\n}'`,
        `JSON.stringify({a:undefined},null,2)==='{}'`,
        `JSON.stringify([[],{}],null,1)==='[\n [],\n {}\n]'`,
        // ciclo e BigInt seguem lançando
        `var o={}; o.o=o; var ok=false; try{ JSON.stringify(o) }catch(e){ ok=e instanceof TypeError } ok`,
        `var ok=false; try{ JSON.stringify({a:1n}) }catch(e){ ok=e instanceof TypeError } ok`,
        `BigInt.prototype.toJSON=function(){ return this.toString() }; var r=JSON.stringify({a:1n}); delete BigInt.prototype.toJSON; r==='{"a":"1"}'`,
        // subclasse de Array serializa como array
        `class X extends Array {} var x=new X(); x.push(1,2); JSON.stringify(x)==='[1,2]'`,
        // mesmo objeto em dois ramos NÃO é ciclo
        `var s={a:1}; JSON.stringify({x:s,y:[s]})==='{"x":{"a":1},"y":[{"a":1}]}'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

// Accessors entram na ORDEM DE INSERÇÃO como data-props (antes saíam no fim, e
// em ordem de map do Odin quando havia vários — origem do Test262 flaky
// Object/entries/exception-during-enumeration).
@(test)
own_key_order_with_accessors :: proc(t: ^testing.T) {
    cases := []string{
        `Object.keys({get b(){return 1}, c:1, a:1}).join()==='b,c,a'`,
        `Object.keys({get z(){}, get y(){}, get x(){}, w:1, set v(_){} }).join()==='z,y,x,w,v'`,
        `var k='q'; Object.keys({a:1, get [k](){return 1}, b:2}).join()==='a,q,b'`,
        `var o={a:1}; Object.defineProperty(o,'g',{get:function(){},enumerable:true}); o.b=2; Object.keys(o).join()==='a,g,b'`,
        // data → accessor mantém a posição
        `var o={a:1,b:2}; Object.defineProperty(o,'a',{get:function(){return 9}}); Object.getOwnPropertyNames(o).join()==='a,b' && o.a===9`,
        // delete + recriação vai para o fim
        `var o={get a(){return 1}, b:2}; delete o.a; o.a=3; Object.keys(o).join()==='b,a'`,
        `var s=''; for (var k in {get b(){}, a:1}) s+=k; s==='ba'`,
        `Object.entries({get b(){return 2}, a:1}).join('|')==='b,2|a,1'`,
        `class C { get z(){} m(){} get a(){} } Object.getOwnPropertyNames(C.prototype).indexOf('z') < Object.getOwnPropertyNames(C.prototype).indexOf('a')`,
        // índices continuam primeiro, em ordem numérica
        `Object.keys({get b(){}, 2:1, a:1, 1:1}).join()==='1,2,b,a'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
