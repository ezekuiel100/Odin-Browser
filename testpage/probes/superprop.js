class A { m(){ return 'a'; } get g(){ return 1; } }
class B extends A { m(){ return super.g + super.m(); } }
console.log(new B().m() === '1a' ? 'SYNTAX_OK' : 'VAL_FAIL');
