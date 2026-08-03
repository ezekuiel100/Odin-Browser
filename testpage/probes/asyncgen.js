(async function(){
  async function* g(){ yield 1; yield 2; }
  var out = [];
  for await (var v of g()) out.push(v);
  console.log(out.join(',') === '1,2' ? 'SYNTAX_OK' : 'VAL_FAIL ' + out.join(','));
})();
