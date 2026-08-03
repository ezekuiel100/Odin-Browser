package js

// M136 — subclasse de builtin: `class X extends Map/Set/Array/Error`.
//
// Era um beco arquitetural: a instância de uma classe é um ^Object, e Map/Set/Array
// são variantes PRÓPRIAS da união Value — nunca um ^Object. Logo `x.set(...)` batia
// em "Map.prototype.set called on incompatible receiver", `extends Array` perdia
// push/length, e `extends Error` perdia a MENSAGEM (o pior dos três: toda biblioteca
// que define erro próprio faz isso, e o diagnóstico virava um erro vazio).
//
// Saída = slots internos, como na spec e como já fazíamos p/ TypedArray (`ab`) e
// generator (`gen`): a instância segue ^Object de verdade (props, protótipo, campos
// de classe) e o valor exótico que o `super()` criou vai no slot `prim`.
//
// Medido no corpo do gap-report de 2026-07-21: alimenta `Reflect.construct target is
// not a constructor` (3 sites) e `Cannot set properties of undefined (setting
// 'constructor')` (2 sites).

import "core:testing"
import "core:strings"

// ── Map / Set ────────────────────────────────────────────────────────────────

@(test)
m136_extends_map_funciona :: proc(t: ^testing.T) {
    src := `
        class X extends Map {}
        var x = new X();
        x.set("a", 1).set("b", 2);
        x.get("a") + "|" + x.size + "|" + x.has("b")
    `
    testing.expect_value(t, run(src).(string), "1|2|true")
}

@(test)
m136_extends_map_com_iteravel_no_super :: proc(t: ^testing.T) {
    // `new X([[k,v]])` tem que chegar ao construtor nativo pelo super implícito.
    src := `class X extends Map {}; new X([["a", 7]]).get("a")`
    testing.expect_value(t, run(src).(f64), 7)
}

@(test)
m136_subclasse_mistura_estado_proprio_e_do_builtin :: proc(t: ^testing.T) {
    // O ponto do slot interno: campo de classe e método próprio convivem com o Map.
    src := `
        class X extends Map {
            tag = "oi";
            dobro(k) { return this.get(k) * 2 }
        }
        var x = new X();
        x.set("a", 3);
        x.tag + "|" + x.dobro("a") + "|" + x.size
    `
    testing.expect_value(t, run(src).(string), "oi|6|1")
}

@(test)
m136_hasOwnProperty_olha_a_instancia_nao_o_slot :: proc(t: ^testing.T) {
    // O recorte do unwrap: só método DO builtin recebe o valor exótico como `this`.
    // hasOwnProperty é de Object.prototype e tem que ver a instância.
    src := `
        class X extends Map { tag = 1 }
        var x = new X();
        x.hasOwnProperty("tag") + "|" + x.hasOwnProperty("size")
    `
    testing.expect_value(t, run(src).(string), "true|false")
}

@(test)
m136_extends_map_e_instanceof_dos_dois_lados :: proc(t: ^testing.T) {
    src := `
        class X extends Map {}
        var x = new X();
        (x instanceof X) + "|" + (x instanceof Map)
    `
    testing.expect_value(t, run(src).(string), "true|true")
}

@(test)
m136_extends_set :: proc(t: ^testing.T) {
    src := `class X extends Set {}; var x = new X(); x.add(5); x.has(5) + "|" + x.size`
    testing.expect_value(t, run(src).(string), "true|1")
}

@(test)
m136_neto_de_map :: proc(t: ^testing.T) {
    // A adoção do slot atravessa dois níveis de herança.
    src := `class A extends Map {}; class B extends A {}; var b = new B(); b.set("k", 9); b.get("k")`
    testing.expect_value(t, run(src).(f64), 9)
}

@(test)
m136_super_metodo_dentro_de_override :: proc(t: ^testing.T) {
    src := `
        class X extends Map { get(k) { return "->" + super.get(k) } }
        var x = new X(); x.set("a", 1); x.get("a")
    `
    testing.expect_value(t, run(src).(string), "->1")
}

@(test)
m136_map_de_subclasse_itera :: proc(t: ^testing.T) {
    src := `
        class X extends Map {}
        var x = new X(); x.set("a", 1); x.set("b", 2);
        var s = ""; for (var e of x) s += e[0] + e[1];
        s
    `
    testing.expect_value(t, run(src).(string), "a1b2")
}

// ── Array ────────────────────────────────────────────────────────────────────

@(test)
m136_extends_array_push_e_length :: proc(t: ^testing.T) {
    src := `class X extends Array {}; var x = new X(); x.push(1, 2, 3); x.length`
    testing.expect_value(t, run(src).(f64), 3)
}

@(test)
m136_extends_array_indexa_nos_dois_sentidos :: proc(t: ^testing.T) {
    src := `
        class X extends Array {}
        var x = new X(); x.push("a"); x[1] = "b";
        x[0] + x[1] + "|" + x.length
    `
    testing.expect_value(t, run(src).(string), "ab|2")
}

@(test)
m136_extends_array_metodos_e_is_array :: proc(t: ^testing.T) {
    src := `
        class X extends Array {}
        var x = new X(); x.push(1, 2);
        x.map(function(n) { return n * 2 }).join(",") + "|" + Array.isArray(x)
    `
    testing.expect_value(t, run(src).(string), "2,4|true")
}

