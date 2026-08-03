package js

// M153 — namespace CSS: CSS.escape() e CSS.supports() (css_om.odin).
//
// Entrou pela porta do M150 (identificador livre lanca ReferenceError):
// `CSS is not defined` apareceu NOMEADO no gap-report (airbnb & cia. fazem
// `CSS.supports('display','grid')` e `CSS.escape(id)`).
//
// AVISO: ESTES testes rodam sob `run()` (pacote js puro, SEM o pacote ui), entao
// o hook g_css_supports e NIL e CSS.supports cai na HEURISTICA sintatica. Por
// isso os casos "false" de supports usam identificador IMPLAUSIVEL (digito/
// espaco), nao uma propriedade real-mas-nao-suportada — essa distincao so existe
// com o hook do ui instalado (render de verdade). O que estes testes guardam: o
// algoritmo do escape (exato, independe de tabela) e a ESTRUTURA do parser de
// <supports-condition> (and/or/not/parenteses/declaracao).

import "core:testing"

// -- CSS.escape (algoritmo "serialize an identifier", exato) ------------------

@(test)
m153_escape_preserva_ident_comum :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.escape('foo')`).(string), "foo")
    testing.expect_value(t, run(`CSS.escape('foo-bar_baz')`).(string), "foo-bar_baz")
    testing.expect_value(t, run(`CSS.escape('')`).(string), "")
}

@(test)
m153_escape_pontuacao_leva_barra :: proc(t: ^testing.T) {
    // '.', '#', ' ' nao estao no conjunto preservado -> '\' + char.
    testing.expect_value(t, run(`CSS.escape('.foo')`).(string), "\\.foo")
    testing.expect_value(t, run(`CSS.escape('#bar')`).(string), "\\#bar")
    testing.expect_value(t, run(`CSS.escape('a b')`).(string), "a\\ b")
}

@(test)
m153_escape_digito_inicial_vira_hex :: proc(t: ^testing.T) {
    // 1o char digito -> '\'<hex><espaco>. '0' = 0x30, '7' = 0x37.
    testing.expect_value(t, run(`CSS.escape('0')`).(string), "\\30 ")
    testing.expect_value(t, run(`CSS.escape('7up')`).(string), "\\37 up")
    // digito NAO-inicial e preservado
    testing.expect_value(t, run(`CSS.escape('a7')`).(string), "a7")
}

@(test)
m153_escape_hifen_casos_de_borda :: proc(t: ^testing.T) {
    // '-' sozinho -> "\-"
    testing.expect_value(t, run(`CSS.escape('-')`).(string), "\\-")
    // '-' seguido de digito -> o digito vira hex ('-' + \\31 = '1')
    testing.expect_value(t, run(`CSS.escape('-1')`).(string), "-\\31 ")
    // "--a": ambos '-' e 'a' preservados
    testing.expect_value(t, run(`CSS.escape('--a')`).(string), "--a")
}

@(test)
m153_escape_controle_e_null :: proc(t: ^testing.T) {
    // Caracteres invisiveis construidos por codigo (licao do NBSP no M151: char
    // de controle escrito cru no fonte e armadilha). U+0001 -> "\1 ".
    testing.expect_value(t, run(`CSS.escape(String.fromCharCode(1))`).(string), "\\1 ")
    // NULL -> U+FFFD (REPLACEMENT CHARACTER, code point 65533)
    testing.expect_value(t, run(`CSS.escape(String.fromCharCode(0)).charCodeAt(0)`).(f64), 65533)
}

@(test)
m153_escape_nao_ascii_preservado :: proc(t: ^testing.T) {
    // code point >= U+0080 e preservado literalmente (e' = U+00E9 = 233)
    testing.expect_value(t, run(`CSS.escape(String.fromCharCode(233)).charCodeAt(0)`).(f64), 233)
}

// -- CSS.supports (forma de dois argumentos) ----------------------------------

@(test)
m153_supports_par_prop_conhecida :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.supports('display', 'grid')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('position', 'sticky')`).(bool), true)
}

@(test)
m153_supports_par_valor_vazio_e_important :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.supports('display', '')`).(bool), false)
    // !important e invalido dentro de @supports
    testing.expect_value(t, run(`CSS.supports('color', 'red !important')`).(bool), false)
}

@(test)
m153_supports_par_prop_implausivel :: proc(t: ^testing.T) {
    // sob heuristica (hook nil), digito inicial / espaco = nao-plausivel -> false
    testing.expect_value(t, run(`CSS.supports('1px', 'x')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('foo bar', 'x')`).(bool), false)
}

// -- CSS.supports (forma de condicao textual) ---------------------------------

@(test)
m153_supports_cond_declaracao_simples :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.supports('(display: grid)')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('( display:grid )')`).(bool), true)
}

