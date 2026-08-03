class C { #x = 1; static has(o){ return #x in o; } }
console.log(C.has(new C()) && !C.has({}) ? 'SYNTAX_OK' : 'VAL_FAIL');
