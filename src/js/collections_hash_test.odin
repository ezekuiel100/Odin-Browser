package js

import "core:testing"

@(test)
collections_hash_semantics :: proc(t: ^testing.T) {
    testing.expect(t, run(`
        var o = {}, p = {}, a = Symbol('x'), b = Symbol('x');
        var m = new Map();
        m.set(NaN, 1); m.set(0/0, 2); m.set(-0, 3); m.set(0, 4);
        m.set(1, 5); m.set(true, 6); m.set('1', 7);
        m.set(o, 8); m.set(p, 9); m.set(a, 10); m.set(b, 11);
        m.set(12345678901234567890n, 12); m.set(BigInt('12345678901234567890'), 13);
        m.size === 10 && m.get(NaN) === 2 && m.get(-0) === 4 &&
        m.get(1) === 5 && m.get(true) === 6 && m.get('1') === 7 &&
        m.get(o) === 8 && m.get(p) === 9 && m.get(a) === 10 &&
        m.get(b) === 11 && m.get(12345678901234567890n) === 13
    `) == true)
}

@(test)
collections_hash_mutation :: proc(t: ^testing.T) {
    testing.expect(t, run(`
        var s = new Set([1,2,3]), seen = '';
        s.forEach(function(v) {
            seen += v;
            if (v === 1) { s.delete(1); s.delete(2); s.add(4); }
            if (v === 3) { s.clear(); s.add(5); }
        });
        seen === '135' && s.size === 1 && s.has(5) && !s.has(1)
    `) == true)
}

@(test)
collections_hash_compaction :: proc(t: ^testing.T) {
    testing.expect(t, run(`
        var m = new Map();
        for (var i = 0; i < 2000; i++) m.set(i, i);
        for (var i = 0; i < 1900; i++) m.delete(i);
        m.set(2000, 7); m.set(1900, 9); m.delete(1901); m.set(1901, 10);
        var keys = [...m.keys()], clone = structuredClone(m);
        keys.length === 101 && keys[0] === 1900 && keys[100] === 1901 &&
        m.size === 101 && clone.get(1900) === 9 && clone.get(1901) === 10 &&
        clone.delete(1900) && !clone.has(1900) && !m.has(100)
    `) == true)
}
