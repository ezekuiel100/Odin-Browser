package js

// M67 (2026-07-10): Proxy e Reflect — base da reatividade do Vue 3. Um proxy é um
// ^Object com px_handler!=nil e hooks get/set → proxy_get/proxy_set; `in`, delete
// e ownKeys são interceptados em js_in/.Delete/own_enum_keys. Reflect.* opera no
// alvo. Desbloqueou ultra-photo.com (era "Proxy is not a constructor").

import "core:testing"

@(test)
test_proxy_get_trap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var p = new Proxy({a:1}, { get(t,k){ return k in t ? t[k]*10 : -1; } });
        p.a + ',' + p.zzz
    `).(string), "10,-1")
}

@(test)
test_proxy_set_trap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var target = {};
        var p = new Proxy(target, { set(t,k,v){ t[k] = v*2; return true; } });
        p.x = 21;
        target.x
    `).(f64), f64(42))
}

@(test)
test_proxy_default_forwarding :: proc(t: ^testing.T) {
    // sem trap: leitura/escrita vão direto ao alvo
    testing.expect_value(t, run(`
        var p = new Proxy({a:1,b:2}, {});
        p.c = 3;
        p.a + p.b + p.c
    `).(f64), f64(6))
}

@(test)
test_proxy_has_trap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var p = new Proxy({x:1}, { has(t,k){ return k === 'magic' || k in t; } });
        ('x' in p) && ('magic' in p) && !('no' in p)
    `).(bool), true)
}

@(test)
test_proxy_delete_trap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = '';
        var p = new Proxy({y:2}, { deleteProperty(t,k){ log = k; delete t[k]; return true; } });
        delete p.y;
        log + '|' + (('y' in p) ? 'yes' : 'no')
    `).(string), "y|no")
}

@(test)
test_proxy_ownkeys_forin :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var p = new Proxy({m:1, n:2}, {});
        var ks = [];
        for (var k in p) ks.push(k);
        Object.keys(p).join(',') + '|' + ks.join(',')
    `).(string), "m,n|m,n")
}

@(test)
test_proxy_over_array :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var p = new Proxy([10,20,30], { get(t,k,r){ return Reflect.get(t,k,r); } });
        p[1] + ',' + p.length
    `).(string), "20,3")
}

@(test)
test_proxy_vue_reactive_pattern :: proc(t: ^testing.T) {
    // o padrão EXATO do Vue 3: get/set delegam a Reflect com o receiver
    testing.expect_value(t, run(`
        var c = new Proxy({count:0}, {
            get(t,k,r){ return Reflect.get(t,k,r); },
            set(t,k,v,r){ return Reflect.set(t,k,v,r); }
        });
        c.count = 5;
        c.count += 10;
        c.count
    `).(f64), f64(15))
}

@(test)
test_proxy_not_constructor_error :: proc(t: ^testing.T) {
    // Proxy exige alvo/handler objeto
    testing.expect_value(t, run(`
        var msg = '';
        try { new Proxy(42, {}); } catch(e){ msg = e.name; }
        msg
    `).(string), "TypeError")
}

// ── Reflect ──────────────────────────────────────────────────────────────────

@(test)
test_reflect_get_set :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = {a:1};
        Reflect.set(o, 'b', 2);
        Reflect.get(o, 'a') + Reflect.get(o, 'b')
    `).(f64), f64(3))
}

@(test)
test_reflect_has :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = {a:1};
        Reflect.has(o,'a') && !Reflect.has(o,'z')
    `).(bool), true)
}

@(test)
test_reflect_ownkeys :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Reflect.ownKeys({p:1, q:2, r:3}).join(',')
    `).(string), "p,q,r")
}

@(test)
test_reflect_delete :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var o = {a:1, b:2};
        Reflect.deleteProperty(o, 'a');
        ('a' in o) ? 'has' : 'gone'
    `).(string), "gone")
}

@(test)
test_reflect_apply :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function add(a,b){ return a + b + this.base; }
        Reflect.apply(add, {base:100}, [1,2])
    `).(f64), f64(103))
}

@(test)
test_reflect_construct :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class Point { constructor(x,y){ this.x=x; this.y=y; } sum(){ return this.x+this.y; } }
        var p = Reflect.construct(Point, [3,4]);
        (p instanceof Point) ? p.sum() : -1
    `).(f64), f64(7))
}

