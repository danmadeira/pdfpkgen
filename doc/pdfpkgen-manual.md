# Manual técnico da package PDFPKGEN
Este manual descreve a instalação, o modelo de coordenadas e o uso das rotinas públicas da package Oracle PL/SQL `PDFPKGEN`. A package constrói um PDF 1.4 em memória e retorna o documento como um `BLOB` temporário.

## 1. Escopo e requisitos

- Oracle Database com suporte a PL/SQL, `DBMS_LOB`, `UTL_RAW` e `UTL_I18N`.
- A package specification e o body devem ser instalados no mesmo schema, nessa ordem: [pdfpkgen.pks](../src/pdfpkgen.pks) e depois [pdfpkgen.pkb](../src/pdfpkgen.pkb). Esses scripts criam o objeto Oracle `PDFPKGEN`.
- Para persistir os resultados dos exemplos, são necessárias uma tabela repositório com coluna `BLOB` e uma sequência. Esses objetos não fazem parte da package.
- Sem fonte Unicode configurada, o texto deve ser representável em Windows-1252/WinAnsi.

Após compilar a package, consulte eventuais erros no schema:

```sql
SELECT type, line, position, text
FROM user_errors
WHERE name = 'PDFPKGEN'
ORDER BY sequence;
```

A package guarda o estado do documento em variáveis de pacote: páginas, cores, tabela e imagens. Comece cada documento com `pdfpkgen.new_document`; não é seguro intercalar a composição de vários documentos na mesma sessão.

Internamente, cada página acumula operadores PDF em um CLOB temporário. `generate` converte esses fluxos para bytes Windows-1252, monta os objetos PDF, os recursos compartilhados (fontes e imagens), a tabela de referências cruzadas (`xref`) e o trailer. O resultado é um BLOB temporário; a package não cria arquivos no sistema operacional.

## 2. Coordenadas e página

O padrão é A4 em retrato, aproximadamente $595 \times 842$ pontos, com margens iniciais de 40 pontos em cada lado. As coordenadas usam pontos PDF: $72$ pontos equivalem a uma polegada. A origem $(0,0)$ fica no canto inferior esquerdo; portanto, valores crescentes de $y$ sobem na página.

Configure o tamanho da página antes de `new_document`. Os formatos predefinidos são A4, Letter e Legal; `P` significa retrato e `L`, paisagem. Também é possível informar largura e altura personalizadas em pontos. A orientação paisagem troca largura e altura do formato selecionado.

```sql
-- Formato padrão internacional, paisagem
pdfpkgen.set_page_size('A4', 'L');

-- Ou formato Carta em retrato
pdfpkgen.set_page_size('LETTER', 'P');

-- Ou dimensões customizadas: 720 × 900 pontos
pdfpkgen.set_page_size(720, 900);

pdfpkgen.new_document;
```

Para documentos sucessivos na mesma sessão, chame `generate` para concluir o atual; depois configure tamanho e margens do próximo documento e chame `new_document`. A mudança de tamanho durante a composição é rejeitada. Dimensões precisam ser positivas e as margens configuradas devem deixar uma área útil.

`set_margins_cm` recebe as quatro margens em centímetros e converte para pontos. Chame-a **antes** de `new_document` para a primeira página já usar a margem superior configurada.

```sql
pdfpkgen.set_margins_cm(
    p_top_cm    => 3,
    p_left_cm   => 3,
    p_right_cm  => 2,
    p_bottom_cm => 2
);
pdfpkgen.new_document;
```

Margens devem ser não negativas e deixar área útil dentro da página. `add_page` cria uma página em branco; ao mudar de página manualmente, o código chamador deve posicionar novamente títulos e conteúdo.

## 3. Ciclo básico

1. Configure formato/orientação ou dimensões personalizadas e margens, se necessário.
2. Chame `pdfpkgen.new_document`.
3. Adicione texto, formas, tabelas e imagens.
4. Chame `pdfpkgen.generate` para obter o `BLOB` PDF.
5. Persista ou transmita o BLOB e, quando não for mais necessário, libere-o com `DBMS_LOB.FREETEMPORARY`.

```sql
DECLARE
    l_pdf BLOB;
BEGIN
    pdfpkgen.new_document;
    pdfpkgen.write_text(40, 780, 'Meu relatório', 18, TRUE);
    l_pdf := pdfpkgen.generate;

    -- Persistir ou transmitir l_pdf aqui.

    IF DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pdf);
    END IF;
END;
/
```

`generate` não salva o PDF em arquivo nem em tabela: apenas retorna o BLOB. Se a aplicação executar `COMMIT`, deve fazê-lo somente depois de persistir o BLOB. Em tratamento de erro, libere o BLOB temporário se ele já tiver sido criado.

