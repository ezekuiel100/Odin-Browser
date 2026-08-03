// Sonda de capacidade da LINGUAGEM (sem DOM). Roda por: browser.exe --js262 probe_lang.js
// Cada teste devolve true (OK) ou qualquer outra coisa (BAD). Exceção = FAIL.
var out = [];
var cat = "";
function C(c) { cat = c; }
function T(name, fn) {
  var r;
  try { r = fn(); } catch (e) {
    var m = "?";
    try { m = (e && e.name ? e.name + ": " : "") + (e && e.message ? e.message : String(e)); } catch (e2) {}
    out.push("FAIL\t" + cat + "\t" + name + "\t" + m);
    return;
  }
  if (r === true) out.push("OK\t" + cat + "\t" + name);
  else out.push("BAD\t" + cat + "\t" + name + "\tgot=" + strv(r));
}
function strv(v) { try { return String(v); } catch (e) { return "<unstringable>"; } }
// S: sonda de SINTAXE via eval. Compara o valor produzido (o parser recupera de erro
// em vez de lançar, então "parseou" não prova nada — só o valor prova).
function S(name, code, expected) {
  T(name, function () {
    var got = eval(code);
    return got === expected ? true : "got=" + strv(got) + " want=" + strv(expected);
  });
}

// ─────────────────────────── SINTAXE / GRAMÁTICA ───────────────────────────
C("sintaxe");
S("optional catch binding", "(function(){ try { null.x } catch { return 'c' } })()", "c");
S("exponenciacao **", "2 ** 10", 1024);
S("numeric separator", "1_000_000", 1000000);
S("logical assignment &&=", "(function(){ var a = 1; a &&= 5; return a })()", 5);
S("logical assignment ??=", "(function(){ var a = null; a ??= 7; return a })()", 7);
S("optional chaining call", "(function(){ var o = {}; return o.f?.() === undefined ? 'u' : 'x' })()", "u");
S("spread em chamada", "Math.max(...[1,9,3])", 9);
S("default param", "(function(a, b = 3){ return a + b })(1)", 4);
S("destructuring com default", "(function(){ var { a = 5 } = {}; return a })()", 5);
S("destructuring aninhado", "(function(){ var { a: { b } } = { a: { b: 2 } }; return b })()", 2);
S("rest em objeto", "(function(){ var { a, ...r } = { a: 1, b: 2, c: 3 }; return r.b + r.c })()", 5);
S("for-of com entries", "(function(){ var s = 0; for (var [k, v] of [[1,2]]) s = k + v; return s })()", 3);
S("labeled continue", "(function(){ var n = 0; a: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { if (j) continue a; n++ } } return n })()", 3);
S("getter em literal", "(function(){ var o = { get x(){ return 9 } }; return o.x })()", 9);
S("setter em literal", "(function(){ var v; var o = { set x(n){ v = n } }; o.x = 4; return v })()", 4);
S("computed key", "(function(){ var k = 'z'; var o = { [k]: 1 }; return o.z })()", 1);
S("shorthand method", "(function(){ var o = { m(){ return 3 } }; return o.m() })()", 3);
S("__proto__ em literal", "(function(){ var b = { f(){ return 'b' } }; var o = { __proto__: b }; return o.f() })()", "b");
S("classe: campo publico", "(function(){ class A { x = 1 }; return new A().x })()", 1);
S("classe: campo privado", "(function(){ class A { #x = 2; g(){ return this.#x } }; return new A().g() })()", 2);
S("classe: metodo privado", "(function(){ class A { #m(){ return 3 } g(){ return this.#m() } }; return new A().g() })()", 3);
S("classe: static block", "(function(){ class A { static v; static { A.v = 4 } }; return A.v })()", 4);
S("classe: #x in obj", "(function(){ class A { #x = 1; static has(o){ return #x in o } }; return A.has(new A()) })()", true);
S("classe: getter/setter", "(function(){ class A { get v(){ return 5 } }; return new A().v })()", 5);
S("classe: extends + super", "(function(){ class A { m(){ return 1 } }; class B extends A { m(){ return super.m() + 1 } }; return new B().m() })()", 2);
S("new.target", "(function(){ function F(){ return new.target === F ? 'y' : 'n' }; return new F() instanceof F ? (function(){ var r; F.call(null); return 'n2' })() : 'x' })()", "n2");
S("generator", "(function(){ function* g(){ yield 1; yield 2 }; var s = 0; for (var v of g()) s += v; return s })()", 3);
S("generator delegate yield*", "(function(){ function* a(){ yield 1 }; function* b(){ yield* a(); yield 2 }; return [...b()].join(',') })()", "1,2");
S("async generator + for await", "(function(){ return typeof (async function*(){ yield 1 }) })()", "function");
S("tagged template", "(function(){ function t(s, v){ return s[0] + v + s.raw[1] }; return t`a${1}b` })()", "a1b");
S("template multilinha", "(function(){ return `a\\nb`.length })()", 3);
S("arrow this lexico", "(function(){ var o = { v: 7, f: function(){ return (() => this.v)() } }; return o.f() })()", 7);
S("IIFE arrow", "(() => 42)()", 42);
S("comma operator", "(1, 2, 3)", 3);
S("void", "void 0", undefined);
S("in operator", "'a' in { a: 1 }", true);
S("delete", "(function(){ var o = { a: 1 }; delete o.a; return 'a' in o })()", false);
S("typeof undeclared", "typeof naoExisteEmLugarNenhum", "undefined");
S("try/finally sobrescreve return", "(function(){ return (function(){ try { return 1 } finally { return 2 } })() })()", 2);
S("switch fallthrough", "(function(){ var s = ''; switch (2) { case 1: s += 'a'; case 2: s += 'b'; case 3: s += 'c'; break; default: s += 'd' } return s })()", "bc");
S("do-while", "(function(){ var i = 0; do { i++ } while (i < 3); return i })()", 3);
S("with", "(function(){ var o = { a: 5 }; with (o) { return a } })()", 5);
S("getter herdado por classe", "(function(){ class A { get x(){ return 1 } }; class B extends A {}; return new B().x })()", 1);
S("regex literal com flags", "/a/gi.flags", "gi");
S("dynamic import (sintaxe)", "typeof import", "undefined");
S("import.meta fora de modulo", "(function(){ try { eval('import.meta'); return 'ok' } catch (e) { return 'throw' } })()", "throw");
S("using declaration (ES2026)", "(function(){ try { eval('{ using x = { [Symbol.dispose](){} }; }'); return 'ok' } catch (e) { return 'throw' } })()", "ok");
S("decorators", "(function(){ try { eval('class A { @dec m(){} }'); return 'ok' } catch (e) { return 'throw' } })()", "ok");

