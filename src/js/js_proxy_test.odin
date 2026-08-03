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
