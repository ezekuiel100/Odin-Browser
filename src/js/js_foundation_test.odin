package js
import "core:testing"

@(test)
foundation_descriptors :: proc(t: ^testing.T) {
    cases := []string{

        `var o={}; Object.defineProperty(o,'x',{}); o.hasOwnProperty('x') && o.x===undefined`,
        `var o={}; Object.defineProperty(o,'x',{value:1}); var ok=false; try {Object.defineProperty(o,'x',{value:2})} catch(e){ok=e instanceof TypeError} ok && o.x===1`,
        `var o={}; Object.defineProperty(o,'x',{value:NaN}); Object.defineProperty(o,'x',{value:NaN}); true`,
        `var o={}; var ok=false; try{Object.defineProperty(o,'x',{get:3})}catch(e){ok=true} ok && !o.hasOwnProperty('x')`,
        `var o={}; Object.defineProperty(o,'x',{get:function(){return 2}, configurable:true}); Object.defineProperty(o,'x',{value:4}); o.x===4`,
        `var o={}; Object.defineProperty(o,'x',{get:undefined}); var d=Object.getOwnPropertyDescriptor(o,'x'); d.get===undefined && !('value' in d)`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
@(test)
foundation_callbacks :: proc(t: ^testing.T) {
    cases := []string{
        `var o={0:2,2:4,length:3}; var ctx={n:4}; Array.prototype.some.call(o,function(v,i,a){return this===ctx && a===o && v===4},ctx)`,
        `var o={0:2,length:2}; var n=0; Array.prototype.every.call(o,function(v){n++; return this.x===v},{x:2}) && n===1`,
        `var o={0:2,length:2}; var n=0; Array.prototype.findIndex.call(o,function(v){n++; return this.x===n},{x:2})===1 && n===2`,
        `Array.prototype.findLast.call({0:2,1:4,length:2},function(v){return v===this.x},{x:2})===2`,
        `var o={length:1}; Object.defineProperty(o,'0',{get:function(){return 7}}); Array.prototype.some.call(o,function(v){return v===7})`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
@(test)
foundation_functions :: proc(t: ^testing.T) {
    cases := []string{
        `Array.prototype.map.name==='map' && Array.prototype.map.length===1 && Object.defineProperty.length===3`,
        `var ok=false; try{new Array.prototype.map()}catch(e){ok=e instanceof TypeError} ok`,
        `function f(a,b=1,c){} f.length===1 && f.bind(null).length===1 && f.bind(null,1).length===0 && f.bind(null).name==='bound f'`,
        `class C {m(){}} var ok=false; try{new C.prototype.m()}catch(e){ok=e instanceof TypeError} ok && C.prototype.m.prototype===undefined && new C() instanceof C`,
        `var f=()=>1; var ok=false; try{new f()}catch(e){ok=true} ok`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