// ─────────────────────────── OBJECT / PROPRIEDADES ──────────────────────────
C("object");
T("Object.keys ordem de insercao", function () { var o = { b: 1, a: 2 }; return Object.keys(o).join(',') === 'b,a' || Object.keys(o).join(','); });
T("Object.keys ordem com getter", function () { var o = { b: 1, get a() { return 2 }, c: 3 }; return Object.keys(o).join(',') === 'b,a,c' || Object.keys(o).join(','); });
T("Object.assign", function () { return Object.assign({}, { a: 1 }).a === 1; });
T("Object.entries", function () { return Object.entries({ a: 1 })[0][1] === 1; });
T("Object.fromEntries", function () { return Object.fromEntries([['a', 1]]).a === 1; });
T("Object.hasOwn", function () { return Object.hasOwn({ a: 1 }, 'a') === true; });
T("Object.groupBy", function () { var g = Object.groupBy([1, 2, 3], function (x) { return x % 2 ? 'o' : 'e' }); return g.o.length === 2; });
T("Object.freeze impede escrita", function () { var o = Object.freeze({ a: 1 }); o.a = 2; return o.a === 1; });
T("Object.isFrozen", function () { return Object.isFrozen(Object.freeze({})) === true; });
T("Object.seal", function () { var o = Object.seal({ a: 1 }); o.b = 2; return o.b === undefined; });
T("Object.preventExtensions", function () { var o = {}; Object.preventExtensions(o); o.a = 1; return o.a === undefined; });
T("defineProperty getter", function () { var o = {}; Object.defineProperty(o, 'x', { get: function () { return 8 } }); return o.x === 8; });
T("defineProperty enumerable:false", function () { var o = {}; Object.defineProperty(o, 'x', { value: 1, enumerable: false }); return Object.keys(o).length === 0; });
T("defineProperty writable:false", function () { var o = {}; Object.defineProperty(o, 'x', { value: 1, writable: false }); o.x = 9; return o.x === 1; });
T("getOwnPropertyDescriptor", function () { var d = Object.getOwnPropertyDescriptor({ a: 1 }, 'a'); return d.value === 1 && d.writable === true && d.enumerable === true; });
T("getOwnPropertyDescriptors", function () { return Object.getOwnPropertyDescriptors({ a: 1 }).a.value === 1; });
T("getOwnPropertyNames nao-enum", function () { var o = {}; Object.defineProperty(o, 'h', { value: 1 }); return Object.getOwnPropertyNames(o).indexOf('h') >= 0; });
T("getPrototypeOf / setPrototypeOf", function () { var b = {}; var o = Object.create(b); return Object.getPrototypeOf(o) === b; });
T("Object.create(null)", function () { var o = Object.create(null); return Object.getPrototypeOf(o) === null; });
T("Object.create com descritores", function () { var o = Object.create(null, { a: { value: 3, enumerable: true } }); return o.a === 3; });
T("obj.__proto__ leitura", function () { return ({}).__proto__ === Object.prototype; });
T("getPrototypeOf(funcao)", function () { return Object.getPrototypeOf(function () { }) === Function.prototype; });
T("getPrototypeOf(C.prototype)", function () { class A { }; return Object.getPrototypeOf(A.prototype) === Object.prototype; });
T("Object.prototype.toString marca", function () { return Object.prototype.toString.call([]) === '[object Array]'; });
T("toStringTag custom", function () { var o = {}; o[Symbol.toStringTag] = 'Q'; return Object.prototype.toString.call(o) === '[object Q]'; });
T("propertyIsEnumerable", function () { return ({ a: 1 }).propertyIsEnumerable('a') === true; });
T("spread de objeto copia getters", function () { var o = { get a() { return 1 } }; return ({ ...o }).a === 1; });