// ── Error ────────────────────────────────────────────────────────────────────

@(test)
m136_extends_error_preserva_a_mensagem :: proc(t: ^testing.T) {
    // O caso que mais aparecia em site real: o erro chegava sem message.
    src := `class X extends Error {}; new X("ops").message`
    testing.expect_value(t, run(src).(string), "ops")
}

@(test)
m136_erro_proprio_com_nome :: proc(t: ^testing.T) {
    // O idioma completo: super(m) no construtor e name próprio depois.
    src := `
        class InvariantError extends Error {
            constructor(m) { super(m); this.name = "InvariantError" }
        }
        var out = "";
        try { throw new InvariantError("quebrou") }
        catch (e) {
            out = e.name + ": " + e.message + "|" + (e instanceof InvariantError) + "|" + (e instanceof Error)
        }
        out
    `
    testing.expect_value(t, run(src).(string), "InvariantError: quebrou|true|true")
}

@(test)
m136_erro_de_subclasse_tem_stack_e_tostring :: proc(t: ^testing.T) {
    src := `
        class X extends Error { constructor(m) { super(m); this.name = "X" } }
        var e = new X("z");
        String(e) + "|" + (typeof e.stack)
    `
    testing.expect_value(t, run(src).(string), "X: z|string")
}

// ── Reflect.construct com newTarget ──────────────────────────────────────────

@(test)
m136_reflect_construct_honra_o_new_target :: proc(t: ^testing.T) {
    // O 3º argumento era IGNORADO. É o miolo do `_createSuper` que o Babel emite p/
    // classe derivada: sem ele a instância sai com o prototype errado.
    src := `
        class A { constructor() { this.v = 1 } }
        class B extends A {}
        var o = Reflect.construct(A, [], B);
        (o instanceof B) + "|" + (o instanceof A) + "|" + o.v
    `
    testing.expect_value(t, run(src).(string), "true|true|1")
}

@(test)
m136_reflect_construct_de_nativa_com_new_target :: proc(t: ^testing.T) {
    src := `
        class MeuErro extends Error {}
        var e = Reflect.construct(Error, ["x"], MeuErro);
        (e instanceof MeuErro) + "|" + e.message
    `
    testing.expect_value(t, run(src).(string), "true|x")
}

@(test)
m136_reflect_construct_sem_new_target_continua_igual :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: sem o 3º argumento nada muda.
    src := `class A { constructor() { this.v = 2 } }; Reflect.construct(A, []).v`
    testing.expect_value(t, run(src).(f64), 2)
}

// ── não-regressão dos builtins normais ───────────────────────────────────────

@(test)
m136_map_e_array_comuns_intactos :: proc(t: ^testing.T) {
    src := `
        var m = new Map(); m.set("a", 1);
        var a = [1, 2]; a.push(3);
        m.get("a") + "|" + m.size + "|" + a.length + "|" + a[2] + "|" + Array.isArray(a)
    `
    testing.expect_value(t, run(src).(string), "1|1|3|3|true")
}

@(test)
m136_receiver_errado_ainda_e_erro :: proc(t: ^testing.T) {
    // O guarda continua valendo: um objeto QUALQUER não vira Map por acidente.
    src := `
        var out = "sem erro";
        try { Map.prototype.set.call({}, "a", 1) }
        catch (e) { out = e instanceof TypeError ? "TypeError" : "outro" }
        out
    `
    testing.expect_value(t, run(src).(string), "TypeError")
}

// ── Proxy como construtor (trap `construct`) ─────────────────────────────────

@(test)
m136_new_de_proxy_sem_trap_constroi_o_alvo :: proc(t: ^testing.T) {
    // Um Proxy é um ^Object, não ^Function: `new p()` dava "is not a constructor".
    src := `
        class A { constructor(v) { this.v = v } }
        var P = new Proxy(A, {});
        var a = new P(7);
        a.v + "|" + (a instanceof A)
    `
    testing.expect_value(t, run(src).(string), "7|true")
}

@(test)
m136_trap_construct_intercepta :: proc(t: ^testing.T) {
    src := `
        class A { constructor(v) { this.v = v } }
        var P = new Proxy(A, {
            construct: function(alvo, args) { return new alvo(args[0] * 10) }
        });
        new P(4).v
    `
    testing.expect_value(t, run(src).(f64), 40)
}

@(test)
m136_reflect_construct_de_proxy :: proc(t: ^testing.T) {
    src := `
        class A { constructor(v) { this.v = v } }
        var P = new Proxy(A, {});
        Reflect.construct(P, [3]).v
    `
    testing.expect_value(t, run(src).(f64), 3)
}

@(test)
m136_alvo_invalido_diz_o_que_recebeu :: proc(t: ^testing.T) {
    // A mensagem instrumentada: `typeof` diria "object" p/ `{}` e p/ Proxy igual, e
    // era essa distinção que apontava a raiz.
    src := `
        var out = "";
        try { Reflect.construct({}, []) } catch (e) { out = e.message }
        out
    `
    got := run(src).(string)
    testing.expectf(t, strings.contains(got, "objeto comum"), "diz o que recebeu (msg=%s)", got)
}
