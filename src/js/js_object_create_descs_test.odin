package js

import "core:testing"

// `Object.create(proto, descritores)` — o 2º argumento era IGNORADO em silêncio.
//
// ⚠️ Por que isso passou despercebido tanto tempo: o defeito NÃO aparece onde
// está. O protótipo saía certo e as props simplesmente não existiam; o sintoma
// nascia a quatro saltos dali, dentro de código transpilado, como
// `TypeError: u.resolveOptions is not a function` no getbootstrap.com.
//
// A cadeia real (clipboard.js compilado para ES5 pelo Babel):
//   _inherits    → Object.create(Super.prototype, {constructor:{value: Sub}})
//   sem o descritor, Sub.prototype.constructor HERDA o do Super
//   _createSuper → NewTarget = _getPrototypeOf(this).constructor  === Super (errado)
//   Reflect.construct(Super, args, NewTarget) → instância com protótipo do SUPER
//   → os métodos da subclasse não existem na instância.
// Por isso o teste que importa aqui é o ÚLTIMO: ele reproduz a cadeia inteira.

@(test)
object_create_aplica_descritor_de_valor :: proc(t: ^testing.T) {
    r := run(`
        var p = { m: function () { return 4; } };
        var o = Object.create(p, { k: { value: 42, writable: true, configurable: true } });
        o.k === 42 && o.m() === 4 && Object.getPrototypeOf(o) === p
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "descritor de valor aplicado, e o protótipo continua certo")
}

@(test)
object_create_aplica_getter :: proc(t: ^testing.T) {
    r := run(`
        var o = Object.create(null, { g: { get: function () { return 7; } } });
        o.g === 7
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "descritor de acessor (get) aplicado")
}

@(test)
object_create_respeita_enumerable :: proc(t: ^testing.T) {
    // ⚠️ o default de `enumerable` é FALSE. Um conserto que só fizesse
    // `o.props[k] = valor` daria a prop certa e a enumerabilidade ERRADA —
    // e `Object.keys` é exatamente o que o código de lib usa para copiar objetos.
    r := run(`
        var o = Object.create(null, {
            escondida: { value: 1 },
            visivel:   { value: 2, enumerable: true }
        });
        o.escondida === 1 && o.visivel === 2 && Object.keys(o).join() === 'visivel'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "não-enumerável por default; enumerable:true aparece em Object.keys")
}

@(test)
object_create_sem_descritores_intacto :: proc(t: ^testing.T) {
    // CONTROLES: as duas formas que já funcionavam e passam pelo mesmo código.
    r := run(`
        var p = { m: function () { return 1; } };
        var a = Object.create(p);
        var b = Object.create(null);
        var c = Object.create(p, undefined);
        a.m() === 1 && Object.getPrototypeOf(b) === null && c.m() === 1
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "Object.create(p) / (null) / (p, undefined) seguem iguais")
}

@(test)
define_properties_continua_funcionando :: proc(t: ^testing.T) {
    // O helper virou COMPARTILHADO com o Object.create; este caso garante que a
    // extração não levou o defineProperties junto.
    r := run(`
        var o = {};
        Object.defineProperties(o, { a: { value: 1, enumerable: true }, b: { get: function () { return 2; } } });
        o.a === 1 && o.b === 2 && Object.keys(o).join() === 'a'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "Object.defineProperties intacto depois da extração do helper")
}

@(test)
cadeia_babel_do_clipboardjs :: proc(t: ^testing.T) {
    // O TESTE QUE IMPORTA: a forma exata que quebrava no getbootstrap.com.
    // Sem o descritor `constructor`, `u` nasce com o protótipo da Base e
    // `u.metodoDaSub()` lança "is not a function".
    r := run(`
        function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }
        function _inherits(sub, sup) {
            sub.prototype = Object.create(sup && sup.prototype, {
                constructor: { value: sub, writable: true, configurable: true }
            });
            if (sup) Object.setPrototypeOf(sub, sup);
        }
        function _createSuper(Derived) {
            return function () {
                var Super = _getPrototypeOf(Derived);
                var NewTarget = _getPrototypeOf(this).constructor;
                return Reflect.construct(Super, arguments, NewTarget);
            };
        }
        function Base() {}
        var chamarSuper = null;
        function Sub() { var u = chamarSuper.call(this); u.metodoDaSub(); return u; }
        _inherits(Sub, Base);
        chamarSuper = _createSuper(Sub);
        Object.defineProperty(Sub.prototype, 'metodoDaSub', {
            value: function () { this.rodou = true; }, writable: true, configurable: true
        });
        var inst = new Sub();
        inst.rodou === true && Sub.prototype.constructor === Sub
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "cadeia _inherits+_createSuper+Reflect.construct chega ao método da subclasse")
}