### Validação de argumentos

As rotinas validam dimensões e coordenadas antes de emitir operadores PDF: tamanhos de página, fonte, margens, células, retângulos e imagens devem ser positivos quando aplicável; posições explícitas e elementos visuais devem permanecer dentro da página. Componentes RGB são números inteiros de `0` a `255`; trios opcionais devem ser informados por completo ou deixados inteiramente `NULL`. Alinhamentos horizontais aceitam `L`, `C` ou `R` (parágrafos também aceitam `J`); alinhamentos verticais aceitam `T`, `M` ou `B`.

Operações de caminho exigem a sequência `begin_path` → `add_line_to`/`add_curve`/`close_path` → `stroke_path` ou `fill_path`. Desenhar uma imagem, linha, retângulo ou tabela enquanto há um caminho sem pintura gera erro para evitar que operadores incompatíveis consumam a geometria. `add_image` valida o conteúdo e a compatibilidade do PNG/JPEG, a escala e o retângulo final dentro da página; transparência parcial não representável é rejeitada explicitamente.

Erros são levantados com `RAISE_APPLICATION_ERROR` e mensagens que identificam a regra violada (por exemplo, dimensões fora da página, RGB fracionário, alinhamento desconhecido, operação de caminho fora de sequência ou combinação incompatível de opções de imagem). Os códigos `-20082` a `-20089` identificam validações de geometria, caminho e posicionamento de imagem.

### Metadados do PDF

Use `set_metadata` para definir título, autor, assunto e palavras-chave no dicionário Info do PDF. Os campos são opcionais, aceitam texto Unicode e cada um tem limite de 4000 bytes. Passe `NULL` para limpar um campo; uma chamada sem argumentos limpa todos. A configuração permanece no estado da package até ser alterada.

```sql
pdfpkgen.set_metadata(
    p_title    => 'Relatório de operações',
    p_author   => 'Equipe de dados',
    p_subject  => 'Resumo mensal',
    p_keywords => 'operações, mensal, 2026'
);
pdfpkgen.new_document;
```

Os metadados são gravados como strings Unicode UTF-16BE, para leitores de PDF exibirem corretamente caracteres fora de WinAnsi. Se nenhum campo estiver definido, o dicionário Info é omitido.

## 4. API de documentos e layout

### `new_document`

Libera páginas e imagens temporárias do documento anterior, limpa o estado interno e inicia uma página. É a rotina recomendada para começar cada PDF.

### `add_page`

Acrescenta uma página em branco. O cursor vertical automático volta ao topo, respeitando a margem superior atual. Elementos posicionados por coordenadas explícitas não são repetidos. Cabeçalhos de tabela registrados por `add_header` são repetidos quando uma linha da tabela é levada para uma nova página.

### Cabeçalho e rodapé por página

Configure `set_page_header` e `set_page_footer` antes de `new_document`. Os textos são desenhados automaticamente em todas as páginas, inclusive na primeira e nas criadas por paginação. Ambos aceitam tamanho, negrito, alinhamento horizontal (`L`, `C`, `R`) e uma coordenada Y opcional em pontos. Sem Y explícito, o cabeçalho aparece dentro da margem superior e o rodapé dentro da margem inferior. Use `{PAGE}` no texto para inserir o número da página atual.

```sql
pdfpkgen.set_page_header('RELATÓRIO DE VENDAS', 9, TRUE, 'L');
pdfpkgen.set_page_footer('Página {PAGE}', 9, FALSE, 'R');
pdfpkgen.new_document;
```

Para desativar um deles no próximo documento, configure seu texto como `NULL`. A configuração deve ser feita antes do início do documento e permanece para documentos sucessivos até ser substituída.

### `current_y`

Retorna a posição vertical atual do cursor usado por `write_line` e `write_paragraph`. É útil para encadear blocos:

```sql
pdfpkgen.write_paragraph(40, 700, 500, 'Primeiro bloco...', 11, 8, 'L');
pdfpkgen.write_paragraph(40, pdfpkgen.current_y, 500, 'Bloco seguinte...', 11, 8, 'L');
```

### `set_margins_cm`

Assinatura: `set_margins_cm(p_top_cm, p_left_cm, p_right_cm, p_bottom_cm)`. Define margens em centímetros. A rotina altera o estado do pacote e deve ser chamada antes de criar o documento/páginas que usarão essa configuração.

### `set_page_size`