@(test)
test_proxy_callable_paths :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function sum(x) { return this.base + x; }
        var seen = 0;
        var handler = { apply(t, r, a) { seen++; return Reflect.apply(t,r,a)*2; } };
        var p = new Proxy(sum, handler);
        var obj = {base:10, f:p};
        var a = obj.f(1), b = p.call({base:20},2);
        var c = p.apply({base:30},[3]), d = Reflect.apply(p,{base:40},[4]);
        var e = p.bind({base:50},5)();
        [typeof p,a,b,c,d,e,seen].join(',')
    `).(string), "function,22,44,66,88,110,5")
}

@(test)
test_proxy_nested_forwarding :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function F(v) { this.v=v; this.nt=new.target; return v; }
        var p=new Proxy(new Proxy(F,{}),{});
        var o=new p(7);
        [p.call({},3),o.v,o.nt===p,o instanceof F].join(',')
    `).(string), "3,7,true,true")
}

@(test)
test_proxy_construct_validation :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var p=new Proxy(function(){}, {construct(t,a,nt){return {v:a[0],nt:nt};}});
        var o=new p(9), r=Reflect.construct(p,[8]);
        var bad='';
        try { new (new Proxy(function(){},{construct(){return 1;}}))(); }
        catch(e){bad=e.name;}
        [o.v,o.nt===p,r.v,r.nt===p,bad].join(',')
    `).(string), "9,true,8,true,TypeError")
}

@(test)
test_proxy_ownkeys_trap_order_and_filter :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var count=0;
        var target={a:1,b:2};
        Object.defineProperty(target,'hidden',{value:3,enumerable:false});
        var p=new Proxy(target,{ownKeys(t){count++; return ['b','hidden','a'];}});
        var keys=Object.keys(p).join(',');
        var all=Reflect.ownKeys(p).join(',');
        var loop=[]; for(var k in p) loop.push(k);
        [keys,all,loop.join(','),count].join('|')
    `).(string), "b,a|b,hidden,a|b,a|3")
}

@(test)
test_proxy_ownkeys_symbols_and_invalid_results :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var s=Symbol('s');
        var p=new Proxy({}, {ownKeys(){return [s,'x'];},
            getOwnPropertyDescriptor(t,k){return {enumerable:true,configurable:true};}});
        var keys=Reflect.ownKeys(p), errors=0;
        var cases=[1,['x','x'],[3]];
        for(var i=0;i<cases.length;i++) {
            try { Reflect.ownKeys(new Proxy({}, {ownKeys(){return cases[i];}})); }
            catch(e){if(e.name==='TypeError') errors++;}
        }
        [keys[0]===s,keys[1],Object.keys(p).join(','),errors].join('|')
    `).(string), "true|x|x|3")
}

@(test)
test_proxy_revocable_operations :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r=Proxy.revocable(function(){return 4;},{}), p=r.proxy;
        var before=p(); r.revoke(); r.revoke();
        var ops=[function(){p();},function(){new p();},function(){p.x;},
            function(){p.x=1;},function(){'x' in p;},function(){delete p.x;},
            function(){Object.keys(p);},function(){Reflect.get(p,'x');},
            function(){Reflect.set(p,'x',1);},function(){Reflect.deleteProperty(p,'x');}];
        var count=0;
        for(var i=0;i<ops.length;i++) {try {ops[i]();} catch(e){if(e.name==='TypeError')count++;}}
        [before,typeof p,count].join(',')
    `).(string), "4,function,10")
}

@(test)
test_reflect_receiver_accessors_and_nested_proxies :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var base={get value(){return this.x;}};
        var target=Object.create(base); target.x=1;
        var receiver={x:42};
        var seen;
        var p=new Proxy(target,{get(t,k,r){seen=r;return Reflect.get(t,k,r);}});
        var nested=new Proxy(p,{});
        var a=Reflect.get(base,'value',receiver), b=Reflect.get(nested,'value',receiver);
        var same=seen===receiver;
        var reads=[];
        var reactive=new Proxy({x:7,get value(){return this.x;}},
            {get(t,k,r){reads.push(k);return Reflect.get(t,k,r);}});
        var c=reactive.value;
        [a,b,same,c,reads.join(',')].join('|')
    `).(string), "42|42|true|7|value,x")
}

@(test)
test_proxy_ownkeys_invariants :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var fixed={}; Object.defineProperty(fixed,'x',{value:1,configurable:false});
        var closed=Object.preventExtensions({x:1}), errors=0;
        var cases=[new Proxy(fixed,{ownKeys(){return [];}}),
            new Proxy(closed,{ownKeys(){return ['x','y'];}})];
        for(var i=0;i<cases.length;i++) {
            try { Reflect.ownKeys(cases[i]); } catch(e){if(e.name==='TypeError')errors++;}
        }
        errors
    `).(f64), f64(2))
}
