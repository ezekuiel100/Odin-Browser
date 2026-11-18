package js

import "core:testing"

// startsWith/endsWith com posição, Math.round no empate negativo e $<nome> no replace.
@(test)
string_starts_ends_position :: proc(t: ^testing.T) {
    cases := []string{
        `'abc'.startsWith('b',1) && !'abc'.startsWith('a',1) && 'abc'.startsWith('')`,
        `'abc'.endsWith('a',1) && 'abc'.endsWith('ab',2) && !'abc'.endsWith('c',2)`,
        `'abc'.startsWith('a',-5) && 'abc'.startsWith('',99) && !'abc'.startsWith('c',Infinity) && 'abc'.startsWith('a',NaN)`,
        `'abc'.endsWith('c',99) && 'abc'.endsWith('',-1) && !'abc'.endsWith('a',-1) && 'abc'.endsWith('c',undefined)`,
        `'abc'.startsWith('b',{valueOf:function(){ return 1 }}) && 'a1'.endsWith(1)`,
        `'héllo'.startsWith('llo',2) && 'héllo'.endsWith('hé',2)`,
        `var ok=false; try{ 'a/a/'.startsWith(/a/) }catch(e){ ok=e instanceof TypeError } ok`,
        `var ok=false; try{ 'abc'.endsWith('c',{valueOf:function(){ throw 7 }}) }catch(e){ ok=e===7 } ok`,
        `String.prototype.startsWith.call(123,'12') && new String('xy').endsWith('y')`,
        `var ok=false; try{ String.prototype.startsWith.call(null,'a') }catch(e){ ok=e instanceof TypeError } ok`,
        `var n=0; ['startsWith','endsWith','includes'].forEach(function(m){ try{ 'Symbol()'[m](Symbol()) }catch(e){ if(e instanceof TypeError) n++ } }); n===3`,
        `var ok=false; try{ String.prototype.endsWith.call(Symbol(),'a') }catch(e){ ok=e instanceof TypeError } ok && String(Symbol('d'))==='Symbol(d)'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
math_round_spec :: proc(t: ^testing.T) {
    cases := []string{
        `1/Math.round(-0.5)===-Infinity && 1/Math.round(-0.2)===-Infinity && 1/Math.round(-0)===-Infinity && 1/Math.round(0.2)===Infinity`,
        `Math.round(-0.6)===-1 && Math.round(-1.5)===-1 && Math.round(-2.5)===-2 && Math.round(2.5)===3 && Math.round(0.5)===1`,
        `Math.round(0.49999999999999994)===0 && Math.round(-0.49999999999999994)===0`,
        `Math.round(4503599627370495.5)===4503599627370496 && Math.round(9007199254740991)===9007199254740991`,
        `isNaN(Math.round(NaN)) && Math.round(Infinity)===Infinity && Math.round({valueOf:function(){ return 1.6 }})===2`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
replace_named_groups :: proc(t: ^testing.T) {
    cases := []string{
        `'2024-03-07'.replace(/(?<y>\d+)-(?<m>\d+)-(?<d>\d+)/,'$<d>/$<m>/$<y>')==='07/03/2024'`,
        `'ab'.replace(/(?<x>a)/,'[$<x>]')==='[a]b' && 'aa'.replace(/(?<x>a)/g,'<$<x>>')==='<a><a>'`,
        // nome inexistente / grupo que não casou → "", sem `>` fica literal
        `'ab'.replace(/(?<x>a)/,'[$<nope>]')==='[]b' && 'ab'.replace(/(?<x>z)?a/,'[$<x>]')==='[]b'`,
        `'ab'.replace(/(?<x>a)/,'[$<x]')==='[$<x]b'`,
        // sem grupos nomeados `$<` é literal
        `'ab'.replace(/(a)/,'[$<x>]')==='[$<x>]b' && 'ab'.replace('a','$<x>')==='$<x>b'`,
        // o callback recebe o objeto groups por último
        `'ab'.replace(/(?<x>a)/,function(m,p1,off,s,g){ return g.x+off+s })==='a0abb'`,
        `var n; 'ab'.replace(/(a)/,function(){ n=arguments.length; return '' }); n===4`,
        // ordem das chaves de groups = ordem no padrão; protótipo nulo
        `var g=/(?<z>a)(?<b>b)(?<m>c)/.exec('abc').groups; Object.keys(g).join()==='z,b,m' && Object.getPrototypeOf(g)===null`,
        `'abc'.match(/(?<z>a)(?<b>b)/).groups.b==='b'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