Use `set_page_size(formato, orientação)` com `A4`, `LETTER` ou `LEGAL` e orientação `P` (retrato) ou `L` (paisagem). Para dimensões personalizadas, use `set_page_size(largura_pt, altura_pt)`. As dimensões devem ser positivas e compatíveis com as margens atuais. Configure antes de `new_document`; após concluir um documento com `generate`, é possível definir o tamanho do próximo.

## 5. Texto

### Fonte Unicode TrueType incorporada

Armazene um arquivo `.ttf` licenciado como BLOB e chame `set_unicode_font` antes de `new_document`. A package incorpora a fonte completa no PDF, cria uma fonte Type0/CIDFontType2 com codificação Identity-H e adiciona um mapa ToUnicode para cópia/pesquisa do texto. A fonte é mantida para documentos seguintes da sessão até `clear_unicode_font` ou outra chamada a `set_unicode_font`.

```sql
DECLARE
    l_font BLOB;
BEGIN
    SELECT blob_content
    INTO l_font
    FROM repositorio_arquivo
    WHERE filename = 'DejaVuSans.ttf';

    pdfpkgen.set_unicode_font(l_font, 'DejaVuSans');
    pdfpkgen.new_document;
    pdfpkgen.write_text(40, 780, 'Português: ação, coração e informação', 18);
    pdfpkgen.write_text(40, 750, 'Ελληνικά — Русский', 14);
END;
/
```

O exemplo requer que a fonte TTF já esteja armazenada em `repositorio_arquivo.blob_content`; a package não distribui fontes. São suportadas fontes TrueType com `cmap` Unicode BMP formato 4 e caracteres até U+FFFF, desde que cada caractere exista na fonte escolhida. A DejaVu Sans cobre português, grego e cirílico, mas normalmente não contém glifos CJK; use uma TTF licenciada com cobertura adequada para esses alfabetos. Fontes OTF-CFF/WOFF, caracteres suplementares (como emojis), ligaduras e modelagem/shaping complexo não são suportados. A face TTF carregada é usada como uma única face; para obter variantes reais bold/italic, carregue a variante correspondente em outro documento.

### `write_text`

Escreve uma linha em posição absoluta:

`write_text(p_x, p_y, p_text, p_size, p_bold, p_italic, p_align)`

- `p_x`, `p_y`: posição em pontos PDF.
- `p_text`: texto Windows-1252/WinAnsi por padrão; com fonte Unicode configurada, texto BMP representado pela fonte incorporada.
- `p_size`: tamanho da fonte em pontos; padrão `10`.
- `p_bold`, `p_italic`: selecionam variantes Helvetica no modo padrão. Com TTF Unicode, a face carregada é usada; carregue arquivos de variante separados para bold/italic.
- `p_align`: `L` esquerda, `C` centro ou `R` direita. Para `C` e `R`, `p_x` é o centro ou a borda final do texto, respectivamente.

No modo padrão, as métricas da Helvetica usadas para alinhamento são estimativas e podem variar ligeiramente em relação ao visualizador de PDF. No modo Unicode, são usados os avanços horizontais da TTF, sem kerning.

### Medição de texto

- `measure_text_width(texto, tamanho, negrito)` retorna a largura em pontos PDF. No modo padrão, usa métricas aproximadas Helvetica; no modo Unicode, usa os avanços da fonte incorporada. `p_size` deve ser positivo.
- `measure_paragraph_height(texto, largura, tamanho, espaçamento_linha, negrito)` calcula a altura estimada após quebra automática. O espaçamento entre linhas padrão é 4 pontos; o resultado não inclui o espaçamento final de `write_paragraph`.

As funções e a renderização compartilham o mesmo algoritmo de quebra: palavras são mantidas juntas sempre que cabem; uma palavra maior que a largura disponível é dividida por caracteres. Quebras CR/LF e linhas vazias explícitas são preservadas, tabulações viram espaços e sequências de espaços são normalizadas. Sem fonte Unicode, as larguras são estimativas da Helvetica. Com fonte Unicode, são usados os avanços horizontais da TTF incorporada; kerning e shaping tipográfico complexo continuam fora do escopo.

```sql
DECLARE
    l_width  NUMBER;
    l_height NUMBER;
BEGIN
    l_width := pdfpkgen.measure_text_width('Texto de exemplo', 11);
    l_height := pdfpkgen.measure_paragraph_height(
        p_text  => 'Um parágrafo que será quebrado conforme a largura.',
        p_width => 250,
        p_size  => 11
    );
    DBMS_OUTPUT.PUT_LINE('Largura: ' || l_width || ' pt; altura: ' || l_height || ' pt');
END;
/
```

### `write_line`

