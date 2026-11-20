package js

import "core:testing"

@(test)
array_define_property_indices :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[]; Object.defineProperty(a,'2',{value:42}); a.length===3 && a[2]===42 && !(0 in a) && a.hasOwnProperty('2')`,
        `var a=[]; Object.defineProperty(a,'0',{value:7}); a[0]=9; var d=Object.getOwnPropertyDescriptor(a,'0'); a[0]===7 && !d.writable && !d.enumerable && !d.configurable && !delete a[0]`,
        `var a=[1]; Object.defineProperty(a,'0',{value:2}); var d=Object.getOwnPropertyDescriptor(a,'0'); d.value===2 && d.writable && d.enumerable && d.configurable`,
        `var a=[1]; Object.defineProperty(a,'0',{enumerable:false}); a[0]===1 && Object.keys(a).length===0 && Object.getOwnPropertyNames(a).indexOf('0')>=0 && Object.getOwnPropertyDescriptors(a)[0].value===1`,
        `var a=[]; Object.defineProperty(a,'0',{get:function(){return this.x},set:function(v){this.x=v},configurable:true}); a[0]=8; a[0]===8 && a.length===1 && a.map(function(x){return x+1})[0]===9 && delete a[0] && !(0 in a)`,
        `var a=[]; Object.defineProperty(a,'x',{value:4}); a.x=9; a.x===4 && !a.propertyIsEnumerable('x') && !delete a.x`,
        `var a=[]; Object.defineProperty(a,'01',{value:4}); a['01']===4 && a.length===0 && a[1]===undefined`,
        `var a=[]; Object.defineProperty(a,'4294967295',{value:4}); a.length===0 && a[4294967295]===4`,
        `var a=[1]; Object.defineProperty(a,'0',{writable:false}); var caught=false; try{(function(){'use strict'; a[0]=2})()}catch(e){caught=e instanceof TypeError} caught && a[0]===1`,
        `var a=[1]; Object.defineProperty(a,'0',{configurable:false}); var ok=false; try{Object.defineProperty(a,'0',{enumerable:false})}catch(e){ok=e instanceof TypeError} ok && a[0]===1`,
        `var a=[]; Object.defineProperty(a,'0',{value:1}); var keys=''; for(var k in a)keys+=k; keys===''`,
        `var a=[]; var ok=false; try{Object.defineProperty(a,'0',{get:3})}catch(e){ok=e instanceof TypeError} ok && a.length===0`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
array_define_property_length :: proc(t: ^testing.T) {
    cases := []string{
        `var a=[1,2,3]; Object.defineProperty(a,'length',{value:1}); a.length===1 && !(1 in a) && a[2]===undefined`,
        `var a=[1]; Object.defineProperty(a,'length',{value:4}); a.length===4 && !(1 in a) && !(3 in a)`,
        `var a=[1]; Object.defineProperty(a,'length',{writable:false}); a.length=0; a[1]=2; a[0]=9; a.length===1 && a[0]===9 && !Object.getOwnPropertyDescriptor(a,'length').writable`,
        `var a=[1]; Object.defineProperty(a,'length',{writable:false}); var ok=false; try{Object.defineProperty(a,'1',{value:2})}catch(e){ok=e instanceof TypeError} ok && a.length===1 && !(1 in a)`,
        `var a=[1]; Object.defineProperty(a,'length',{writable:false}); Object.defineProperty(a,'length',{value:1}); var ok=false; try{a.push(2)}catch(e){ok=e instanceof TypeError} ok && a.length===1`,
        `var a=[1,2,3,4]; Object.defineProperty(a,'2',{configurable:false}); var ok=false; try{Object.defineProperty(a,'length',{value:1,writable:false})}catch(e){ok=e instanceof TypeError} ok && a.length===3 && a[2]===3 && !(3 in a) && !Object.getOwnPropertyDescriptor(a,'length').writable`,
        `var a=[1]; var ok=false; try{Object.defineProperty(a,'length',{value:1.5})}catch(e){ok=e instanceof RangeError} ok && a.length===1`,
        `var a=[]; var ok=false; try{Object.defineProperty(a,'length',{get:function(){return 1}})}catch(e){ok=e instanceof TypeError} ok && a.length===0`,
        `var a=[]; var n=0; Object.defineProperty(a,'length',{value:{valueOf:function(){n++;return 2}}}); n===2 && a.length===2`,
        `var a=[1,2]; Object.defineProperties(a,{'0':{value:8},length:{value:1}}); a.length===1 && a[0]===8`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