// ─────────────────────────── ARRAY ───────────────────────────
C("array");
T("at()", function () { return [1, 2, 3].at(-1) === 3; });
T("flat()", function () { return [1, [2, [3]]].flat(2).join(',') === '1,2,3'; });
T("flatMap()", function () { return [1, 2].flatMap(function (x) { return [x, x] }).length === 4; });
T("findLast / findLastIndex", function () { return [1, 2, 3].findLast(function (x) { return x < 3 }) === 2 && [1, 2, 3].findLastIndex(function (x) { return x < 3 }) === 1; });
T("includes(NaN)", function () { return [NaN].includes(NaN) === true; });
T("Array.from(iteravel)", function () { return Array.from(new Set([1, 2])).length === 2; });
T("Array.from(arraylike, fn)", function () { return Array.from({ length: 2, 0: 'a', 1: 'b' }, function (x) { return x + '!' }).join(',') === 'a!,b!'; });
T("Array.of", function () { return Array.of(7).length === 1; });
T("Array.isArray", function () { return Array.isArray([]) === true; });
T("copyWithin", function () { return [1, 2, 3, 4].copyWithin(0, 2).join(',') === '3,4,3,4'; });
T("fill", function () { return new Array(3).fill(0).join(',') === '0,0,0'; });
T("sort estavel + comparator", function () { return [3, 1, 2].sort(function (a, b) { return a - b }).join(',') === '1,2,3'; });
T("sort default (lexicografico)", function () { return [10, 9, 1].sort().join(',') === '1,10,9'; });
T("toSorted / toReversed", function () { var a = [2, 1]; return a.toSorted().join(',') === '1,2' && a.join(',') === '2,1' && a.toReversed().join(',') === '1,2'; });
T("with()", function () { return [1, 2].with(0, 9).join(',') === '9,2'; });
T("toSpliced()", function () { return [1, 2, 3].toSpliced(1, 1).join(',') === '1,3'; });
T("reduceRight", function () { return [1, 2, 3].reduceRight(function (a, b) { return a + b }) === 6; });
T("splice retorna removidos", function () { var a = [1, 2, 3]; return a.splice(1, 1).join(',') === '2' && a.join(',') === '1,3'; });
T("indexOf/lastIndexOf", function () { return [1, 2, 1].lastIndexOf(1) === 2; });
T("join com null/undefined", function () { return [1, null, undefined, 2].join(',') === '1,,,2'; });
T("length truncante", function () { var a = [1, 2, 3]; a.length = 1; return a.join(',') === '1'; });
T("holes: forEach pula", function () { var a = [1, , 3]; var n = 0; a.forEach(function () { n++ }); return n === 2; });
T("Array.prototype.entries/keys/values", function () { return [...['a'].entries()][0][1] === 'a'; });
T("Array.fromAsync", function () { return typeof Array.fromAsync === 'function'; });
T("concat com spreadable", function () { return [1].concat([2], 3).join(',') === '1,2,3'; });
T("array esparso -> JSON", function () { return JSON.stringify([1, , 3]) === '[1,null,3]'; });

