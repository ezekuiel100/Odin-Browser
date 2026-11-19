package js

import "core:testing"

// Objeto `arguments` (Args_Info): mapeamento com os params em sloppy, callee,
// e herança de Object.prototype em vez de Array.prototype.
@(test)
arguments_mapping :: proc(t: ^testing.T) {
    cases := []string{
        `function m(a){ arguments[0]=9; return a } m(1)===9`,
        `function m(a){ a=9; return arguments[0] } m(1)===9`,
        `function m(a){ a+=1; a++; return arguments[0] } m(1)===3`,
        `function m(a,b){ b=3; return arguments.length===1 && arguments[1]===undefined } m(1)`,
        `function m(a){ delete arguments[0]; arguments[0]=7; return a } m(1)===1`,
        `function m(a){ var f=function(){ a=5 }; f(); return arguments[0] } m(1)===5`,
        `function m(a,a){ arguments[0]=9; return a } m(1,2)===2`,
        `function* g(a){ arguments[0]=5; yield a } g(1).next().value===5`,
        `function m(a){ a = a || 'd'; return arguments[0] } m()===undefined && m('x')==='x'`,
        // sem mapeamento: strict, default, padrão, rest
        `function s(a){ 'use strict'; arguments[0]=9; return a } s(1)===1`,
        `function s(a){ 'use strict'; a=2; return arguments[0] } s(1)===1`,
        `function d(a=0){ arguments[0]=9; return a } d(1)===1`,
        `function p({x}){ arguments[0]=9; return x } p({x:1})===1`,
        `function r(a,...z){ arguments[0]=9; return a } r(1)===1`,
        `class C { m(a){ arguments[0]=9; return a } } new C().m(1)===1`,
        // o valor sobrevive à chamada (escopo fora do pool)
        `function k(a){ return arguments } var x=k(1); x[0]=2; x[0]===2 && x.length===1`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
arguments_object_shape :: proc(t: ^testing.T) {
    cases := []string{
        `function f(){ return typeof arguments.callee } f()==='function'`,
        `function f(){ return arguments.callee===f } f()`,
        `function f(){ 'use strict'; try{ arguments.callee; return false }catch(e){ return e instanceof TypeError } } f()`,
        `function f(){ return Object.getPrototypeOf(arguments)===Object.prototype } f()`,
        `function f(){ return !(arguments instanceof Array) && arguments instanceof Object } f()`,
        `function f(){ return !('map' in arguments) && arguments.map===undefined && 'callee' in arguments } f()`,
        `function f(){ return JSON.stringify(arguments) } f(1,2)==='{"0":1,"1":2}'`,
        `function f(){ return Object.prototype.toString.call(arguments) } f()==='[object Arguments]'`,
        `function f(){ return arguments[Symbol.iterator]===[][Symbol.iterator] && [...arguments].length===2 } f(1,2)`,
        `function f(){ var d=Object.getOwnPropertyDescriptor(arguments,'length'); return d.configurable && d.writable && !d.enumerable } f(1)`,
        `function f(){ return Object.keys(arguments).join() } f(5,6)==='0,1'`,
        `function f(){ return arguments.hasOwnProperty('0') && typeof arguments.toString==='function' } f(1)`,
        // idiomas que precisam seguir funcionando
        `function f(){ return Array.prototype.slice.call(arguments,1).join() } f(1,2,3)==='2,3'`,
        `function g(x,y){ return x+y } function f(){ return g.apply(null, arguments) } f(2,3)===5`,
        `function f(){ var r=[]; Array.prototype.push.apply(r, arguments); return r.length } f(1,2,3)===3`,
        `function f(){ return Array.from(arguments).join() } f(4,5)==='4,5'`,
        `function f(){ return Math.max.apply(Math, arguments) } f(1,9,3)===9`,
        `function f(){ return !Array.isArray(arguments) } f()`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
