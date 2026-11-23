package js

import "core:testing"

@(test)
test_function_own_keys_and_descriptors :: proc(t: ^testing.T) {
    result, _ := run(`
        function f(a, b) {}
        let first = Symbol("first"), second = Symbol("second");
        f.z = 1; f[first] = 2; f.a = 3; f[10] = 4; f[2] = 5;
        f["4294967295"] = 6; f[second] = 7;
        Object.defineProperty(f, "a", {get() {return 8;}});
        Object.defineProperty(f, "a", {value: 9, writable: true});
        delete f.z; f.z = 10;
        let p = new Proxy(f, {});
        let keys = Reflect.ownKeys(p).map(String).join();
        let descriptors = Object.getOwnPropertyDescriptors(p);
        keys === "2,10,length,name,prototype,a,4294967295,z,Symbol(first),Symbol(second)" &&
            Object.keys(f).join() === "2,10,a,4294967295,z" &&
            Object.getOwnPropertyNames(f).join() === "2,10,length,name,prototype,a,4294967295,z" &&
            Object.getOwnPropertySymbols(f)[0] === first &&
            Reflect.ownKeys(descriptors).map(String).join() === keys &&
            descriptors[first].value === 2 && descriptors.a.value === 9 &&
            descriptors.length.value === 2 && !descriptors.name.writable &&
            descriptors.name.configurable && !descriptors.prototype.configurable &&
            Reflect.set(f, "name", "wrong") === false &&
            Reflect.deleteProperty(p, "prototype") === false &&
            Reflect.deleteProperty(p, "name") && !Object.hasOwn(p, "name") &&
            Reflect.defineProperty(p, "name", {value: "new", enumerable: true}) &&
            Object.keys(p).join() === "2,10,a,4294967295,z,name" && f.name === "new";
    `).(bool)
    testing.expect(t, result, "function keys and descriptors agree across Object, Reflect and Proxy")
    inferred, _ := run(`
        const C = class { static { Reflect.ownKeys(this); } };
        const D = class { static { Object.defineProperty(this, "name", {value: "custom"}); } };
        C.name === "C" && D.name === "custom";
    `).(bool)
    testing.expect(t, inferred, "reflection preserves binding inference and explicit names")
}

@(test)
test_array_own_keys_and_descriptors :: proc(t: ^testing.T) {
    result, _ := run(`
        let a = [, "one"], s = Symbol("key");
        a.z = 1; a[s] = 2;
        Object.defineProperties(a, {
            0: {get() {return 3;}, enumerable: false},
            b: {value: 4, configurable: true, enumerable: true},
            a: {value: 5, enumerable: true}
        });
        delete a.b; a.b = 6;
        let p = new Proxy(a, {});
        let descriptors = Object.getOwnPropertyDescriptors(p);
        Reflect.ownKeys(p).map(String).join() === "0,1,length,z,a,b,Symbol(key)" &&
            Object.keys(p).join() === "1,z,a,b" && Object.getOwnPropertySymbols(a)[0] === s &&
            descriptors[0].get() === 3 && !descriptors[0].enumerable && descriptors[s].value === 2 &&
            descriptors.length.value === 2 && !descriptors.length.configurable &&
            Reflect.defineProperty(p, "length", {configurable: true}) === false &&
            Reflect.deleteProperty(p, "length") === false;
    `).(bool)
    testing.expect(t, result, "array indices, length, expandos and symbols share own-key order")
}

@(test)
test_proxy_own_property_traps :: proc(t: ^testing.T) {
    result, _ := run(`
        let target = () => 0;
        target.z = 1;
        let trace = "";
        let p = new Proxy(target, {
            ownKeys() {return ["name", "z", "length"];},
            getOwnPropertyDescriptor(t, k) {
                trace += k + ",";
                return Reflect.getOwnPropertyDescriptor(t, k);
            },
            defineProperty(t, k, d) {return Reflect.defineProperty(t, k, d);}
        });
        let keys = Object.keys(p).join();
        let traceAfterKeys = trace;
        Object.defineProperty(p, "z", {value: 8});
        let reject = new Proxy(target, {defineProperty() {return false;}});
        let fixed = Object.defineProperty({}, "x", {value: 1});
        let invalid = new Proxy(fixed, {getOwnPropertyDescriptor() {return undefined;}});
        let failed = false;
        try { Object.getOwnPropertyDescriptors(invalid); } catch (e) { failed = e instanceof TypeError; }
        keys === "z" && traceAfterKeys === "name,z,length," &&
            target.z === 8 && Reflect.defineProperty(reject, "z", {value: 9}) === false && failed;
    `).(bool)
    testing.expect(t, result, "proxy descriptor traps preserve reported order and respect protected keys")
}
