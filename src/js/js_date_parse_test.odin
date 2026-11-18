package js

import "core:testing"

// Date.parse além do ISO + toString/toUTCString no formato da spec. Antes, tudo
// fora de `YYYY-MM-DD[THH:MM…]` dava NaN e toString devolvia o ISO.
// (local == UTC neste motor: hora sem fuso é lida como UTC.)
@(test)
date_parse_formats :: proc(t: ^testing.T) {
    cases := []string{
        // ISO: formas reduzidas, ano estendido, frações, 24:00
        `Date.parse('1970')===0 && Date.parse('1970-02')===31*864e5`,
        `Date.parse('+002020-01-01T00:00:00Z')===Date.parse('2020-01-01T00:00:00Z')`,
        `Date.parse('-000001-01-01T00:00:00Z')===-62198755200000`,
        `isNaN(Date.parse('-000000-01-01T00:00:00Z'))`,
        `Date.parse('1970-01-01T00:00:00.5Z')===500 && Date.parse('1970-01-01T00:00:00.1234Z')===123`,
        `Date.parse('1970-01-01T24:00:00Z')===864e5 && isNaN(Date.parse('1970-01-01T24:00:01Z'))`,
        `Date.parse('1970-01-01T01:00+01:00')===0 && Date.parse('1970-01-01T00:00:00-0130')===5400000`,
        `isNaN(Date.parse('2021-02-29')) && Date.parse('2020-02-29')===1582934400000`,
        `isNaN(Date.parse('1970-13-01')) && isNaN(Date.parse('1970-01-01T25:00Z'))`,
        // legado: nome de mês
        `Date.parse('Jan 1, 1970')===0 && Date.parse('January 1 1970')===0`,
        `Date.parse('1 Jan 1970')===0 && Date.parse('1970 Jan 1')===0`,
        `Date.parse('March 5, 2024')===Date.parse('2024-03-05')`,
        `Date.parse('Mar 7, 2024 3:45 PM')===Date.parse('2024-03-07T15:45:00Z')`,
        `Date.parse('Mar 7, 2024 12:05 am')===Date.parse('2024-03-07T00:05:00Z')`,
        `Date.parse('Mar 7, 2024 12:05 p.m.')===Date.parse('2024-03-07T12:05:00Z')`,
        // RFC 2822 / cabeçalho HTTP, com fuso
        `Date.parse('Thu, 01 Jan 1970 00:00:00 GMT')===0`,
        `Date.parse('Thu, 01 Jan 1970 01:00:00 +0100')===0`,
        `Date.parse('Thu, 01 Jan 1970 00:00:00 GMT-0500')===5*36e5`,
        `Date.parse('Wed, 31 Dec 1969 19:00:00 EST')===0`,
        `Date.parse('Jan 1 1970 00:00:00 GMT+01:00')===-36e5`,
        // numérico: M/D/Y (EUA) e Y/M/D
        `Date.parse('1/2/2020')===Date.parse('2020-01-02')`,
        `Date.parse('2020/01/02')===Date.parse('2020-01-02') && Date.parse('2020-1-2')===Date.parse('2020-01-02')`,
        `Date.parse('12/31/1999 23:59:59')===Date.parse('1999-12-31T23:59:59Z')`,
        `Date.parse('1/2/99')===Date.parse('1999-01-02') && Date.parse('1/2/20')===Date.parse('2020-01-02')`,
        // inválidos seguem NaN
        `isNaN(Date.parse('')) && isNaN(Date.parse('hello')) && isNaN(Date.parse('Foo 1, 2020'))`,
        `isNaN(Date.parse('Feb 30, 2020')) && isNaN(Date.parse('13/1/2020')) && isNaN(Date.parse('1 2'))`,
        // ToString do argumento
        `Date.parse({toString:function(){ return '1970-01-01T00:00:00Z' }})===0`,
        `new Date('Jan 1, 1970').getTime()===0`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
date_string_formats :: proc(t: ^testing.T) {
    cases := []string{
        `new Date(0).toString()==='Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)'`,
        `new Date(0).toDateString()==='Thu Jan 01 1970'`,
        `new Date(0).toTimeString()==='00:00:00 GMT+0000 (Coordinated Universal Time)'`,
        `new Date(0).toUTCString()==='Thu, 01 Jan 1970 00:00:00 GMT'`,
        `Date.prototype.toGMTString===Date.prototype.toUTCString`,
        `String(new Date(NaN))==='Invalid Date' && new Date(NaN).toUTCString()==='Invalid Date'`,
        `new Date(Date.UTC(-1,0,1)).toUTCString()==='Fri, 01 Jan -0001 00:00:00 GMT'`,
        // a ida e volta que a spec exige
        `var d=new Date(2024,2,7,15,45,12); Date.parse(d.toString())===Math.floor(d.getTime()/1000)*1000`,
        `var d=new Date(2024,2,7,15,45,12); Date.parse(d.toUTCString())===d.getTime()`,
        `var d=new Date(1e12); Date.parse(d.toISOString())===1e12`,
        // toISOString: inválida lança, ano estendido
        `var ok=false; try{ new Date(NaN).toISOString() }catch(e){ ok=e instanceof RangeError } ok`,
        `new Date(8.64e15).toISOString()==='+275760-09-13T00:00:00.000Z'`,
        `new Date(-62198755200000).toISOString()==='-000001-01-01T00:00:00.000Z'`,
        // toJSON: inválida → null, e é genérico
        `JSON.stringify({d:new Date(NaN)})==='{"d":null}' && JSON.stringify(new Date(0))==='"1970-01-01T00:00:00.000Z"'`,
        `Date.prototype.toJSON.call({toISOString:function(){ return 'x' }})==='x'`,
        // TimeClip
        `isNaN(new Date(8.64e15+1).getTime()) && new Date(1.7).getTime()===1`,
        `var d=new Date(0); d.setTime(9e15); isNaN(d.getTime())`,
        // brand check
        `var ok=false; try{ Date.prototype.toString.call({}) }catch(e){ ok=e instanceof TypeError } ok`,
        // toJSON propaga a exceção do getter de toISOString
        `var ok=false; try{ Date.prototype.toJSON.call({get toISOString(){ throw 7 }}) }catch(e){ ok=e===7 } ok`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

// Date.UTC e new Date(y, m, ...) por MakeDay/MakeTime/MakeDate em f64.
@(test)
date_components :: proc(t: ^testing.T) {
    cases := []string{
        `Date.UTC(1970)===0 && isNaN(Date.UTC())`,
        `Date.UTC(0)===Date.UTC(1900,0) && Date.UTC(99,0)===Date.UTC(1999,0) && Date.UTC(100,0)===-59011459200000`,
        `isNaN(Date.UTC(NaN)) && isNaN(Date.UTC(1970,NaN)) && isNaN(Date.UTC(1970,0,1,0,0,0,NaN))`,
        `Date.UTC(1970,12)===Date.UTC(1971,0) && Date.UTC(1970,-1)===Date.UTC(1969,11)`,
        `Date.UTC(1970,0,1,80063993375,29,1,-288230376151711740)===29312`,
        `Date.UTC(1970,0,213503982336,0,0,0,-18446744073709552000)===34447360`,
        `var log=''; function v(n,x){ return {valueOf:function(){ log+=n; return x }} } Date.UTC(v('y',1970),v('m',0),v('d',1),v('h',0),v('i',0),v('s',0),v('l',0)); log==='ymdhisl'`,
        `var ok=false; try{ Date.UTC({valueOf:function(){ throw 7 }}) }catch(e){ ok=e===7 } ok`,
        `Date.UTC(1970,0,1.9,0.5)===0`,
        // o construtor usa o mesmo caminho
        `new Date(2024,0,31,12).getTime()===Date.UTC(2024,0,31,12) && new Date(99,0).getFullYear()===1999`,
        `isNaN(new Date(2024,NaN).getTime()) && new Date(2024,1,30).getDate()===1`,
        // 1 argumento: ToPrimitive (valueOf numérico ou string de data)
        `new Date({valueOf:function(){ return 5 }}).getTime()===5 && new Date({toString:function(){ return 'Jan 1, 1970' }, valueOf:undefined}).getTime()===0`,
        `var d=new Date(7); new Date(d).getTime()===7`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
