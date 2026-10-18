-- Exemplo integrado da package PDFPKGEN: relatório editorial de várias páginas.
-- Demonstra metadados, cabeçalho/rodapé, texto, alinhamentos, vetores Bézier,
-- tabela paginada, imagens opcionais e fonte Unicode opcional.
-- Requer repositorio_arquivo e repositorio_arquivo_seq.
-- Recursos opcionais: filename = 'DejaVuSans.ttf' e filename = 'demo-logo.png'.
-- O TTF deve ser licenciado e conter os glifos usados no texto Unicode.

DECLARE
    l_pdf             BLOB;
    l_unicode_font    BLOB;
    l_logo            BLOB;
    l_id              NUMBER;
    l_filename        VARCHAR2(128);
    l_length          NUMBER;
    l_unicode_loaded  BOOLEAN := FALSE;
    l_even_row        BOOLEAN;
    l_jpg             BLOB;

    c_navy       CONSTANT PLS_INTEGER := 24;
    c_navy_g     CONSTANT PLS_INTEGER := 48;
    c_navy_b     CONSTANT PLS_INTEGER := 74;
    c_teal       CONSTANT PLS_INTEGER := 32;
    c_teal_g     CONSTANT PLS_INTEGER := 135;
    c_teal_b     CONSTANT PLS_INTEGER := 142;
    c_ink        CONSTANT PLS_INTEGER := 39;
    c_ink_g      CONSTANT PLS_INTEGER := 52;
    c_ink_b      CONSTANT PLS_INTEGER := 66;
    c_muted      CONSTANT PLS_INTEGER := 103;
    c_muted_g    CONSTANT PLS_INTEGER := 119;
    c_muted_b    CONSTANT PLS_INTEGER := 132;
    c_line       CONSTANT PLS_INTEGER := 218;

    PROCEDURE fill_rect(
        p_x NUMBER,
        p_y NUMBER,
        p_width NUMBER,
        p_height NUMBER,
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    ) IS
    BEGIN
        pdfpkgen.set_fill_color(p_r, p_g, p_b);
        pdfpkgen.begin_path(p_x, p_y);
        pdfpkgen.add_line_to(p_x + p_width, p_y);
        pdfpkgen.add_line_to(p_x + p_width, p_y + p_height);
        pdfpkgen.add_line_to(p_x, p_y + p_height);
        pdfpkgen.close_path;
        pdfpkgen.fill_path;
    END;

    PROCEDURE draw_cover_art IS
    BEGIN
        -- Abstração geométrica: cartões e uma curva de dados no painel de capa.
        pdfpkgen.set_stroke_color(75, 183, 184);
        pdfpkgen.begin_path(350, 708);
        pdfpkgen.add_curve(375, 735, 389, 685, 414, 706);
        pdfpkgen.add_curve(438, 726, 453, 752, 478, 730);
        pdfpkgen.add_curve(500, 710, 515, 742, 537, 750);
        pdfpkgen.stroke_path;

        pdfpkgen.set_fill_color(120, 220, 206);
        pdfpkgen.begin_path(345, 704);
        pdfpkgen.add_line_to(352, 704);
        pdfpkgen.add_line_to(352, 711);
        pdfpkgen.add_line_to(345, 711);
        pdfpkgen.close_path;
        pdfpkgen.fill_path;

        pdfpkgen.begin_path(410, 702);
        pdfpkgen.add_line_to(417, 702);
        pdfpkgen.add_line_to(417, 709);
        pdfpkgen.add_line_to(410, 709);
        pdfpkgen.close_path;
        pdfpkgen.fill_path;

        pdfpkgen.begin_path(474, 726);
        pdfpkgen.add_line_to(481, 726);
        pdfpkgen.add_line_to(481, 733);
        pdfpkgen.add_line_to(474, 733);
        pdfpkgen.close_path;
        pdfpkgen.fill_path;

        pdfpkgen.begin_path(534, 746);
        pdfpkgen.add_line_to(541, 746);
        pdfpkgen.add_line_to(541, 753);
        pdfpkgen.add_line_to(534, 753);
        pdfpkgen.close_path;
        pdfpkgen.fill_path;
    END;

    PROCEDURE add_demo_row(p_row PLS_INTEGER) IS
        l_product VARCHAR2(120);
        l_category VARCHAR2(40);
        l_quantity VARCHAR2(12);
        l_price VARCHAR2(24);
        l_total VARCHAR2(24);
    BEGIN
        CASE MOD(p_row, 6)
            WHEN 1 THEN
                l_product := 'Caderno executivo';
                l_category := 'Papelaria';
                l_quantity := '12';
                l_price := 'R$ 18,50';
                l_total := 'R$ 222,00';
            WHEN 2 THEN
                l_product := 'Caneta esferográfica';
                l_category := 'Papelaria';
                l_quantity := '30';
                l_price := 'R$ 4,20';
                l_total := 'R$ 126,00';
            WHEN 3 THEN
                l_product := 'Mochila urbana';
                l_category := 'Acessórios';
                l_quantity := '5';
                l_price := 'R$ 189,90';
                l_total := 'R$ 949,50';
            WHEN 4 THEN
                l_product := 'Garrafa térmica';
                l_category := 'Acessórios';
                l_quantity := '8';
                l_price := 'R$ 74,50';
                l_total := 'R$ 596,00';
            WHEN 5 THEN
                l_product := 'Luminária articulada para mesa';
                l_category := 'Escritório';
                l_quantity := '4';
                l_price := 'R$ 129,00';
                l_total := 'R$ 516,00';
            ELSE
                l_product := 'Suporte para notebook';
                l_category := 'Escritório';
                l_quantity := '6';
                l_price := 'R$ 98,90';
                l_total := 'R$ 593,40';
        END CASE;

        l_even_row := MOD(p_row, 2) = 0;
        pdfpkgen.add_cell(
            l_product, 205, 25, 'L',
            p_border => TRUE,
            p_border_r => c_line, p_border_g => 228, p_border_b => 234,
            p_fill_r => CASE WHEN l_even_row THEN 243 ELSE 255 END,
            p_fill_g => CASE WHEN l_even_row THEN 248 ELSE 255 END,
            p_fill_b => CASE WHEN l_even_row THEN 250 ELSE 255 END,
            p_padding => 6, p_valign => 'M',
            p_text_r => c_ink, p_text_g => c_ink_g, p_text_b => c_ink_b
        );
        pdfpkgen.add_cell(
            l_category, 115, 25, 'L',
            p_border => TRUE,
            p_border_r => c_line, p_border_g => 228, p_border_b => 234,
            p_fill_r => 255, p_fill_g => 255, p_fill_b => 255,
            p_padding => 6, p_valign => 'M',
            p_text_r => c_ink, p_text_g => c_ink_g, p_text_b => c_ink_b
        );
        pdfpkgen.add_cell(
            l_quantity, 55, 25, 'C',
            p_border => TRUE,
            p_border_r => c_line, p_border_g => 228, p_border_b => 234,
            p_fill_r => 232, p_fill_g => 245, p_fill_b => 246,
            p_padding => 4, p_valign => 'M',
            p_text_r => c_ink, p_text_g => c_ink_g, p_text_b => c_ink_b
        );
        pdfpkgen.add_cell(
            l_price, 75, 25, 'R',
            p_border => TRUE,
            p_border_r => c_line, p_border_g => 228, p_border_b => 234,
            p_fill_r => 255, p_fill_g => 255, p_fill_b => 255,
            p_padding => 6, p_valign => 'M',
            p_text_r => c_ink, p_text_g => c_ink_g, p_text_b => c_ink_b
        );
        pdfpkgen.add_cell(
            l_total, 85, 25, 'R',
            p_border => TRUE,
            p_border_r => c_line, p_border_g => 228, p_border_b => 234,
            p_fill_r => CASE WHEN l_even_row THEN 232 ELSE 242 END,
            p_fill_g => CASE WHEN l_even_row THEN 245 ELSE 248 END,
            p_fill_b => CASE WHEN l_even_row THEN 246 ELSE 250 END,
            p_padding => 6, p_valign => 'M',
            p_text_r => c_navy, p_text_g => c_navy_g, p_text_b => c_navy_b,
            p_bold => TRUE
        );
        pdfpkgen.next_row(25);
    END;
