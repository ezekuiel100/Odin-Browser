function* g(){ yield 1; yield 2; }
function f(a, b){ return a + b; }
console.log(f(...g()) === 3 ? 'SYNTAX_OK' : 'VAL_FAIL');
