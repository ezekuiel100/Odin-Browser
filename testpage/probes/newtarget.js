function F(){ console.log(new.target !== undefined ? 'SYNTAX_OK' : 'VAL_FAIL'); }
new F();
