package js

import "core:testing"

// name/length/atributos das nativas dos builtins (builtin_meta.odin).
@(test)
builtin_function_metadata :: proc(t: ^testing.T) {
    cases := []string{
        // name e length da spec em nativas que nasciam anônimas / length 0
        `Math.max.name==='max' && Math.max.length===2 && JSON.parse.length===2 && JSON.stringify.length===3`,
        `Array.length===1 && Object.length===1 && Date.length===7 && RegExp.length===2 && Promise.length===1 && Map.length===0`,
        `Promise.prototype.then.length===2 && String.prototype.replace.length===2 && Function.prototype.call.length===1`,
        `parseInt.name==='parseInt' && parseInt.length===2 && Reflect.apply.length===3 && Date.UTC.length===7`,
        `Map.prototype.set.length===2 && Set.prototype.add.name==='add' && Uint8Array.length===3 && Uint8Array.prototype.subarray.length===2`,
        `String(Math.max)==='function max() { [native code] }'`,
        // propriedades dos builtins não enumeram
        `Object.keys(Array.prototype).length===0 && Object.keys(Math).length===0 && Object.keys(JSON).length===0`,
        `Object.keys(String.prototype).length===0 && Object.keys(Number).length===0 && Object.keys(Promise).length===0`,
        `!Array.prototype.propertyIsEnumerable('map') && !Object.getOwnPropertyDescriptor(Object,'keys').enumerable`,
        `var n=0; for (var k in Math) n++; n===0`,
        // constantes imutáveis
        `var d=Object.getOwnPropertyDescriptor(Math,'PI'); !d.writable && !d.enumerable && !d.configurable`,
        `Math.PI=4; Math.PI===3.141592653589793`,
        `var d=Object.getOwnPropertyDescriptor(Array,'prototype'); !d.writable && !d.configurable`,
        // método não é construtor; construtora continua sendo
        `var ok=false; try{ new Math.max() }catch(e){ ok=e instanceof TypeError } ok`,
        `var ok=false; try{ new parseInt('1') }catch(e){ ok=e instanceof TypeError } ok`,
        `new Map() instanceof Map && new Date(0).getTime()===0 && typeof new Promise(function(){})==='object'`,
        // métodos seguem graváveis (polyfill) e o que o usuário adiciona enumera
        `Array.prototype.myx=function(){ return 5 }; var ok=[].myx()===5 && Array.prototype.propertyIsEnumerable('myx'); delete Array.prototype.myx; ok`,
        `var o=String.prototype.trim; String.prototype.trim=function(){ return 'X' }; var r=String.prototype.trim.call(' a '); String.prototype.trim=o; r==='X' && ' a '.trim()==='a'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

// Primitivo lê a cadeia do seu prototype: polyfill e sobrescrita valem para 'a', 1, true.
@(test)
primitive_reads_prototype_chain :: proc(t: ^testing.T) {
    cases := []string{
        `String.prototype.foo=function(){ return 'F'+this }; 'a'.foo()==='Fa'`,
        `Number.prototype.dbl=function(){ return this*2 }; (21).dbl()===42`,
        `Boolean.prototype.neg=function(){ return !this.valueOf() }; true.neg()===false`,
        `Object.prototype.zz=7; var r='a'.zz===7 && (1).zz===7 && true.zz===7; delete Object.prototype.zz; r`,
        `Object.defineProperty(String.prototype,'first',{get:function(){ return this[0] },configurable:true}); 'xy'.first==='x'`,
        // ⚠️ DEGRADAÇÃO ANOTADA: sobrescrever método NATIVO não alcança o primitivo
        // (nativo vence; ver get_member). O wrapper (Object) vê a sobrescrita.
        `var o=Number.prototype.toFixed; Number.prototype.toFixed=function(){ return 'N' }; var r=(1).toFixed(2), w=new Number(1).toFixed(2); Number.prototype.toFixed=o; r==='1.00' && w==='N'`,
        `'abc'.charAt(1)==='b' && 'a'.length===1 && (255).toString(16)==='ff' && true.toString()==='true'`,
        `'a'.constructor===String && (1).constructor===Number && String.prototype.trim===' '.trim`,
        `(1234567).toLocaleString('en-US')==='1,234,567' && Number.prototype.toLocaleString===(1).toLocaleString`,
        `var P=Object.prototype, g=Object.getPrototypeOf; g(String.prototype)===P && g(Number.prototype)===P && g(Boolean.prototype)===P && g(Math)===P && g(JSON)===P && g(Array.prototype)===P && g(P)===null`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
