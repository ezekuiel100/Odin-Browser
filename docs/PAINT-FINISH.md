# Acabamento da pintura

As bordas com cores ou larguras diferentes usam um anel de geometria compartilhada.
Os lados se encontram sem sobrepor tinta, inclusive com cores translucidas. As
curvas internas descontam as larguras horizontal e vertical separadamente.
O caminho de bordas uniformes permanece no traco arredondado do ImGui.

Sombras externas e internas sao pintadas de tras para frente: a primeira sombra
da lista fica por cima. Cores opacas seguem a mesma convencao das outras cores
CSS, e a ausencia de cor usa `currentColor` (tambem para `text-shadow`).
Um spread negativo que elimina a caixa nao produz um retangulo invertido.

Validacao visual automatizada: `tests/paint/paint-finish.html`, executada por
`paint-check.ps1`. Verifica alpha dos cantos, interior arredondado, opacidade,
ordem das sombras e cor implicita.

Limites existentes: o blur de box-shadow continua aproximado por camadas de
retangulos; o recorte de overflow arredondado continua baseado em mascaras;
raios distintos por canto ainda usam a aproximacao do maior raio com flags.
A malha de bordas desiguais usa segmentos para aproximar as curvas.
