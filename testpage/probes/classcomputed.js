var k = 'x';
class C { [k] = 5; }
console.log(new C().x === 5 ? 'SYNTAX_OK' : 'VAL_FAIL');
