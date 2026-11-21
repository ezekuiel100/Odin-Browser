package js

import "core:testing"
import "core:fmt"

@(test)
math_added_methods_metadata_and_coercion :: proc(t: ^testing.T) {
    cases := []string{
        `var names=['cosh','sinh','tanh','acosh','asinh','atanh','expm1','log1p','fround']; names.every(function(n){ var f=Math[n],d=Object.getOwnPropertyDescriptor(Math,n); return typeof f==='function' && f.name===n && f.length===1 && d.writable && d.configurable && !d.enumerable; })`,
        `names.every(function(n){ return Number.isNaN(Math[n]()) && Number.isNaN(Math[n](undefined)) && Number.isNaN(Math[n](NaN)); })`,
        `names.every(function(n){ var count=0; var x=Math[n]({valueOf:function(){ count++; return '0.5'; }}); return count===1 && Object.is(x,Math[n](0.5)); })`,
        `names.every(function(n){ var ok=false; try{ Math[n]({valueOf:function(){ throw 42; }}) }catch(e){ ok=e===42; } return ok; })`,
        `names.every(function(n){ var ok=false; try{ Math[n](Symbol()); }catch(e){ ok=e instanceof TypeError; } return ok; })`,
        `names.every(function(n){ var ok=false; try{ new Math[n](); }catch(e){ ok=e instanceof TypeError; } return ok; })`,
        `Math.cosh(null)===1 && Math.acosh(true)===0 && Math.fround('1.5')===1.5`,
    }
    // Cada run tem seu proprio global.
    prefix := `var names=['cosh','sinh','tanh','acosh','asinh','atanh','expm1','log1p','fround']; `
    for src in cases { v, ok := run(fmt.tprintf("%s%s", prefix, src)).(bool); testing.expect(t, ok && v, src) }
}

@(test)
math_added_methods_special_values :: proc(t: ^testing.T) {
    cases := []string{
        `['sinh','tanh','asinh','atanh','expm1','log1p','fround'].every(function(n){ return Object.is(Math[n](-0),-0) && Object.is(Math[n](0),0); })`,
        `Math.cosh(0)===1 && Math.cosh(-0)===1 && Math.cosh(Infinity)===Infinity && Math.cosh(-Infinity)===Infinity`,
        `Math.sinh(Infinity)===Infinity && Math.sinh(-Infinity)===-Infinity && Math.tanh(Infinity)===1 && Math.tanh(-Infinity)===-1`,
        `Math.asinh(Infinity)===Infinity && Math.asinh(-Infinity)===-Infinity && Math.acosh(Infinity)===Infinity && Math.acosh(1)===0`,
        `Number.isNaN(Math.acosh(0.5)) && Number.isNaN(Math.acosh(-Infinity)) && Number.isNaN(Math.atanh(1.1)) && Number.isNaN(Math.atanh(-Infinity))`,
        `Math.atanh(1)===Infinity && Math.atanh(-1)===-Infinity && Math.expm1(Infinity)===Infinity && Math.expm1(-Infinity)===-1`,
        `Math.log1p(-1)===-Infinity && Number.isNaN(Math.log1p(-1.1)) && Number.isNaN(Math.log1p(-Infinity)) && Math.log1p(Infinity)===Infinity`,
        `Math.fround(Infinity)===Infinity && Math.fround(-Infinity)===-Infinity && Math.fround(1e40)===Infinity && Math.fround(-1e40)===-Infinity`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
math_added_methods_precision :: proc(t: ^testing.T) {
    cases := []string{
        `Math.abs(Math.cosh(1)-1.5430806348152437)<1e-15 && Math.abs(Math.sinh(1)-1.1752011936438014)<1e-15 && Math.abs(Math.tanh(1)-0.7615941559557649)<1e-15`,
        `Math.abs(Math.acosh(2)-1.3169578969248166)<1e-15 && Math.abs(Math.asinh(1)-0.881373587019543)<1e-15 && Math.abs(Math.atanh(0.5)-0.5493061443340548)<1e-15`,
        `Math.abs(Math.expm1(0.25)-0.2840254166877415)<1e-16 && Math.abs(Math.expm1(-0.25)+0.22119921692859512)<1e-16`,
        `['sinh','tanh','asinh','atanh','expm1','log1p'].every(function(n){ return Math.abs(Math[n](1e-20)/1e-20-1)<1e-15 && Math.abs(Math[n](-1e-20)/-1e-20-1)<1e-15; })`,
        `Math.sinh(5e-324)===5e-324 && Math.expm1(5e-324)===5e-324 && Math.log1p(5e-324)===5e-324`,
        `Number.isFinite(Math.sinh(710)) && Number.isFinite(Math.cosh(710)) && Math.sinh(1000)===Infinity && Math.sinh(-1000)===-Infinity`,
        `Number.isFinite(Math.asinh(1e300)) && Number.isFinite(Math.acosh(1e300)) && Math.tanh(1000)===1 && Math.tanh(-1000)===-1`,
        `Math.fround(1.337)===1.3370000123977661 && Math.fround(16777217)===16777216 && Math.fround(16777219)===16777220`,
        `Math.fround(1.0000000596046448)===1 && Math.fround(1.0000001788139343)===1.000000238418579`,
        `Math.fround(Math.pow(2,-149))===Math.pow(2,-149) && Math.fround(Math.pow(2,-150))===0 && Object.is(Math.fround(-Math.pow(2,-150)),-0)`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
