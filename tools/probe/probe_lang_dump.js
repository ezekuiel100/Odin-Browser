// Verificação dos AMBÍGUOS da 1ª sonda: distinguir bug do motor de erro da minha expectativa.
function P(k, fn) { var r; try { r = fn(); } catch (e) { r = "THREW " + (e && e.name) + " " + (e && e.message); } console.log("V\t" + k + "\t" + r); }

P("typeof async()", function () { return typeof (async function () { })(); });
P("async() tem .then?", function () { return typeof (async function () { })().then; });
P("async() instanceof Promise", function () { return (async function () { })() instanceof Promise; });
P("Promise.resolve() instanceof Promise", function () { return Promise.resolve() instanceof Promise; });
P("typeof Promise.resolve()", function () { return typeof Promise.resolve(); });
P("Promise.resolve().constructor===Promise", function () { return Promise.resolve().constructor === Promise; });
P("await ordem (log sincrono)", function () { var g = []; (async function () { g.push(1); await null; g.push(3) })(); g.push(2); return g.join(','); });
P("await realmente entrega valor", function () { var v = 'nao rodou'; (async function () { v = await Promise.resolve('sim') })(); return v; });

P("typeof globalThis", function () { return typeof globalThis; });
P("globalThis === this?", function () { return typeof this; });
P("window existe?", function () { return typeof window; });
P("self existe?", function () { return typeof self; });

P("[1,,3] length", function () { var a = [1, , 3]; return a.length; });
P("[1,,3] forEach visitas", function () { var a = [1, , 3], n = 0; a.forEach(function () { n++ }); return n; });
P("1 in [1,,3]", function () { return 1 in [1, , 3]; });
P("a.length=1 trunca", function () { var a = [1, 2, 3]; a.length = 1; return a.join(',') + " len=" + a.length; });
P("a.length=5 estende", function () { var a = [1]; a.length = 5; return a.length; });
P("delete a[0] deixa buraco", function () { var a = [1, 2]; delete a[0]; return a.length + " " + (0 in a); });

P("'abc'.startsWith('b',1)", function () { return 'abc'.startsWith('b', 1); });
P("'abc'.endsWith('a',1)", function () { return 'abc'.endsWith('a', 1); });
P("'abc'.indexOf('b',2)", function () { return 'abc'.indexOf('b', 2); });

P("JSON.stringify ctrl char", function () { return JSON.stringify(String.fromCharCode(1)); });
P("JSON.stringify aspas/barra", function () { return JSON.stringify('a"b\\c'); });
P("JSON.stringify emoji", function () { return JSON.stringify('\u{1F600}').length; });
P("JSON.stringify(undefined) em obj", function () { return JSON.stringify({ a: undefined, b: 1 }); });
P("JSON.stringify(function) em obj", function () { return JSON.stringify({ a: function () { }, b: 1 }); });
P("JSON.stringify replacer-array", function () { return JSON.stringify({ a: 1, b: 2 }, ['a']); });
P("JSON.stringify indent string", function () { return JSON.stringify({ a: 1 }, null, '\t'); });

P("Date.parse('Jan 1, 1970')", function () { return Date.parse('Jan 1, 1970'); });
P("Date.parse('1970-01-01')", function () { return Date.parse('1970-01-01'); });
P("Date.parse('2024-03-05T10:00:00')", function () { return Date.parse('2024-03-05T10:00:00'); });
P("new Date('March 5, 2024')", function () { return String(new Date('March 5, 2024')); });
P("new Date(2024,2,5) getMonth", function () { return new Date(2024, 2, 5).getMonth(); });
P("toLocaleDateString saida", function () { return new Date(0).toLocaleDateString(); });
P("toLocaleString saida", function () { return new Date(0).toLocaleString(); });
P("date.toString saida", function () { return new Date(0).toString(); });

