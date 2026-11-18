package js

import "core:testing"

// Objetos wrapper de primitivo. Antes `new String("a")` devolvia o PRIMITIVO
// (typeof "string") e `Object("a")` devolvia `{}`.
@(test)
primitive_wrappers :: proc(t: ^testing.T) {
    cases := []string{
        // typeof / instanceof / identidade
        `typeof new String('a')==='object' && typeof new Number(1)==='object' && typeof new Boolean(true)==='object'`,
        `new String('a') instanceof String && new Number(1) instanceof Number && new Boolean(false) instanceof Boolean`,
        `Object('a') instanceof String && Object(1) instanceof Number && Object(true) instanceof Boolean && new Object('a') instanceof String`,
        `var o={}; Object(o)===o && Object(1)!==Object(1) && typeof Object(null)==='object' && typeof Object()==='object'`,
        `Object.getPrototypeOf(new String('a'))===String.prototype && new Number(1).constructor===Number`,
        // chamada sem new segue devolvendo o primitivo
        `typeof String(1)==='string' && typeof Number('2')==='number' && typeof Boolean(0)==='boolean'`,
        `String()==='' && Number()===0 && Boolean()===false && String(undefined)==='undefined'`,
        // truthiness: wrapper de false é objeto, logo truthy
        `!!new Boolean(false) && !!new Number(0) && !!new String('')`,
        // ToPrimitive / igualdade / aritmética
        `new String('a')=='a' && new String('a')!=='a' && new Number(5)+1===6 && new Number(2)*new Number(3)===6`,
        `new String('ab')+'c'==='abc' && String(new String('x'))==='x' && ''+new Number(7)==='7'`,
        `new Number(5).valueOf()===5 && new String('q').valueOf()==='q' && new Boolean(false).valueOf()===false`,
        `new Number(1.5).toFixed(2)==='1.50' && new Number(255).toString(16)==='ff' && new Boolean(true).toString()==='true'`,
        `Number.prototype.toFixed.call(new Number(2),1)==='2.0' && Boolean.prototype.valueOf.call(new Boolean(true))===true`,
        `var ok=false; try{ Boolean.prototype.valueOf.call({}) }catch(e){ ok=e instanceof TypeError } ok`,
        // String wrapper: length, índices, métodos, chaves próprias
        `var s=new String('ab'); s.length===2 && s[0]==='a' && s[1]==='b' && s[2]===undefined && s['1']==='b'`,
        `new String('abc').toUpperCase()==='ABC' && new String('a,b').split(',').length===2 && new String('abc').slice(1)==='bc'`,
        `Object.keys(new String('ab')).join()==='0,1' && Object.getOwnPropertyNames(new String('ab')).join()==='0,1,length'`,
        `var s=new String('ab'); s.x=1; Object.keys(s).join()==='0,1,x'`,
        // Object.prototype.toString
        `Object.prototype.toString.call(new String(''))==='[object String]' && Object.prototype.toString.call(Object(1))==='[object Number]' && Object.prototype.toString.call(new Boolean(1))==='[object Boolean]'`,
        `Object.prototype.toString.call(new Date(0))==='[object Date]'`,
        // JSON desembrulha
        `JSON.stringify([new String('a'), new Number(1), new Boolean(false)])==='["a",1,false]'`,
        `JSON.stringify({a:new Number(3)})==='{"a":3}'`,
        // Reflect.construct (o feature-detect do _createSuper do Babel)
        `Boolean.prototype.valueOf.call(Reflect.construct(Boolean,[],function(){}))===false`,
        // subclasse
        `class S extends String { shout(){ return this.toUpperCase()+'!' } } var s=new S('hi'); s.shout()==='HI!' && s.length===2 && s instanceof String && s instanceof S`,
        // new String chamando String() de dentro do toString do argumento não vaza o "new"
        `var inner; var w=new String({toString:function(){ inner=String(1); return 'z' }}); typeof inner==='string' && w.valueOf()==='z'`,
        // os protótipos SÃO wrappers (spec)
        `Boolean.prototype.toString()==='false' && Number.prototype.valueOf()===0 && String.prototype.valueOf()==='' && String.prototype.length===0`,
        // método vem só da cadeia: apagado do protótipo, cai no de Object
        `var f=Boolean.prototype.toString; delete Boolean.prototype.toString; var r=new Boolean().toString(); Boolean.prototype.toString=f; r==='[object Boolean]'`,
        `Number.length===1 && Boolean.length===1 && String.length===1`,
        // StringToNumber estrito
        `isNaN(Number('INFINITY')) && isNaN(Number('inf')) && isNaN(Number('nan')) && isNaN(Number('1_000')) && Number('-Infinity')===-Infinity && Number(' 1e3 ')===1000`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
