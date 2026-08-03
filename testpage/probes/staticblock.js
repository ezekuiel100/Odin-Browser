class C { static x = 0; static { C.x = 7; } }
console.log(C.x === 7 ? 'SYNTAX_OK' : 'VAL_FAIL');
