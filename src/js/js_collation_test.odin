package js

import "core:testing"

@(test)
locale_compare_portuguese_sort :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var names=['Zuleica','\u00c1lvaro','Bruno','\u00c2ngela','Ana','\u00c9rica','Carlos'];
        names.sort(function(a,b){return a.localeCompare(b,'pt-BR');}).join(',')
    `).(string), "\u00c1lvaro,Ana,\u00c2ngela,Bruno,Carlos,\u00c9rica,Zuleica")
}

@(test)
collator_portuguese_matches_locale_compare :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        var c=new Intl.Collator(['pt-BR']);
        var words=['zebra','\u00e1rvore','a\u00e7\u00e3o','acorde','casa','ca\u00e7a'];
        var a=words.slice().sort(c.compare);
        var b=words.slice().sort(function(x,y){return x.localeCompare(y,'pt-BR');});
        a.join(',')===b.join(',') && a[0]==='a\u00e7\u00e3o' && a[a.length-1]==='zebra'
    `)))
}

@(test)
locale_compare_sensitivity :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        'a'.localeCompare('\u00e1','pt-BR',{sensitivity:'base'})===0 &&
        'A'.localeCompare('a','pt-BR',{sensitivity:'base'})===0 &&
        'a'.localeCompare('\u00e1','pt-BR',{sensitivity:'accent'})!==0 &&
        'A'.localeCompare('a','pt-BR',{sensitivity:'accent'})===0 &&
        'a'.localeCompare('\u00e1','pt-BR',{sensitivity:'case'})===0 &&
        'A'.localeCompare('a','pt-BR',{sensitivity:'case'})!==0 &&
        'a'.localeCompare('\u00e1','pt-BR')!==0
    `)))
}

@(test)
locale_compare_canonical_equivalence_and_nul :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        'caf\u00e9'.localeCompare('cafe\u0301','pt-BR')===0 &&
        'a\u0000b'.localeCompare('a\u0000c','pt-BR')<0 &&
        ''.localeCompare('a','pt-BR')<0 && ''.localeCompare('','pt-BR')===0
    `)))
}

@(test)
locale_compare_numeric_punctuation_case_first :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        'item2'.localeCompare('item10','pt-BR',{numeric:true})<0 &&
        'item2'.localeCompare('item10','pt-BR',{numeric:false})>0 &&
        'a-b'.localeCompare('ab','pt-BR',{ignorePunctuation:true})===0 &&
        'a-b'.localeCompare('ab','pt-BR',{ignorePunctuation:false})!==0 &&
        'A'.localeCompare('a','pt-BR',{caseFirst:'upper'})<0 &&
        'A'.localeCompare('a','pt-BR',{caseFirst:'lower'})>0
    `)))
}

@(test)
locale_compare_other_languages :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        '\u00e4'.localeCompare('z','de')<0 &&
        '\u00e4'.localeCompare('z','sv')>0 &&
        'I'.localeCompare('\u0131','tr',{sensitivity:'base'})===0
    `)))
}

@(test)
locale_compare_coercion :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        var compare=String.prototype.localeCompare;
        compare.call(12,2,'pt-BR')<0 &&
        compare.call({toString(){return 'Ana';}},'Bruno','pt-BR')<0 &&
        '12'.localeCompare({toString(){return '2';}},'pt-BR')<0 &&
        'undefined'.localeCompare(undefined,'pt-BR')===0
    `)))
}

@(test)
locale_compare_invalid_inputs :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var errors=[];
        var calls=[function(){'a'.localeCompare('b','pt_BR');},
            function(){new Intl.Collator('pt_BR');},
            function(){'a'.localeCompare('b','pt-BR',{sensitivity:'bad'});},
            function(){'a'.localeCompare('b','pt-BR',{caseFirst:'bad'});},
            function(){String.prototype.localeCompare.call(null,'a');},
            function(){'a'.localeCompare(Symbol('s'));},
            function(){'a'.localeCompare('b','pt-BR',null);}];
        for(var i=0;i<calls.length;i++) {try {calls[i]();} catch(e){errors.push(e.name);}}
        errors.join(',')
    `).(string), "RangeError,RangeError,RangeError,RangeError,TypeError,TypeError,TypeError")
}

@(test)
collator_options_snapshot_and_getters :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        var reads=0;
        var options=Object.create({get sensitivity(){reads++;return 'base';}});
        options.numeric=true; options.caseFirst='upper'; options.ignorePunctuation=true;
        var c=new Intl.Collator('pt-BR',options);
        options.numeric=false;
        var opts=c.resolvedOptions(), compare=c.compare;
        reads===1 && compare('\u00c1','a')===0 && compare('item2','item10')<0 &&
        compare.call(new Intl.NumberFormat('pt-BR'),'a','A')===0 &&
        opts.sensitivity==='base' && opts.numeric===true && opts.caseFirst==='upper' &&
        opts.ignorePunctuation===true && opts.usage==='sort'
    `)))
}

@(test)
locale_compare_unicode_extensions :: proc(t: ^testing.T) {
    testing.expect(t, truthy(run(`
        new Intl.Collator('pt-BR-u-kn').resolvedOptions().numeric===true &&
        '2'.localeCompare('10','pt-BR-u-kn')<0 &&
        '2'.localeCompare('10','pt-BR-u-kn',{numeric:false})>0
    `)))
}
