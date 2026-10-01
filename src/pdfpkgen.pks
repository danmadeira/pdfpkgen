CREATE OR REPLACE PACKAGE pdfpkgen IS
/*******************************************************************************
   NOME DA PACKAGE: PDFpkgen
   AUTOR:           Daniel Madeira
   DATA CRIAÇÃO:    01/10/2026
   VERSÃO:          1.1

   DESCRIÇÃO:
   Package Oracle PL/SQL para gerar documentos PDF 1.4 diretamente no banco, em
   memória, retornando o arquivo como `BLOB` temporário. A implementação monta
   os objetos PDF, os fluxos de páginas, recursos, referências cruzadas (`xref`)
   e trailer sem depender de um serviço externo de geração.

   LICENÇA:
   Copyright (C) 2026 Daniel Madeira

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://gnu.org>.
*******************************************************************************/

    PROCEDURE new_document;

    PROCEDURE add_page;

    -- Define os campos do dicionário Info do PDF; NULL remove cada campo.
    PROCEDURE set_metadata(
        p_title    VARCHAR2 DEFAULT NULL,
        p_author   VARCHAR2 DEFAULT NULL,
        p_subject  VARCHAR2 DEFAULT NULL,
        p_keywords VARCHAR2 DEFAULT NULL
    );

    -- Configure antes de new_document; use {PAGE} para inserir o número da página.
    PROCEDURE set_page_header(
        p_text  VARCHAR2,
        p_size  NUMBER DEFAULT 9,
        p_bold  BOOLEAN DEFAULT FALSE,
        p_align VARCHAR2 DEFAULT 'C',
        p_y     NUMBER DEFAULT NULL
    );

    PROCEDURE set_page_footer(
        p_text  VARCHAR2,
        p_size  NUMBER DEFAULT 9,
        p_bold  BOOLEAN DEFAULT FALSE,
        p_align VARCHAR2 DEFAULT 'C',
        p_y     NUMBER DEFAULT NULL
    );

    -- Carrega uma fonte TrueType (.ttf) licenciada pelo chamador, antes de new_document.
    -- O modo Unicode incorporado suporta caracteres BMP (U+0000..U+FFFF).
    PROCEDURE set_unicode_font(
        p_font_blob IN BLOB,
        p_font_name VARCHAR2 DEFAULT 'PDFGenUnicode'
    );

    PROCEDURE clear_unicode_font;

    -- Configure antes de new_document; formatos: A4, LETTER ou LEGAL; orientação P/L.
    PROCEDURE set_page_size(
        p_format      VARCHAR2,
        p_orientation VARCHAR2 DEFAULT 'P'
    );

    -- Dimensões personalizadas em pontos PDF (72 pontos por polegada).
    PROCEDURE set_page_size(
        p_width_pts  NUMBER,
        p_height_pts NUMBER
    );

    -- Rotinas de fluxo (write_line, write_paragraph e tabelas) paginam automaticamente.
    -- Rotinas com coordenadas explícitas permanecem posicionadas na página atual.

    -- Configura margens em centímetros; chame antes de new_document.
    PROCEDURE set_margins_cm(
        p_top_cm    NUMBER,
        p_left_cm   NUMBER,
        p_right_cm  NUMBER,
        p_bottom_cm NUMBER
    );

    PROCEDURE add_header(
        p_text  VARCHAR2,
        p_width NUMBER,
        p_align VARCHAR2 DEFAULT 'L'
    );

    PROCEDURE set_table_header_style(
        p_fill_r  NUMBER DEFAULT NULL,
        p_fill_g  NUMBER DEFAULT NULL,
        p_fill_b  NUMBER DEFAULT NULL,
        p_border_r NUMBER DEFAULT NULL,
        p_border_g NUMBER DEFAULT NULL,
        p_border_b NUMBER DEFAULT NULL,
        p_text_r  NUMBER DEFAULT NULL,
        p_text_g  NUMBER DEFAULT NULL,
        p_text_b  NUMBER DEFAULT NULL,
        p_bold    BOOLEAN DEFAULT FALSE,
        p_border  BOOLEAN DEFAULT TRUE,
        p_padding NUMBER DEFAULT 2,
        p_valign  VARCHAR2 DEFAULT 'M'
    );

    -- Sem fonte Unicode configurada, texto deve ser representável em Windows-1252/WinAnsi.
    PROCEDURE write_text(
        p_x         NUMBER,
        p_y         NUMBER,
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_bold      BOOLEAN DEFAULT FALSE,
        p_italic    BOOLEAN DEFAULT FALSE,
        p_align     VARCHAR2 DEFAULT 'L'
    );

    FUNCTION measure_text_width(
        p_text  VARCHAR2,
        p_size  NUMBER DEFAULT 10,
        p_bold  BOOLEAN DEFAULT FALSE
    ) RETURN NUMBER;

    -- Altura estimada do texto quebrado; não inclui espaço após o parágrafo.
    FUNCTION measure_paragraph_height(
        p_text        VARCHAR2,
        p_width       NUMBER,
        p_size        NUMBER DEFAULT 10,
        p_line_spacing NUMBER DEFAULT 4,
        p_bold        BOOLEAN DEFAULT FALSE
    ) RETURN NUMBER;

    -- Alinhamento: L (esquerda), C (centro), R (direita) ou J (justificado).
    -- Espaçamento entre parágrafos em pontos PDF, padrão 0; CR/LF explícitos são preservados.
    PROCEDURE write_paragraph(
        p_x         NUMBER,
        p_y         NUMBER,
        p_width     NUMBER,
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_paragraph_spacing NUMBER DEFAULT 0,
        p_align     VARCHAR2 DEFAULT 'L'
    );

    PROCEDURE write_line(
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_bold      BOOLEAN DEFAULT FALSE,
        p_italic    BOOLEAN DEFAULT FALSE
    );

    PROCEDURE draw_line(
        p_x1 NUMBER,
        p_y1 NUMBER,
        p_x2 NUMBER,
        p_y2 NUMBER
    );

    PROCEDURE draw_rect(
        p_x      NUMBER,
        p_y      NUMBER,
        p_width  NUMBER,
        p_height NUMBER
    );

    PROCEDURE begin_table(
        p_x NUMBER,
        p_y NUMBER
    );

    PROCEDURE add_cell(
        p_text      VARCHAR2,
        p_width     NUMBER,
        p_height    NUMBER DEFAULT 20,
        p_align     VARCHAR2 DEFAULT 'L',
        p_border    BOOLEAN DEFAULT TRUE,
        p_border_r  NUMBER DEFAULT NULL,
        p_border_g  NUMBER DEFAULT NULL,
        p_border_b  NUMBER DEFAULT NULL,
        p_fill_r    NUMBER DEFAULT NULL,
        p_fill_g    NUMBER DEFAULT NULL,
        p_fill_b    NUMBER DEFAULT NULL,
        p_padding   NUMBER DEFAULT 2,
        p_valign    VARCHAR2 DEFAULT 'M',
        p_text_r    NUMBER DEFAULT NULL,
        p_text_g    NUMBER DEFAULT NULL,
        p_text_b    NUMBER DEFAULT NULL,
        p_bold      BOOLEAN DEFAULT FALSE
    );

    PROCEDURE next_row(
        p_height NUMBER DEFAULT 20
    );

    FUNCTION current_y
    RETURN NUMBER;

    PROCEDURE begin_path(
        p_x NUMBER,
        p_y NUMBER
    );

    PROCEDURE add_curve(
        p_cx1 NUMBER, p_cy1 NUMBER,
        p_cx2 NUMBER, p_cy2 NUMBER,
        p_x   NUMBER, p_y   NUMBER
    );

    PROCEDURE add_line_to(
        p_x NUMBER,
        p_y NUMBER
    );

    PROCEDURE close_path;
    PROCEDURE stroke_path;
    PROCEDURE fill_path;

    -- Componentes RGB de 0 a 255.
    PROCEDURE set_fill_color(
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    );

    PROCEDURE set_stroke_color(
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    );

    -- JPEG RGB8 ou PNG RGB/grayscale/indexado; tRNS binário quando representável.
    -- Dimensão NULL/0 é inferida preservando a proporção.
    -- p_scale é alternativo às dimensões; p_text_align alinha pela linha de base (B), topo (T) ou meio (M).
    PROCEDURE add_image(
        p_image_blob IN BLOB,
        p_x          NUMBER,
        p_y          NUMBER,
        p_width      NUMBER DEFAULT 0,
        p_height     NUMBER DEFAULT 0,
        p_scale      NUMBER DEFAULT NULL,
        p_text_align VARCHAR2 DEFAULT 'B',
        p_text_size  NUMBER DEFAULT 10
    );

    FUNCTION generate RETURN BLOB;

END pdfpkgen;
/