Escreve uma linha na margem esquerda atual e move o cursor vertical para baixo por `p_size + 4` pontos. Se esse avanço ultrapassar a margem inferior, inicia uma página automaticamente e continua no topo da nova página. O cursor de `current_y` acompanha a nova posição.

### `write_paragraph`

Assinatura: `write_paragraph(p_x, p_y, p_width, p_text, p_size, p_paragraph_spacing, p_align)`.

- `p_x`, `p_y`: início da área do parágrafo em pontos.
- `p_width`: largura da caixa em pontos; precisa ser positiva.
- `p_text`: conteúdo Windows-1252/WinAnsi. Quebras `CR`, `LF` e `CR/LF` são tratadas como quebras explícitas; tabulações viram espaços.
- `p_size`: tamanho em pontos; padrão `10`.
- `p_paragraph_spacing`: espaço vertical adicional após o parágrafo, em pontos; padrão `0`.
- `p_align`: `L` esquerda, `C` centro, `R` direita ou `J` justificado; padrão `L`.

O texto é quebrado automaticamente por largura estimada da fonte. Em `J`, as linhas intermediárias são justificadas; a última linha do bloco permanece sem justificação. Cada linha verifica o espaço restante e continua automaticamente em uma página nova quando necessário; `current_y` reflete a posição após a paginação. Se a altura de uma linha individual exceder toda a área útil vertical, a package gera erro em vez de desenhá-la fora da página. Use `measure_paragraph_height` para estimar previamente a altura total.


`write_text`, desenho vetorial e `add_image` usam coordenadas absolutas e não fazem paginação nem reposicionamento automático. Para conteúdo corrido, use `write_line` ou `write_paragraph`.

Exemplo:

```sql
pdfpkgen.write_paragraph(
    p_x                 => 40,
    p_y                 => 700,
    p_width             => 515,
    p_text              => 'Texto longo a ser ajustado à largura da caixa.',
    p_size              => 11,
    p_paragraph_spacing => 8,
    p_align             => 'J'
);
```

## 6. Tabelas

### Fluxo recomendado

1. `begin_table(x, y)` posiciona a primeira célula.
2. Opcionalmente, chame `set_table_header_style(...)`; em seguida cada `add_header(texto, largura, alinhamento)` armazena e **desenha imediatamente** sua célula.
3. `next_row(altura)` encerra o cabeçalho e posiciona a linha de dados.
4. Para cada coluna, chame `add_cell(texto, largura, altura, alinhamento)`. As células da linha são acumuladas temporariamente e ainda não aparecem no fluxo da página.
5. Chame `next_row` para verificar o espaço, desenhar a linha inteira e avançar. Se ela não couber, a package começa uma página nova, repete o cabeçalho e desenha a linha sem dividi-la.

Os alinhamentos horizontais são `L`, `C` e `R`; os verticais são `T` (topo), `M` (meio) e `B` (base). `add_cell` quebra automaticamente o texto pela largura interna e calcula a altura mínima da célula. Cada célula pode definir `p_border` (habilitar/desabilitar borda), cor RGB opcional da borda (`p_border_r/g/b`), preenchimento RGB opcional (`p_fill_r/g/b`), `p_padding` em pontos, `p_valign`, cor RGB do texto (`p_text_r/g/b`) e `p_bold`. RGB deve ser informado como trio completo com canais de 0 a 255. Sem RGB de preenchimento, a célula fica transparente; borda e texto sem RGB próprio herdam as cores atuais. Padding padrão: 2 pontos.
Os alinhamentos horizontais são `L`, `C` e `R`; os verticais são `T` (topo), `M` (meio) e `B` (base). `add_cell` quebra automaticamente o texto pela largura interna e calcula a altura mínima da célula. A paginação compensa a altura efetiva de cada linha, mantendo as bordas contíguas quando linhas sucessivas têm alturas diferentes. Cada célula pode definir `p_border` (habilitar/desabilitar borda), cor RGB opcional da borda (`p_border_r/g/b`), preenchimento RGB opcional (`p_fill_r/g/b`), `p_padding` em pontos, `p_valign`, cor RGB do texto (`p_text_r/g/b`) e `p_bold`. RGB deve ser informado como trio completo com canais de 0 a 255. Sem RGB de preenchimento, a célula fica transparente; borda e texto sem RGB próprio herdam as cores atuais. Padding padrão: 2 pontos.

A altura de avanço da linha é o maior valor entre o argumento de `next_row` e as alturas calculadas das células. `generate` também desenha a última linha pendente. Uma linha que exceda a área útil (considerando o cabeçalho repetido) causa erro. Cabeçalhos continuam em uma linha. `begin_table` inicia uma tabela independente e limpa o estado da anterior.

