package js

import "core:testing"

@(test)
weak_constructor_rejects_invalid_arguments :: proc(t: ^testing.T) {
    for code in ([]string{
        `var caught=false;try{new WeakRef(1)}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{new FinalizationRegistry(1)}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{new WeakRef()}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{new FinalizationRegistry()}catch(e){caught=e instanceof TypeError}caught`,
        `var n=0;for(var x of [undefined,null,false,0,NaN,'',1n,Symbol.for('registered')]){try{new WeakRef(x)}catch(e){if(e instanceof TypeError)n++}}n===8`,
        `var n=0;for(var x of [undefined,null,false,0,'',1n,Symbol(),{},[],{call:function(){}}]){try{new FinalizationRegistry(x)}catch(e){if(e instanceof TypeError)n++}}n===10`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
weak_constructor_requires_new :: proc(t: ^testing.T) {
    for code in ([]string{
        `var caught=false;try{WeakRef({})}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{WeakRef.call({}, {})}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{FinalizationRegistry(function(){})}catch(e){caught=e instanceof TypeError}caught`,
        `var caught=false;try{FinalizationRegistry.call({},function(){})}catch(e){caught=e instanceof TypeError}caught`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
weak_constructor_accepts_valid_arguments :: proc(t: ^testing.T) {
    for code in ([]string{
        `var ok=true;for(var x of [{},[],function(){},/x/,new Map(),new Set(),new Number(1),Symbol(),Symbol.iterator]){var r=new WeakRef(x);ok=ok && r instanceof WeakRef && r.deref()===x}ok`,
        `var called=false;function cb(){called=true}var ok=true;for(var f of [cb,()=>{},cb.bind(null),new Proxy(cb,{}),function*(){},async function(){}]){ok=ok && new FinalizationRegistry(f) instanceof FinalizationRegistry}ok && !called`,
        `var x={};var C=WeakRef.bind(null,x);var r=new C();r instanceof WeakRef && r.deref()===x`,
        `var C=FinalizationRegistry.bind(null,function(){});new C() instanceof FinalizationRegistry`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}
