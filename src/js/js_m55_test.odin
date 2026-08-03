package js

// M55: TAGGED TEMPLATES. O lexer deixou de dessugarizar template p/ concat e
// emite estrutura (TplStart/Str/TplExprStart/TplExprEnd/TplEnd); o parser monta
// .Template (chunks em params, exprs em body) e .Tagged quando o template segue
// uma expressão; o interp concatena (normal) ou chama tag(chunks, ...valores).
// Rodar: odin test src/js

import "core:testing"

// ── templates normais continuam idênticos (regressão do redesenho) ───────────

@(test)
test_template_still_concats :: proc(t: ^testing.T) {
    testing.expect_value(t, run("var x=2; `a${x}b${x+1}c`").(string), "a2b3c")
}

@(test)
test_template_only_interp_is_string :: proc(t: ^testing.T) {
    // `${1}${2}` tem que continuar sendo a STRING "12", não o número 3
    testing.expect_value(t, run("`${1}${2}`").(string), "12")
}

@(test)
test_template_nested :: proc(t: ^testing.T) {
    testing.expect_value(t, run("var q=1; `a${`x${q}y`}b`").(string), "ax1yb")
}

@(test)
test_template_object_in_interp :: proc(t: ^testing.T) {
    // objeto com {} dentro do ${} (pilha interp_braces)
    testing.expect_value(t, run("`v=${ {k: 5}.k }`").(string), "v=5")
}

@(test)
test_template_division_after :: proc(t: ^testing.T) {
    // regressão do regex_allowed: `/` após template é DIVISÃO, não regex
    testing.expect_value(t, as_number(run("`4`/2")), f64(2))
}

// ── tagged templates ──────────────────────────────────────────────────────────

@(test)
test_tagged_basic :: proc(t: ^testing.T) {
    // a tag recebe (chunks, ...valores) — não a string pronta
    testing.expect_value(t, run(`
        function tag(strings, v){ return strings[0] + '|' + v + '|' + strings[1]; }
        var nome = 'Ana';
        tag` + "`Olá ${nome}!`" + `
    `).(string), "Olá |Ana|!")
}

@(test)
test_tagged_chunks_and_values :: proc(t: ^testing.T) {
    // contagem: chunks = valores + 1, incluindo vazios nas pontas
    testing.expect_value(t, run(`
        function tag(s, a, b){
            return s.length + ':' + (s[0]==='') + ':' + (s[2]==='') + ':' + a + ',' + b;
        }
        tag` + "`${1}x${2}`" + `
    `).(string), "3:true:true:1,2")
}

@(test)
test_tagged_no_interp :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function tag(s){ return s.length + ':' + s[0]; }
        tag` + "`puro`" + `
    `).(string), "1:puro")
}

@(test)
test_tagged_values_keep_type :: proc(t: ^testing.T) {
    // os valores interpolados chegam com o TIPO original (não viram string)
    testing.expect_value(t, run(`
        function tag(s, v){ return typeof v; }
        tag` + "`x${ {a:1} }y`" + `
    `).(string), "object")
}

@(test)
test_tagged_uppercase_values :: proc(t: ^testing.T) {
    // o exemplo clássico: processa só os valores, não o texto fixo
    testing.expect_value(t, run(`
        function grita(strings) {
            var out = strings[0];
            for (var i = 1; i < arguments.length; i++)
                out += String(arguments[i]).toUpperCase() + strings[i];
            return out;
        }
        var quem = 'mundo';
        grita` + "`Olá ${quem}!`" + `
    `).(string), "Olá MUNDO!")
}

@(test)
test_tagged_member_tag_this :: proc(t: ^testing.T) {
    // tag que é membro (styled.div`...`): this = o objeto
    testing.expect_value(t, run(`
        var styled = {
            prefixo: 'css:',
            div: function(strings){ return this.prefixo + strings[0]; }
        };
        styled.div` + "`color: red`" + `
    `).(string), "css:color: red")
}

@(test)
test_tagged_result_chains :: proc(t: ^testing.T) {
    // o resultado do tagged continua na cadeia postfix
    testing.expect_value(t, as_number(run(`
        function tag(s, v){ return s[0] + v; }
        tag` + "`abc${'de'}`" + `.length
    `)), f64(5))
}

@(test)
test_tagged_call_result_as_tag :: proc(t: ^testing.T) {
    // padrão styled('div')`...`: a TAG é o resultado de uma chamada
    testing.expect_value(t, run(`
        function styled(el){ return function(strings){ return el + '{' + strings[0] + '}'; }; }
        styled('div')` + "`margin:0`" + `
    `).(string), "div{margin:0}")
}

@(test)
test_tagged_expressions_evaluated_in_order :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [];
        function f(x){ log.push(x); return x; }
        function tag(s, a, b){ return log.join(',') + '|' + a + b; }
        tag` + "`${f(1)}-${f(2)}`" + `
    `).(string), "1,2|12")
}

@(test)
test_tagged_non_function_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var erro = '';
        try { (42)` + "`x`" + `; } catch(e){ erro = e.name; }
        erro
    `).(string), "TypeError")
}

@(test)
test_string_raw :: proc(t: ^testing.T) {
    // String.raw como tag (aproximação: cooked == raw)
    testing.expect_value(t, run("String.raw`a${1+1}b${'c'}`").(string), "a2bc")
}
