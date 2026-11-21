package js

import "core:testing"

@(test)
test_proxy_get_prototype_protocol :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var target={}, proto={}, calls=0;
        var handler={getPrototypeOf(t){
            if(this===handler && t===target && arguments.length===1) calls++;
            return proto;
        }};
        var p=new Proxy(target,handler);
        var a=Object.getPrototypeOf(p)===proto;
        var b=Reflect.getPrototypeOf(p)===proto;
        var c=Object.getPrototypeOf(new Proxy(p,{}))===proto;
        var d=Reflect.getPrototypeOf(new Proxy(function(){}, {getPrototypeOf(){return null;}}))===null;
        var e=Object.getPrototypeOf(new Proxy([],{}))===Array.prototype;
        [a,b,c,d,e,calls].join(',')
    `).(string), "true,true,true,true,true,3")
}

@(test)
test_proxy_get_prototype_errors_and_invariants :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var proto={}, target=Object.preventExtensions(Object.create(proto));
        var good=new Proxy(target,{getPrototypeOf(){return proto;}});
        var closed=new Proxy(target,{getPrototypeOf(){return {};}});
        var r=Proxy.revocable({},{}); r.revoke();
        var sentinel={}, caught=false;
        try {Object.getPrototypeOf(new Proxy({}, {get getPrototypeOf(){throw sentinel;}}));}
        catch(e){caught=e===sentinel;}
        var ops=[function(){Object.getPrototypeOf(closed);},
            function(){Reflect.getPrototypeOf(new Proxy(closed,{}));},
            function(){Object.getPrototypeOf(new Proxy({}, {getPrototypeOf(){return 1;}}));},
            function(){Object.getPrototypeOf(new Proxy({}, {getPrototypeOf:3}));},
            function(){Object.getPrototypeOf(r.proxy);},
            function(){Reflect.getPrototypeOf(r.proxy);},
            function(){Reflect.getPrototypeOf(1);}];
        var errors=0;
        for(var i=0;i<ops.length;i++) try{ops[i]();}catch(e){if(e.name==='TypeError') errors++;}
        [Object.getPrototypeOf(good)===proto,caught,errors].join(',')
    `).(string), "true,true,7")
}

@(test)
test_symbol_replace_custom_dispatch :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var receiver={toString(){throw 'coerced receiver';}};
        var replacement={}, result={}, reads=0, calls=0;
        var proto={};
        Object.defineProperty(proto,Symbol.replace,{get(){
            reads++;
            return function(s,r){
                if(this===pattern && s===receiver && r===replacement && arguments.length===2) calls++;
                return result;
            };
        }});
        var pattern=Object.create(proto);
        pattern.toString=function(){throw 'coerced pattern';};
        var a=String.prototype.replace.call(receiver,pattern,replacement)===result;
        var b=String.prototype.replaceAll.call(receiver,pattern,replacement)===result;
        [typeof Symbol.replace, a,b,reads,calls].join(',')
    `).(string), "symbol,true,true,2,2")
}

@(test)
test_symbol_replace_errors_and_fallback :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var errors=0, sentinel={}, caught=0;
        var pattern={}; pattern[Symbol.replace]=3;
        try {'abc'.replace(pattern,'x');}catch(e){if(e.name==='TypeError')errors++;}
        try {'abc'.replaceAll(pattern,'x');}catch(e){if(e.name==='TypeError')errors++;}
        try {String.prototype.replace.call(null,pattern,'x');}catch(e){if(e.name==='TypeError')errors++;}
        Object.defineProperty(pattern,Symbol.replace,{get(){throw sentinel;}});
        try {'abc'.replace(pattern,'x');}catch(e){if(e===sentinel)caught++;}
        try {'abc'.replaceAll(pattern,'x');}catch(e){if(e===sentinel)caught++;}
        var fallback={toString(){return 'b';}}; fallback[Symbol.replace]=null;
        [errors,caught,'abc'.replace(fallback,'X'),'aba'.replaceAll(fallback,'X'),
            'aba'.replace(/a/g,'x')].join(',')
    `).(string), "3,2,aXc,aXa,xbx")
}