Após `begin_table` e antes de adicionar cabeçalhos, `set_table_header_style` configura o estilo compartilhado por todas as colunas do cabeçalho — preenchimento, cor da borda e do texto, negrito, borda, padding e alinhamento vertical. O estilo não pode ser alterado depois do primeiro `add_header`; ele é reaplicado automaticamente nos cabeçalhos repetidos em novas páginas.


```sql
pdfpkgen.begin_table(40, 650);
pdfpkgen.set_table_header_style(
    p_fill_r => 38, p_fill_g => 112, p_fill_b => 145,
    p_border_r => 25, p_border_g => 79, p_border_b => 105,
    p_text_r => 255, p_text_g => 255, p_text_b => 255,
    p_bold => TRUE, p_padding => 5, p_valign => 'M'
);
pdfpkgen.add_header('Produto', 250, 'L');
pdfpkgen.add_header('Qtd.', 70, 'C');
pdfpkgen.add_header('Total', 195, 'R');
pdfpkgen.next_row(24);
pdfpkgen.add_cell(
    'Caderno executivo com descrição longa que quebra em várias linhas', 250, 22, 'L',
    p_border => TRUE,
    p_border_r => 170, p_border_g => 180, p_border_b => 188,
    p_fill_r => 238, p_fill_g => 245, p_fill_b => 250,
    p_padding => 6, p_valign => 'T'
);
pdfpkgen.add_cell('12', 70, 22, 'C');
pdfpkgen.add_cell('R$ 222,00', 195, 22, 'R');
pdfpkgen.next_row(22);
```

`add_header` exige que `begin_table` tenha sido chamado. Não chame `add_header` se quiser somente uma célula comum; use `add_cell`.

## 7. Cores e desenho

### Cores

`set_fill_color(r, g, b)` define preenchimento e cor do texto; `set_stroke_color(r, g, b)` define contorno. Cada canal RGB vai de `0` a `255` e é limitado pela implementação a esse intervalo. A cor permanece ativa até ser alterada.

### Linha e retângulo

- `draw_line(x1, y1, x2, y2)` desenha e traça uma linha com a cor de contorno atual.
- `draw_rect(x, y, largura, altura)` desenha **e já traça** o retângulo. A rotina termina o caminho com `S`; não a use esperando preencher esse mesmo caminho com `fill_path`.

### Paths e curvas Bézier

Use `begin_path(x, y)`, depois um ou mais `add_line_to(x, y)` e `add_curve(cx1, cy1, cx2, cy2, x, y)`. `close_path` fecha a forma. Em seguida, escolha `stroke_path` para contornar ou `fill_path` para preencher.

Os operadores de pintura (`S` e `f`) consomem o caminho atual. Para preencher e também contornar uma forma, reconstrua o caminho entre as duas operações, como faz o exemplo abaixo.

```sql
pdfpkgen.set_fill_color(165, 214, 167);
pdfpkgen.set_stroke_color(46, 125, 50);
pdfpkgen.begin_path(60, 100);
pdfpkgen.add_line_to(120, 180);
pdfpkgen.add_curve(150, 200, 190, 180, 210, 130);
pdfpkgen.close_path;
pdfpkgen.fill_path;

-- O caminho foi consumido por fill_path; reconstrua-o para o contorno.
pdfpkgen.begin_path(60, 100);
pdfpkgen.add_line_to(120, 180);
pdfpkgen.add_curve(150, 200, 190, 180, 210, 130);
pdfpkgen.close_path;
pdfpkgen.stroke_path;
```

## 8. Imagens

`add_image(p_image_blob, p_x, p_y, p_width, p_height, p_scale, p_text_align, p_text_size)` incorpora uma imagem. `p_x` é a coordenada horizontal da borda esquerda; `p_y` é a borda inferior da imagem quando o alinhamento é `B` (padrão), ou a linha de base do texto nos alinhamentos `T` e `M`.