BEGIN
    BEGIN
        SELECT blob_content
        INTO l_jpg
        FROM repositorio_arquivo
        WHERE filename = 'infograficos.jpeg';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(
                -20090,
                'Imagem infograficos.jpeg não encontrada em repositorio_arquivo.'
            );
    END;

    -- Recursos opcionais: o relatório funciona sem fonte extra ou imagem.
    BEGIN
        SELECT blob_content
        INTO l_unicode_font
        FROM repositorio_arquivo
        WHERE filename = 'DejaVuSans.ttf';

        IF l_unicode_font IS NOT NULL AND DBMS_LOB.GETLENGTH(l_unicode_font) > 0 THEN
            pdfpkgen.set_unicode_font(l_unicode_font, 'DejaVuSans');
            l_unicode_loaded := TRUE;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            l_unicode_font := NULL;
    END;

    BEGIN
        SELECT blob_content
        INTO l_logo
        FROM repositorio_arquivo
        WHERE filename = 'demo-logo.png';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            l_logo := NULL;
    END;

    pdfpkgen.set_page_size('A4', 'P');
    pdfpkgen.set_margins_cm(
        p_top_cm => 1.8,
        p_left_cm => 1.5,
        p_right_cm => 1.5,
        p_bottom_cm => 1.7
    );
    pdfpkgen.set_metadata(
        p_title => 'Panorama de desempenho | Relatório integrado',
        p_author => 'Daniel Madeira',
        p_subject => 'Demonstração editorial dos recursos PDFPKGEN',
        p_keywords => 'relatório, indicadores, vendas, PDFPKGEN'
    );
    pdfpkgen.set_page_header('NÚCLEO DE INTELIGÊNCIA  /  RELATÓRIOS', 8, TRUE, 'L');
    pdfpkgen.set_page_footer(
        'CONFIDENCIAL  •  DEMONSTRAÇÃO                                      PÁGINA {PAGE}',
        8,
        FALSE,
        'L'
    );
    pdfpkgen.new_document;

    -- Capa com contraste alto, gráfico vetorial, cartões de indicadores e imagem opcional.
    fill_rect(40, 680, 515, 112, c_navy, c_navy_g, c_navy_b);
    pdfpkgen.set_fill_color(255, 255, 255);
    pdfpkgen.write_text(58, 757, 'PANORAMA', 26, TRUE);
    pdfpkgen.write_text(58, 731, 'DE DESEMPENHO', 20, TRUE);
    pdfpkgen.set_fill_color(161, 221, 222);
    pdfpkgen.write_text(59, 705, 'RELATÓRIO EXECUTIVO  /  OUTUBRO 2026', 8, TRUE);
    draw_cover_art;

    IF l_logo IS NOT NULL THEN
        pdfpkgen.add_image(
            p_image_blob => l_logo,
            p_x => 505,
            p_y => 748,
            p_width => 34,
            p_height => 34
        );
    END IF;

    -- Indicadores em cartões com paleta consistente.
    fill_rect(40, 610, 163, 52, 236, 246, 247);
    fill_rect(216, 610, 163, 52, 236, 246, 247);
    fill_rect(392, 610, 163, 52, 236, 246, 247);
    pdfpkgen.set_fill_color(c_teal, c_teal_g, c_teal_b);
    pdfpkgen.write_text(53, 642, 'RECEITA DO PERÍODO', 8, TRUE);
    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_text(53, 620, 'R$ 428,6 mil', 16, TRUE);
    pdfpkgen.set_fill_color(c_teal, c_teal_g, c_teal_b);
    pdfpkgen.write_text(229, 642, 'CRESCIMENTO', 8, TRUE);
    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_text(229, 620, '+12,8%', 16, TRUE);
    pdfpkgen.set_fill_color(c_teal, c_teal_g, c_teal_b);
    pdfpkgen.write_text(405, 642, 'PEDIDOS ATENDIDOS', 8, TRUE);
    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_text(405, 620, '1.284', 16, TRUE);

    pdfpkgen.set_fill_color(c_ink, c_ink_g, c_ink_b);
    pdfpkgen.write_paragraph(
        p_x => 40,
        p_y => 586,
        p_width => 515,
        p_text => 'Uma visão clara do período: receita em expansão, operação estável ' ||
                  'e oportunidades para aprofundar o relacionamento com clientes. ' ||
                  'Este documento reúne indicadores, interpretação e detalhe de produtos ' ||
                  'em um formato pronto para apresentação e arquivo.' ||
                  CASE WHEN l_unicode_loaded THEN CHR(10) ||
                       'Amostra Unicode: Ελληνικά — Русский.' ELSE '' END,
        p_size => 10,
        p_paragraph_spacing => 4,
        p_align => 'J'
    );

    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_text(40, pdfpkgen.current_y - 8, 'DESTAQUES DO PERÍODO', 11, TRUE);
    pdfpkgen.set_stroke_color(c_teal, c_teal_g, c_teal_b);
    pdfpkgen.draw_line(40, pdfpkgen.current_y - 15, 555, pdfpkgen.current_y - 15);
    pdfpkgen.set_fill_color(c_muted, c_muted_g, c_muted_b);
    pdfpkgen.write_paragraph(
        p_x => 40,
        p_y => pdfpkgen.current_y - 32,
        p_width => 515,
        p_text => 'O avanço foi impulsionado por maior recorrência e pela boa performance ' ||
                  'das categorias de escritório e acessórios. A curva ilustrativa abaixo ' ||
                  'é desenhada com segmentos Bézier; a tabela detalhada continua nas ' ||
                  'páginas seguintes com cabeçalho repetido automaticamente.',
        p_size => 9,
        p_paragraph_spacing => 0,
        p_align => 'L'
    );

    -- Micrográfico vetorial de tendência no fluxo, posicionado após o texto.
    pdfpkgen.set_stroke_color(c_teal, c_teal_g, c_teal_b);
    pdfpkgen.begin_path(48, pdfpkgen.current_y - 13);
    pdfpkgen.add_line_to(165, pdfpkgen.current_y - 13);
    pdfpkgen.add_curve(230, pdfpkgen.current_y + 4, 280, pdfpkgen.current_y + 27, 340, pdfpkgen.current_y + 17);
    pdfpkgen.add_curve(405, pdfpkgen.current_y + 7, 465, pdfpkgen.current_y + 34, 545, pdfpkgen.current_y + 28);
    pdfpkgen.stroke_path;

    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_text(40, pdfpkgen.current_y - 8, 'DETALHE POR PRODUTO', 11, TRUE);
    -- O cabeçalho da tabela tem 20 pt de altura; reservar espaço abaixo do título.
    pdfpkgen.begin_table(40, pdfpkgen.current_y - 40);
    pdfpkgen.set_table_header_style(
        p_fill_r => c_navy, p_fill_g => c_navy_g, p_fill_b => c_navy_b,
        p_border_r => 20, p_border_g => 66, p_border_b => 91,
        p_text_r => 255, p_text_g => 255, p_text_b => 255,
        p_bold => TRUE, p_padding => 5, p_valign => 'M'
    );
    pdfpkgen.add_header('Produto', 205, 'L');
    pdfpkgen.add_header('Categoria', 115, 'L');
    pdfpkgen.add_header('Qtd.', 55, 'C');
    pdfpkgen.add_header('Preço', 75, 'R');
    pdfpkgen.add_header('Total', 85, 'R');
    pdfpkgen.next_row(25);

    -- A tabela excede a área restante da primeira página: as linhas seguintes
    -- continuam automaticamente, repetindo o cabeçalho e atualizando {PAGE}.
    FOR i IN 1 .. 20 LOOP
        add_demo_row(i);
    END LOOP;

    -- O fechamento continua no fluxo após a tabela, sem criar uma página extra.
    pdfpkgen.set_fill_color(c_navy, c_navy_g, c_navy_b);
    pdfpkgen.write_line('LEITURA FINAL', 12, TRUE);
    pdfpkgen.set_fill_color(c_ink, c_ink_g, c_ink_b);
    pdfpkgen.write_paragraph(
        p_x => 40,
        p_y => pdfpkgen.current_y,
        p_width => 390,
        p_text => 'Os dados apresentados são ilustrativos e servem para demonstrar a composição ' ||
                  'de um relatório completo: capa, elementos vetoriais, cartões, tabela com ' ||
                  'estilos por célula, texto corrido, metadados e recursos opcionais.',
        p_size => 9,
        p_paragraph_spacing => 0,
        p_align => 'J'
    );

    -- A4: X/Y consideram as margens laterais (1,5 cm) e inferior (1,7 cm).
    -- Largura explícita e altura omitida preservam a proporção do PNG.
    pdfpkgen.add_image(
        p_image_blob => l_jpg,
        p_x          => 467,
        p_y          => 48,
        p_width      => 85
    );
    
    l_pdf := pdfpkgen.generate;
    l_id := repositorio_arquivo_seq.NEXTVAL;
    l_filename := 'relatorio.pdf';
    INSERT INTO repositorio_arquivo (
        id, blob_content, mime_type, filename, charset, last_updated
    ) VALUES (
        l_id, l_pdf, 'application/pdf', l_filename, NULL, CURRENT_TIMESTAMP
    );
    COMMIT;

    l_length := DBMS_LOB.GETLENGTH(l_pdf);
    IF DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pdf);
    END IF;
    IF l_unicode_loaded THEN
        pdfpkgen.clear_unicode_font;
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        'Relatório gerado: ' || l_filename || ' (' || l_length || ' bytes).'
    );
EXCEPTION
    WHEN OTHERS THEN
        IF l_pdf IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_pdf);
        END IF;
        RAISE;
END;
/