// ─────────────────────────── STRING ───────────────────────────
C("string");
T("padStart/padEnd", function () { return 'a'.padStart(3, '-') === '--a'; });
T("trimStart/trimEnd", function () { return '  a '.trimStart() === 'a '; });
T("replaceAll", function () { return 'aaa'.replaceAll('a', 'b') === 'bbb'; });
T("replace com funcao", function () { return 'ab'.replace(/b/, function (m) { return m.toUpperCase() }) === 'aB'; });
T("replace com $1", function () { return 'ab'.replace(/(a)(b)/, '$2$1') === 'ba'; });
T("matchAll", function () { return [...'aa'.matchAll(/a/g)].length === 2; });
T("at()", function () { return 'abc'.at(-1) === 'c'; });
T("codePointAt / fromCodePoint", function () { return String.fromCodePoint(0x1F600).codePointAt(0) === 0x1F600; });
T("normalize", function () { return typeof ''.normalize === 'function' && 'a'.normalize() === 'a'; });
T("localeCompare", function () { return 'a'.localeCompare('b') < 0; });
T("raw", function () { return String.raw`a\nb`.length === 4; });
T("isWellFormed / toWellFormed", function () { return typeof ''.isWellFormed === 'function'; });
T("split com limite", function () { return 'a,b,c'.split(',', 2).length === 2; });
T("split com grupos de captura", function () { return 'a1b'.split(/(\d)/).join('|') === 'a|1|b'; });
T("repeat", function () { return 'ab'.repeat(2) === 'abab'; });
T("startsWith/endsWith com pos", function () { return 'abc'.startsWith('b', 1) === true; });
T("indices UTF-16 (surrogate)", function () { return '😀'.length === 2; });
T("iterador por code point", function () { return [...'😀'].length === 1; });
T("template + toString de objeto", function () { return `${{ toString: function () { return 'q' } }}` === 'q'; });

// ─────────────────────────── NUMBER / MATH ───────────────────────────
C("number");
T("toFixed", function () { return (1.005).toFixed(2) === '1.00' || (1.005).toFixed(2) === '1.01'; });
T("toFixed arredondamento spec", function () { return (1.45).toFixed(1) === '1.4' ? true : 'got=' + (1.45).toFixed(1) + ' (v8 da 1.4)'; });
T("toPrecision", function () { return (123.456).toPrecision(4) === '123.5'; });
T("toString(radix)", function () { return (255).toString(16) === 'ff'; });
T("parseInt com radix", function () { return parseInt('ff', 16) === 255; });
T("Number.isInteger/isSafeInteger", function () { return Number.isInteger(1) && !Number.isSafeInteger(2 ** 53); });
T("Number.EPSILON/MAX_SAFE_INTEGER", function () { return Number.MAX_SAFE_INTEGER === 9007199254740991; });
T("float -> string (shortest)", function () { return String(0.1 + 0.2) === '0.30000000000000004'; });
T("exponencial automatico", function () { return String(1e21) === '1e+21'; });
T("numero muito pequeno", function () { return String(1e-7) === '1e-7'; });
T("Math.round(-0.5)", function () { return Object.is(Math.round(-0.5), -0) === true; });
T("Math.hypot/cbrt/clz32/fround", function () { return Math.hypot(3, 4) === 5 && Math.clz32(1) === 31; });
T("Math.trunc/sign", function () { return Math.trunc(-1.7) === -1 && Math.sign(-3) === -1; });
T("BigInt aritmetica", function () { return (2n ** 64n).toString() === '18446744073709551616'; });
T("BigInt mistura lanca TypeError", function () { try { var x = 1n + 1; return 'sem throw'; } catch (e) { return e instanceof TypeError; } });