- O argumento precisa ser um `BLOB` válido em formato JPEG ou PNG suportado.
- JPEG: RGB, 8 bits por componente, três componentes.
- PNG: grayscale ou RGB de 8 bits, ou paleta indexada de 1, 2, 4 ou 8 bits; não entrelaçado. O chunk `tRNS` é aceito como transparência binária: cor-chave em grayscale/RGB ou entradas transparentes iniciais da paleta (alpha zero, entradas restantes opacas).
- Não são suportados canais alpha explícitos (PNG grayscale+alpha/RGBA), valores de alpha parciais em paletas, APNG, PNG de 16 bits ou entrelaçamento.
- `p_width` e `p_height` têm padrão `0`. Se uma dimensão for `NULL` ou `0`, a package calcula essa dimensão pela proporção original. Se ambas forem omitidas/zero, usa as dimensões em pixels como dimensões de exibição em pontos.
- `p_scale` é um fator positivo aplicado às dimensões naturais em pixels, convertidas em pontos; use-o em vez de `p_width`/`p_height` (deixe ambos em `0`). Por exemplo, `0.5` desenha à metade do tamanho natural.
- `p_text_align`: `B` mantém o comportamento de coordenada inferior; `T` alinha o topo da imagem ao topo estimado do texto; `M` centraliza a imagem verticalmente na caixa do texto. `p_y` é a linha de base e `p_text_size` (padrão `10` pontos) define a altura estimada dessa caixa.
- A package copia os dados da imagem ao adicioná-la; a imagem original pode ser liberada depois da chamada.

Exemplo que define apenas a largura e preserva a proporção:

```sql
pdfpkgen.add_image(
    p_image_blob => l_logo,
    p_x          => 40,
    p_y          => 600,
    p_width      => 180
    -- p_height omitido: calculado a partir da proporção da imagem.
);
```

PNG é descompactado apenas no sentido de extrair e concatenar seus chunks `IDAT`; o fluxo zlib/Deflate permanece comprimido. O PDF usa `FlateDecode` com `DecodeParms` e predictor PNG. O parser valida estrutura e limites dos chunks, mas não valida CRC nem decodifica integralmente a imagem para detectar corrupção dos pixels.

```sql
-- Escala natural de 0,5 e alinhamento do meio da imagem à linha de texto.
pdfpkgen.add_image(
    p_image_blob => l_logo,
    p_x          => 40,
    p_y          => 720, -- linha de base do texto
    p_scale      => 0.5,
    p_text_align => 'M',
    p_text_size  => 14
);
```

Ao chamar `new_document`, a package libera os BLOBs temporários de imagem que guardou para o documento anterior.

## 9. Exemplo de persistência em tabela

O padrão abaixo usa nomes de objetos específicos da aplicação. Ajuste a tabela e a sequência ao schema instalado.

```sql
DECLARE
    l_pdf      BLOB;
    l_id       NUMBER;
    l_filename VARCHAR2(100);
BEGIN
    pdfpkgen.new_document;
    pdfpkgen.write_text(40, 780, 'Relatório', 18, TRUE);
    l_pdf := pdfpkgen.generate;

    l_id := repositorio_arquivo_seq.NEXTVAL;
    l_filename := 'relatorio-' || TO_CHAR(l_id) || '.pdf';

    INSERT INTO repositorio_arquivo
        (id, blob_content, mime_type, filename, charset, last_updated, md5_hash)
    VALUES
        (l_id, l_pdf, 'application/pdf', l_filename, NULL, CURRENT_TIMESTAMP, NULL);
    COMMIT;

    IF DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pdf);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        IF l_pdf IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_pdf);
        END IF;
        RAISE;
END;
/
```

## 10. Limitações e recomendações

- A página gerada é A4; coordenadas fora dos limites ou margens não são automaticamente recortadas à área útil.
- `set_margins_cm` configura a paginação do cursor, mas chamadas absolutas como `write_text`, `draw_line`, `draw_rect` e `add_image` usam exatamente as coordenadas recebidas.
- A paginação automática existe para `write_line`, `write_paragraph` e linhas de tabela confirmadas por `next_row` (ou finalizadas por `generate`); texto absoluto não cria outra página automaticamente.
- `add_cell` quebra o texto de dados e calcula uma altura mínima; cabeçalhos de tabela continuam limitados a uma linha. Parágrafos são quebrados conforme a largura fornecida.
- As métricas de Helvetica para alinhamento e quebra são aproximações. Faça revisão visual para layouts que exijam precisão tipográfica.
- O PDF é montado em memória. Para documentos ou imagens grandes, considere o consumo de PGA/LOB temporário e libere todos os BLOBs temporários após o uso.
- Sem TTF configurada, a package usa as quatro fontes Type 1 padrão: Helvetica regular, bold, oblique e bold-oblique. A fonte Unicode incorporada é uma única face TTF e atualmente aceita somente BMP/cmap formato 4, sem ligaduras nem shaping complexo.

## 11. Exemplo incluído no projeto

- [relatorio.sql](../exemplo/relatorio.sql): relatório editorial de várias páginas que reúne capa, cartões de indicadores, gráfico Bézier, tabela paginada, metadados e recursos opcionais de imagem e fonte Unicode.

## 12. Referência completa da API pública