@(test)
m153_supports_cond_and_or_not :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.supports('(display: grid) and (gap: 1px)')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('not (display: grid)')`).(bool), false)
    // or com um operando implausivel: o lado bom ganha
    testing.expect_value(t, run(`CSS.supports('(display: grid) or (1px: x)')`).(bool), true)
    // and com um operando implausivel: derruba tudo
    testing.expect_value(t, run(`CSS.supports('(display: grid) and (1px: x)')`).(bool), false)
}

@(test)
m153_supports_cond_general_enclosed_e_selector :: proc(t: ^testing.T) {
    // selector(...) e function-enclosed: nao afirmamos suporte -> false
    testing.expect_value(t, run(`CSS.supports('selector(.foo)')`).(bool), false)
    // parentese sem ':' nao e declaracao
    testing.expect_value(t, run(`CSS.supports('(color)')`).(bool), false)
}

@(test)
m153_supports_cond_not_de_implausivel :: proc(t: ^testing.T) {
    // not de algo nao suportado -> true
    testing.expect_value(t, run(`CSS.supports('not (1px: x)')`).(bool), true)
}

// -- CSS.supports (declaracao NUA: passo 2 do CSSOM) --------------------------
// O texto que nao parseia como <supports-condition> ainda e tentado como
// <declaration>. Sem isso `CSS.supports('color: red')` — a grafia mais comum da
// forma de 1 argumento — devolvia false, e o feature-detect por texto dizia "nao
// suporto" para TUDO. (Aqui sob heuristica: o que se testa e a FORMA aceita.)

@(test)
m153_supports_declaracao_nua :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`CSS.supports('color: red')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('display:grid')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('  color : red  ')`).(bool), true)
    testing.expect_value(t, run(`CSS.supports('-webkit-transform: none')`).(bool), true)
    // `--x: 1px` (custom property) NAO cabe aqui: sob heuristica `--x` nao e um
    // identificador plausivel e a resposta sai false, enquanto com o hook real e
    // true (o motor parseia custom property). Quem cobre isso e o teste do lado ui
    // (`test_supports_js_declaracao_nua_usa_o_motor`), que tem o hook de verdade.
    // a forma entre parenteses continua valendo (controle: o passo 1 nao sumiu)
    testing.expect_value(t, run(`CSS.supports('(color: red)')`).(bool), true)
}

@(test)
m153_supports_declaracao_nua_forma_invalida :: proc(t: ^testing.T) {
    // sem ':' / sem valor / sem propriedade nao e declaracao
    testing.expect_value(t, run(`CSS.supports('color')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('color:')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports(': red')`).(bool), false)
    // ';' nao faz parte de <declaration>
    testing.expect_value(t, run(`CSS.supports('color: red;')`).(bool), false)
    // `not` sem parenteses e sintaxe INVALIDA, e o passo 2 tambem a recusa (a
    // "propriedade" seria `not color`, implausivel). Antes disto o resultado era
    // TRUE: o `not` invertia o "nao afirmo" do primary e o motor afirmava o que
    // nao sabe -- ver a guarda `is_supports_in_parens` em css_om.odin.
    testing.expect_value(t, run(`CSS.supports('not color: red')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('not display: grid')`).(bool), false)
    // parenteses desbalanceados = SOBRA de condicao, nao declaracao. Sem esta
    // guarda a "propriedade" seria `color` e o valor, o resto da condicao.
    testing.expect_value(t, run(`CSS.supports('color: red) or (foo: bar')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('(color: red')`).(bool), false)
}

@(test)
m153_supports_condicao_falsa_nao_vira_declaracao :: proc(t: ^testing.T) {
    // O passo 2 so pode agir sobre texto que NAO e condicao. Estes SAO condicoes
    // bem formadas que avaliaram FALSE — o fallback nao pode ressuscita-las
    // (o ':' delas esta dentro de parenteses, e e isso que o `index_top` ve).
    testing.expect_value(t, run(`CSS.supports('(display: grid) and (1px: x)')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('not (display: grid)')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('(1px: x)')`).(bool), false)
    testing.expect_value(t, run(`CSS.supports('selector(.foo)')`).(bool), false)
}

// -- ancoragem no objeto ------------------------------------------------------

@(test)
m153_css_e_objeto_com_metodos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof CSS`).(string), "object")
    testing.expect_value(t, run(`typeof CSS.escape`).(string), "function")
    testing.expect_value(t, run(`typeof CSS.supports`).(string), "function")
}