// ─────────────────────────── COERCAO / SEMANTICA ───────────────────────────
C("coercao");
T("+obj usa valueOf", function () { return +{ valueOf: function () { return 42 } } === 42; });
T("obj + 1 usa valueOf", function () { return ({ valueOf: function () { return 42 } }) + 1 === 43; });
T("data - data", function () { return new Date(3000) - new Date(1000) === 2000; });
T("[] + []", function () { return [] + [] === ''; });
T("1 + {}", function () { return 1 + {} === '1[object Object]'; });
T("'x' + [1,2]", function () { return 'x' + [1, 2] === 'x1,2'; });
T("[1] == '1'", function () { return ([1] == '1') === true; });
T("Symbol.toPrimitive", function () { var o = {}; o[Symbol.toPrimitive] = function (h) { return h === 'number' ? 5 : 's' }; return +o === 5 && `${o}` === 's'; });
T("null == undefined", function () { return (null == undefined) === true && (null === undefined) === false; });
T("NaN !== NaN", function () { return NaN !== NaN; });
T("Object.is(+0,-0)", function () { return Object.is(0, -0) === false; });
T("string relacional", function () { return ('a' < 'b') === true; });
T("ToNumber('  12  ')", function () { return Number('  12  ') === 12; });
T("ToNumber('0x10')", function () { return Number('0x10') === 16; });
T("ToNumber('')", function () { return Number('') === 0; });
T("ReferenceError em livre", function () { try { naoDefinido2; return 'sem throw'; } catch (e) { return e instanceof ReferenceError; } });
T("TDZ de let", function () { try { eval('(function(){ x; let x = 1 })()'); return 'sem throw'; } catch (e) { return e instanceof ReferenceError; } });
T("const imutavel", function () { try { eval('const c = 1; c = 2'); return 'sem throw'; } catch (e) { return e instanceof TypeError; } });
T("hoisting de var", function () { return eval('(function(){ var r = typeof v; var v = 1; return r })()') === 'undefined'; });
T("hoisting de funcao", function () { return eval('(function(){ return f(); function f(){ return 1 } })()') === 1; });
T("closure em loop com let", function () { var fs = []; for (let i = 0; i < 3; i++) fs.push(function () { return i }); return fs[0]() === 0 && fs[2]() === 2; });

// ─────────────────────────── FUNCOES ───────────────────────────
C("funcao");
T("fn.length", function () { return (function (a, b) { }).length === 2; });
T("fn.name", function () { return (function foo() { }).name === 'foo'; });
T("fn.name inferido de var", function () { var bar = function () { }; return bar.name === 'bar'; });
T("bind + parcial", function () { function f(a, b) { return a + b } return f.bind(null, 1)(2) === 3; });
T("bind preserva instanceof", function () { function F() { } var B = F.bind(null); return new B() instanceof F; });
T("call/apply", function () { return (function () { return this.v }).call({ v: 1 }) === 1; });
T("arguments", function () { return (function () { return arguments.length })(1, 2) === 2; });
T("arguments e array-like p/ Array.from", function () { return (function () { return Array.from(arguments).join(',') })(1, 2) === '1,2'; });
T("Function.prototype.toString", function () { return typeof (function f() { }).toString() === 'string'; });
T("funcoes nativas: .name", function () { return Array.prototype.map.name === 'map'; });
T("funcoes nativas: .length", function () { return Array.prototype.map.length === 1 ? true : 'got=' + Array.prototype.map.length; });
T("new sobre nativa nao-construtora", function () { try { new Math.max(); return 'sem throw'; } catch (e) { return e instanceof TypeError; } });
T("recursao profunda nao crasha", function () { try { (function r(n) { return n ? r(n - 1) : 0 })(2000); return true; } catch (e) { return 'lancou em 2000: ' + e.name; } });