Todas as rotinas abaixo pertencem à package Oracle `PDFPKGEN`. Os parâmetros são de entrada; a API pública não possui parâmetros `OUT` ou `IN OUT`. Os valores padrão são os declarados na specification.

### Ciclo do documento e metadados

- `new_document`: limpa os dados temporários do documento anterior e inicia um documento com a primeira página. Mantém configurações da sessão, como tamanho, margens, cabeçalho/rodapé, metadados e fonte Unicode.
- `add_page`: acrescenta uma página ao documento ativo, reinicia a posição do cursor e reaplica o cabeçalho/rodapé configurado.
- `set_metadata(p_title, p_author, p_subject, p_keywords)`: configura título, autor, assunto e palavras-chave no dicionário Info do PDF. Todos são `VARCHAR2`, opcionais e padrão `NULL`; cada valor aceita até 4000 bytes. `NULL` limpa o campo. A configuração permanece na sessão até ser alterada.
- `set_page_header(p_text, p_size, p_bold, p_align, p_y)`: configura o texto repetido no topo de cada página. `p_text` é `VARCHAR2`; `p_size` é positivo em pontos (9); `p_bold` ativa negrito (`FALSE`); `p_align` é `L`, `C` ou `R` (`C`); `p_y` é coordenada vertical opcional em pontos (`NULL`, posição automática). `{PAGE}` é substituído pelo número da página.
- `set_page_footer(p_text, p_size, p_bold, p_align, p_y)`: mesmos parâmetros e regras de `set_page_header`, para o rodapé. Configure ambos antes de `new_document`.
- `set_unicode_font(p_font_blob, p_font_name)`: carrega uma fonte TrueType licenciada em `p_font_blob` (`BLOB`) antes de `new_document`; `p_font_name` é o nome PDF (`PDFGenUnicode`). Requer `cmap` Unicode formato 4 e suporta caracteres BMP existentes na fonte.
- `clear_unicode_font`: libera a fonte Unicode carregada; chame fora de um documento ativo.

### Página e margens

- `set_page_size(p_format, p_orientation)`: escolhe formato `A4`, `LETTER` ou `LEGAL` (`VARCHAR2`); `p_orientation` é `P` (retrato) ou `L` (paisagem), padrão `P`. Configure antes de `new_document`.
- `set_page_size(p_width_pts, p_height_pts)`: sobrecarga que define largura e altura personalizadas em pontos PDF; ambas devem ser positivas. Configure antes de `new_document`.
- `set_margins_cm(p_top_cm, p_left_cm, p_right_cm, p_bottom_cm)`: configura as quatro margens em centímetros, nesta ordem. Devem ser não negativas e deixar área útil; chame antes de `new_document`.

### Texto e medição

- `write_text(p_x, p_y, p_text, p_size, p_bold, p_italic, p_align)`: desenha texto em coordenadas absolutas X/Y, em pontos. `p_text` é `VARCHAR2`; sem fonte Unicode, deve ser WinAnsi. `p_size` é positivo (10); `p_bold` e `p_italic` selecionam variantes da fonte (ambos `FALSE`); `p_align` é `L`, `C` ou `R` (`L`). Para alinhamento central ou à direita, X representa o centro ou a borda final.
- `write_line(p_text, p_size, p_bold, p_italic)`: escreve no cursor atual, avança o cursor e pagina automaticamente. `p_size` é positivo (10); negrito e itálico são opcionais (`FALSE`).
- `write_paragraph(p_x, p_y, p_width, p_text, p_size, p_paragraph_spacing, p_align)`: escreve parágrafo com quebra automática a partir de X/Y, dentro de `p_width`, em pontos. `p_text` é `VARCHAR2`; `p_size` é positivo (10); `p_paragraph_spacing` é não negativo e define o espaço após o bloco (0); `p_align` é `L`, `C`, `R` ou `J` (esquerda). Preserva quebras explícitas e pagina automaticamente.
- `measure_text_width(p_text, p_size, p_bold) RETURN NUMBER`: retorna a largura estimada em pontos. `p_size` é positivo (10); `p_bold` seleciona métrica aproximada em negrito (`FALSE`). Com fonte Unicode, usa os avanços horizontais da TTF.
- `measure_paragraph_height(p_text, p_width, p_size, p_line_spacing, p_bold) RETURN NUMBER`: retorna a altura estimada após quebra automática. `p_width` e `p_size` são positivos; `p_size` padrão 10, `p_line_spacing` é não negativo e padrão 4 pontos, `p_bold` padrão `FALSE`. O retorno não inclui o espaçamento final do parágrafo.
- `current_y RETURN NUMBER`: retorna a posição atual do cursor vertical em pontos; exige documento ativo.

