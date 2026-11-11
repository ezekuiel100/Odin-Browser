# Mascaras de imagem SVG

O renderizador aceita uma imagem SVG em `mask-image` ou no shorthand `mask`,
incluindo as formas `-webkit-`. A URL pode apontar para um arquivo externo ou
conter SVG em uma URL `data:` com percent-encoding ou base64.

```css
.icon {
  background-color: currentColor;
  mask: url(icon.svg) center / contain no-repeat;
}
```

A imagem altera a transparencia do elemento inteiro, incluindo seus filhos.
O RGB do elemento permanece independente da cor do SVG. O modo padrao usa
alpha; `mask-mode:luminance` usa a luminancia multiplicada pelo alpha.
Uma imagem pendente ou que falhou deixa o grupo transparente. A chegada da
imagem invalida o cache da camada.

Estao implementados `mask-size` (`auto`, `contain`, `cover`, comprimentos e
percentuais), posicao de um ou dois valores, repeticao nos dois eixos e as
areas `border-box`, `padding-box` e `content-box`. Mascaras de gradiente
continuam usando o caminho anterior.

Limites atuais: uma unica camada de imagem SVG; referencias a elementos
`<mask>` por fragmento, imagens raster como mascara, `mask-composite`,
`mask-repeat:round/space` e posicao de quatro valores ainda nao estao implementados.
A imagem usa os recursos de desenho ja oferecidos pelo renderizador SVG.

O reftest `tests/reftest/svg-mask-image-001.html` cobre URLs `data:`, repeticao,
alpha parcial, recorte dos filhos, luminancia, posicionamento e falha da imagem.
Seu gabarito e `svg-mask-image-001-ref.html`.