// ─────────────────────────── PROMISE / ASYNC ───────────────────────────
C("async");
T("Promise.resolve/then existe", function () { return typeof Promise.resolve().then === 'function'; });
T("Promise.all/race", function () { return typeof Promise.all === 'function' && typeof Promise.race === 'function'; });
T("Promise.allSettled", function () { return typeof Promise.allSettled === 'function'; });
T("Promise.any + AggregateError", function () { return typeof Promise.any === 'function' && typeof AggregateError === 'function'; });
T("Promise.withResolvers", function () { return typeof Promise.withResolvers === 'function'; });
T("queueMicrotask", function () { return typeof queueMicrotask === 'function'; });
T("async fn devolve promise", function () { return (async function () { })() instanceof Promise; });
T("await resolve (ordem)", function () { var log = []; (async function () { log.push(1); await null; log.push(3) })(); log.push(2); return log.join(',') === '1,2'; });
T("thenable customizado", function () { return typeof Promise.resolve({ then: function (r) { r(1) } }).then === 'function'; });
T("unhandledrejection detectavel", function () { return typeof addEventListener === 'function' || 'sem addEventListener global'; });
T("setTimeout existe", function () { return typeof setTimeout === 'function'; });
T("Symbol.asyncIterator", function () { return typeof Symbol.asyncIterator === 'symbol'; });

// ─────────────────────────── SYMBOL / PROXY / REFLECT ───────────────────────────
C("meta");
T("Symbol identidade", function () { var s = Symbol('a'); var o = {}; o[s] = 1; return o[s] === 1 && Object.keys(o).length === 0; });
T("Symbol.for registro global", function () { return Symbol.for('k') === Symbol.for('k'); });
T("Symbol.iterator custom", function () { var o = {}; o[Symbol.iterator] = function () { var i = 0; return { next: function () { return i < 2 ? { value: i++, done: false } : { done: true } } } }; return [...o].length === 2; });
T("Symbol.hasInstance", function () { var C2 = {}; C2[Symbol.hasInstance] = function () { return true }; return ({}) instanceof C2; });
T("Symbol.species", function () { return typeof Symbol.species === 'symbol'; });
T("getOwnPropertySymbols", function () { var s = Symbol(); var o = {}; o[s] = 1; return Object.getOwnPropertySymbols(o).length === 1; });
T("Proxy get/set", function () { var p = new Proxy({}, { get: function () { return 7 }, set: function () { return true } }); return p.qualquer === 7; });
T("Proxy has/deleteProperty", function () { var p = new Proxy({}, { has: function () { return true }, deleteProperty: function () { return true } }); return ('x' in p) === true; });
T("Proxy ownKeys + getOwnPropertyDescriptor", function () { var p = new Proxy({}, { ownKeys: function () { return ['a'] }, getOwnPropertyDescriptor: function () { return { value: 1, enumerable: true, configurable: true } } }); return Object.keys(p).join(',') === 'a'; });
T("Proxy apply", function () { var p = new Proxy(function () { }, { apply: function () { return 9 } }); return p() === 9; });
T("Proxy construct", function () { var p = new Proxy(function () { }, { construct: function () { return { v: 3 } } }); return new p().v === 3; });
T("Proxy defineProperty/getPrototypeOf", function () { var hit = 0; var p = new Proxy({}, { getPrototypeOf: function () { hit++; return null } }); Object.getPrototypeOf(p); return hit === 1; });
T("Proxy revocable", function () { return typeof Proxy.revocable === 'function'; });
T("Reflect.get com receiver", function () { var o = { get a() { return this.v } }; return Reflect.get(o, 'a', { v: 5 }) === 5; });
T("Reflect.ownKeys/has/set/deleteProperty", function () { return Reflect.ownKeys({ a: 1 }).join(',') === 'a' && Reflect.has({ a: 1 }, 'a'); });
T("Reflect.construct com newTarget", function () { function A() { }; function B() { }; var o = Reflect.construct(A, [], B); return Object.getPrototypeOf(o) === B.prototype; });
T("Reflect.apply/defineProperty/getPrototypeOf", function () { return Reflect.apply(Math.max, null, [1, 2]) === 2; });
T("WeakRef", function () { return typeof WeakRef === 'function'; });
T("FinalizationRegistry", function () { return typeof FinalizationRegistry === 'function'; });
T("globalThis", function () { return typeof globalThis === 'object'; });