P("Proxy sobre funcao: typeof", function () { return typeof new Proxy(function () { }, {}); });
P("Proxy sobre funcao: chamada", function () { return new Proxy(function () { return 1 }, {})(); });
P("Proxy ownKeys trap", function () { var p = new Proxy({}, { ownKeys: function () { return ['a'] }, getOwnPropertyDescriptor: function () { return { value: 1, enumerable: true, configurable: true } } }); return Object.keys(p).join('|'); });
P("Proxy deleteProperty trap", function () { var hit = 0; var p = new Proxy({ a: 1 }, { deleteProperty: function (t, k) { hit++; delete t[k]; return true } }); delete p.a; return hit; });
P("Proxy defineProperty trap", function () { var hit = 0; var p = new Proxy({}, { defineProperty: function () { hit++; return true } }); Object.defineProperty(p, 'x', { value: 1 }); return hit; });
P("Reflect.get receiver", function () { var o = { get a() { return this.v } }; return Reflect.get(o, 'a', { v: 5 }); });

P("Array.prototype.lastIndexOf", function () { return typeof [].lastIndexOf; });
P("Array.prototype.toSorted", function () { return typeof [].toSorted; });
P("Array.prototype.at", function () { return typeof [].at; });
P("Array.prototype.findLast", function () { return typeof [].findLast; });
P("Array.prototype.group", function () { return typeof [].group; });

P("Object.create(null,{...})", function () { var o = Object.create(null, { a: { value: 3, enumerable: true } }); return o.a; });
P("Object.create(proto) so", function () { var b = { z: 1 }; return Object.create(b).z; });
P("__proto__ leitura", function () { return ({}).__proto__ === Object.prototype; });
P("__proto__ escrita", function () { var o = {}; o.__proto__ = { q: 1 }; return o.q; });
P("{__proto__: b} literal", function () { var b = { q: 2 }; return ({ __proto__: b }).q; });

P("chave numerica vs string ordem", function () { var o = { b: 1, 2: 2, a: 3, 1: 4 }; return Object.keys(o).join(','); });
P("for-in herda do proto", function () { var b = { z: 1 }; var o = Object.create(b); o.a = 1; var ks = []; for (var k in o) ks.push(k); return ks.join(','); });

P("Symbol.species", function () { return typeof Symbol.species; });
P("Symbol.replace", function () { return typeof Symbol.replace; });
P("Symbol.match/search/split", function () { return typeof Symbol.match + '/' + typeof Symbol.search + '/' + typeof Symbol.split; });
P("Symbol.toPrimitive", function () { return typeof Symbol.toPrimitive; });
P("Symbol.dispose", function () { return typeof Symbol.dispose; });

P("erro: mensagem de undefined.prop", function () { try { var u; u.x } catch (e) { return e.name + ': ' + e.message } });
P("erro: chamada de nao-funcao", function () { try { var o = {}; o.f() } catch (e) { return e.name + ': ' + e.message } });
P("erro: stack tem linhas?", function () { try { null.x } catch (e) { return String(e.stack).split('\n').length } });
P("erro: instanceof cadeia", function () { return new TypeError('x') instanceof Error; });

P("getter em classe estatica", function () { class A { static get v() { return 1 } } return A.v; });
P("class expression nomeada", function () { var C = class Q { m() { return typeof Q } }; return new C().m(); });
P("super em objeto literal", function () { var b = { m() { return 1 } }; var o = { __proto__: b, m() { return super.m() + 1 } }; return o.m(); });
P("Symbol.iterator em Map spread", function () { return [...new Map([['a', 1]])].length; });
P("String.prototype.replace $&", function () { return 'a'.replace(/a/, '[$&]'); });
P("String.prototype.replace $<n>", function () { return 'a'.replace(/(?<g>a)/, '[$<g>]'); });
P("regex /d indices", function () { var m = /a/d.exec('a'); return typeof m.indices; });
P("regex flags getter", function () { return /a/gimsuy.flags; });
console.log("=== V_END ===");