### Tabelas

- `begin_table(p_x, p_y)`: inicia uma tabela nas coordenadas absolutas X/Y, em pontos, e limpa o estado de tabela anterior.
- `set_table_header_style(p_fill_r, p_fill_g, p_fill_b, p_border_r, p_border_g, p_border_b, p_text_r, p_text_g, p_text_b, p_bold, p_border, p_padding, p_valign)`: configura o estilo compartilhado do cabeçalho antes do primeiro `add_header`. Cada trio RGB opcional define preenchimento, borda ou texto; informe todos os canais ou deixe todos `NULL`, com inteiros de 0 a 255. `p_bold` ativa negrito (`FALSE`), `p_border` ativa borda (`TRUE`), `p_padding` é interno em pontos (2), e `p_valign` é `T`, `M` ou `B` (`M`).
- `add_header(p_text, p_width, p_align)`: adiciona e desenha uma coluna de cabeçalho. `p_text` é `VARCHAR2`, `p_width` é positivo em pontos e `p_align` é `L`, `C` ou `R` (`L`). Cabeçalhos registrados são repetidos quando a tabela pagina.
- `add_cell(p_text, p_width, p_height, p_align, p_border, p_border_r, p_border_g, p_border_b, p_fill_r, p_fill_g, p_fill_b, p_padding, p_valign, p_text_r, p_text_g, p_text_b, p_bold)`: acumula uma célula na linha atual. `p_text` é `VARCHAR2`; largura e altura são positivas (altura padrão 20 pontos); `p_align` é `L`, `C` ou `R` (`L`); `p_border` habilita borda (`TRUE`); trios RGB opcionais usam inteiros de 0 a 255; `p_padding` é não negativo e menor que metade da largura (2 pontos); `p_valign` é `T`, `M` ou `B` (`M`); `p_bold` padrão `FALSE`. A altura efetiva da linha considera o conteúdo quebrado.
- `next_row(p_height)`: confirma a linha pendente e avança a tabela. `p_height` é altura mínima positiva em pontos (20); a linha migra inteira quando não cabe e o cabeçalho é repetido.

### Desenho vetorial e cores

- `set_fill_color(p_r, p_g, p_b)`: seleciona a cor de preenchimento e texto atual; os canais RGB são inteiros de 0 a 255.
- `set_stroke_color(p_r, p_g, p_b)`: seleciona a cor de contorno/traço, com os mesmos requisitos RGB.
- `draw_line(p_x1, p_y1, p_x2, p_y2)`: desenha linha entre dois pontos absolutos dentro da página.
- `draw_rect(p_x, p_y, p_width, p_height)`: desenha e contorna retângulo; coordenadas devem estar dentro da página e dimensões ser positivas.
- `begin_path(p_x, p_y)`: inicia caminho vetorial no ponto absoluto indicado, dentro da página.
- `add_line_to(p_x, p_y)`: adiciona segmento ao caminho aberto, com destino dentro da página.
- `add_curve(p_cx1, p_cy1, p_cx2, p_cy2, p_x, p_y)`: adiciona curva Bézier cúbica; pontos de controle e destino devem estar dentro da página.
- `close_path`: fecha o subcaminho atual.
- `stroke_path`: pinta o caminho aberto com a cor de traço e o encerra.
- `fill_path`: preenche o caminho aberto com a cor de preenchimento e o encerra.

As rotinas de caminho exigem `begin_path` e devem terminar com `stroke_path` ou `fill_path` antes de iniciar outra página, tabela ou imagem.

### Imagens e geração

- `add_image(p_image_blob, p_x, p_y, p_width, p_height, p_scale, p_text_align, p_text_size)`: incorpora `BLOB` JPEG RGB8 ou PNG suportado. Coordenadas e dimensões são pontos; largura/altura `NULL` ou 0 são calculadas pela proporção. `p_scale` é fator positivo alternativo às dimensões (`NULL`); `p_text_align` é `B`, `T` ou `M` (`B`); `p_text_size` define a altura estimada da linha em pontos (10). O retângulo final deve caber na página. PNG aceita grayscale/RGB8 ou paleta indexada e `tRNS` binário; canal alpha explícito e transparência parcial não são suportados.
- `generate RETURN BLOB`: finaliza e retorna o PDF como `BLOB` temporário. O chamador deve persistir ou transmitir o resultado e liberar o temporário com `DBMS_LOB.FREETEMPORARY`.

Esta referência corresponde à specification instalada; os exemplos ilustram chamadas com parâmetros nomeados.