// ─────────────────────────── COLECOES ───────────────────────────
C("colecoes");
T("Map basico + ordem", function () { var m = new Map([['b', 1], ['a', 2]]); return [...m.keys()].join(',') === 'b,a'; });
T("Map com chave objeto", function () { var k = {}; var m = new Map(); m.set(k, 1); return m.get(k) === 1; });
T("Map.groupBy", function () { return typeof Map.groupBy === 'function'; });
T("Set operacoes (union/intersection)", function () { return typeof new Set().union === 'function'; });
T("WeakMap/WeakSet", function () { var k = {}; var w = new WeakMap(); w.set(k, 1); return w.get(k) === 1; });
T("subclasse de Map", function () { class M extends Map { }; var m = new M(); m.set('a', 1); return m.get('a') === 1; });
T("subclasse de Array", function () { class A extends Array { }; var a = new A(); a.push(1); return a.length === 1; });
T("subclasse de Error com cause", function () { class E extends Error { }; var e = new E('m', { cause: 'c' }); return e.message === 'm' && e.cause === 'c'; });
T("Error.cause", function () { return new Error('m', { cause: 1 }).cause === 1; });
T("Error.stack", function () { return typeof new Error('m').stack === 'string'; });
T("captureStackTrace", function () { return typeof Error.captureStackTrace === 'function'; });
T("structuredClone", function () { var o = structuredClone({ a: [1, { b: 2 }] }); return o.a[1].b === 2; });
T("structuredClone de Map/Date", function () { var o = structuredClone({ d: new Date(0), m: new Map([['a', 1]]) }); return o.m.get('a') === 1 && o.d instanceof Date; });

// ─────────────────────────── REGEX ───────────────────────────
C("regex");
T("grupos nomeados", function () { return /(?<y>\d+)/.exec('12').groups.y === '12'; });
T("lookbehind", function () { return /(?<=a)b/.test('ab') === true; });
T("flag u + \\u{...}", function () { return /\u{1F600}/u.test('😀') === true; });
T("flag s (dotAll)", function () { return /a.b/s.test('a\nb') === true; });
T("flag y (sticky)", function () { var r = /a/y; r.lastIndex = 1; return r.test('ba') === true; });
T("flag d (indices)", function () { var m = /a/d.exec('a'); return m.indices && m.indices[0][0] === 0; });
T("flag v (unicodeSets)", function () { try { return new RegExp('[\\q{abc}]', 'v').test('abc'); } catch (e) { return 'sem flag v: ' + e.name; } });
T("property escapes \\p{...}", function () { return /\p{L}/u.test('á') === true; });
T("backreference", function () { return /(a)\1/.test('aa') === true; });
T("named backreference \\k<n>", function () { return /(?<x>a)\k<x>/.test('aa') === true; });
T("quantificador nao-guloso", function () { return 'aaa'.match(/a+?/)[0] === 'a'; });
T("replace com $<nome>", function () { return 'a'.replace(/(?<g>a)/, '[$<g>]') === '[a]'; });
T("Symbol.replace custom", function () { var o = {}; o[Symbol.replace] = function () { return 'X' }; return 'abc'.replace(o) === 'X'; });
T("RegExp.prototype.source/flags", function () { return new RegExp('a', 'g').source === 'a'; });
T("lastIndex com /g em exec loop", function () { var r = /a/g, n = 0; while (r.exec('aaa')) n++; return n === 3; });

