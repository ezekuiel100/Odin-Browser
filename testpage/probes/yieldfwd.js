function* inner(){ var got = yield 'i'; yield got; }
function* outer(){ yield* inner(); }
var it = outer();
it.next();
var r = it.next('X');
console.log(r.value === 'X' ? 'SYNTAX_OK' : 'VAL_FAIL ' + r.value);