// ─────────────────────────── TYPEDARRAY / BINARIO ───────────────────────────
C("binario");
T("ArrayBuffer + Uint8Array", function () { var b = new ArrayBuffer(4); var u = new Uint8Array(b); u[0] = 255; return u[0] === 255; });
T("DataView", function () { var d = new DataView(new ArrayBuffer(4)); d.setUint16(0, 513); return d.getUint16(0) === 513; });
T("TypedArray.from/of", function () { return Uint8Array.from([1, 2]).length === 2; });
T("subarray/slice", function () { return new Uint8Array([1, 2, 3]).subarray(1).length === 2; });
T("Float64Array", function () { var f = new Float64Array(1); f[0] = 0.5; return f[0] === 0.5; });
T("BigInt64Array", function () { return typeof BigInt64Array === 'function'; });
T("Atomics/SharedArrayBuffer", function () { return typeof SharedArrayBuffer === 'function'; });
T("ArrayBuffer.transfer/resize", function () { return typeof new ArrayBuffer(1).transfer === 'function'; });
T("TextEncoder/TextDecoder", function () { return typeof TextEncoder === 'function' && new TextEncoder().encode('a')[0] === 97; });
T("btoa/atob", function () { return typeof btoa === 'function' && btoa('a') === 'YQ=='; });
T("WebAssembly", function () { return typeof WebAssembly === 'object'; });

// ─────────────────────────── DATE / INTL / JSON ───────────────────────────
C("date/intl/json");
T("Date.parse ISO", function () { return Date.parse('1970-01-01T00:00:02Z') === 2000; });
T("Date.parse RFC/locale", function () { return !isNaN(Date.parse('Jan 1, 1970')); });
T("toISOString", function () { return new Date(0).toISOString() === '1970-01-01T00:00:00.000Z'; });
T("JSON.stringify usa toJSON", function () { return JSON.stringify(new Date(0)) === '"1970-01-01T00:00:00.000Z"'; });
T("JSON.stringify replacer + espaco", function () { return JSON.stringify({ a: 1 }, null, 2).indexOf('\n') > 0; });
T("JSON.stringify replacer array", function () { return JSON.stringify({ a: 1, b: 2 }, ['a']) === '{"a":1}'; });
T("JSON.parse reviver", function () { return JSON.parse('{"a":1}', function (k, v) { return typeof v === 'number' ? v * 2 : v }).a === 2; });
T("JSON escapa unicode/controle", function () { return JSON.stringify('') === '"\\u0001"'; });
T("getTimezoneOffset / horario local", function () { return typeof new Date().getTimezoneOffset() === 'number'; });
T("toLocaleDateString", function () { return typeof new Date(0).toLocaleDateString() === 'string'; });
T("Intl.NumberFormat", function () { return new Intl.NumberFormat('en-US').format(1234.5) === '1,234.5'; });
T("Intl.NumberFormat currency", function () { return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(2) === '$2.00'; });
T("Intl.DateTimeFormat", function () { return typeof new Intl.DateTimeFormat('en-US').format(new Date(0)) === 'string'; });
T("Intl.RelativeTimeFormat", function () { return typeof Intl.RelativeTimeFormat === 'function'; });
T("Intl.Collator", function () { return typeof Intl.Collator === 'function'; });
T("Intl.PluralRules", function () { return typeof Intl.PluralRules === 'function'; });
T("Intl.ListFormat / Segmenter", function () { return typeof Intl.ListFormat === 'function' && typeof Intl.Segmenter === 'function'; });
T("Temporal", function () { return typeof Temporal === 'object'; });

// ─────────────────────────── SAIDA ───────────────────────────
console.log("=== PROBE_LANG_BEGIN ===");
for (var i = 0; i < out.length; i++) console.log(out[i]);
var ok = 0, bad = 0, fail = 0;
for (var i = 0; i < out.length; i++) {
  if (out[i].indexOf('OK\t') === 0) ok++;
  else if (out[i].indexOf('BAD\t') === 0) bad++;
  else fail++;
}
console.log("=== PROBE_LANG_END total=" + out.length + " ok=" + ok + " bad=" + bad + " fail=" + fail + " ===");
