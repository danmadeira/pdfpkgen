CREATE OR REPLACE PACKAGE BODY pdfpkgen IS
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
 
    ----------------------------------------------------------------------------
    -- tipos
    ----------------------------------------------------------------------------

    TYPE t_clob_tab IS TABLE OF CLOB
    INDEX BY PLS_INTEGER;

    TYPE t_offsets IS TABLE OF NUMBER
    INDEX BY PLS_INTEGER;

    TYPE t_unicode_map IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    TYPE t_header_text IS TABLE OF VARCHAR2(4000)
    INDEX BY PLS_INTEGER;

    TYPE t_header_width IS TABLE OF NUMBER
    INDEX BY PLS_INTEGER;

    TYPE t_header_align IS TABLE OF VARCHAR2(1)
    INDEX BY PLS_INTEGER;

    TYPE t_cell_rec IS RECORD (
        text VARCHAR2(32767),
        width NUMBER,
        height NUMBER,
        align VARCHAR2(1),
        border BOOLEAN,
        border_r NUMBER,
        border_g NUMBER,
        border_b NUMBER,
        fill_r NUMBER,
        fill_g NUMBER,
        fill_b NUMBER,
        text_r NUMBER,
        text_g NUMBER,
        text_b NUMBER,
        padding NUMBER,
        valign VARCHAR2(1),
        bold BOOLEAN
    );
    TYPE t_cell_tab IS TABLE OF t_cell_rec INDEX BY PLS_INTEGER;

    TYPE t_text_lines IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;

    TYPE t_image_rec IS RECORD (
        blob_data BLOB,
        filter_name VARCHAR2(20),
        color_components NUMBER,
        bits_per_component NUMBER,
        page_no NUMBER,
        x NUMBER,
        y NUMBER,
        width NUMBER,
        height NUMBER,
        pixel_width NUMBER,
        pixel_height NUMBER,
        palette_hex VARCHAR2(1536),
        palette_entries NUMBER,
        mask_values VARCHAR2(1000)
    );
    TYPE t_image_tab IS TABLE OF t_image_rec INDEX BY PLS_INTEGER;

    g_images t_image_tab;
    g_image_count NUMBER := 0;
    g_header_align t_header_align;
    g_header_text t_header_text;
    g_header_width t_header_width;
    g_header_count NUMBER := 0;
    g_header_fill_r NUMBER;
    g_header_fill_g NUMBER;
    g_header_fill_b NUMBER;
    g_header_border_r NUMBER;
    g_header_border_g NUMBER;
    g_header_border_b NUMBER;
    g_header_text_r NUMBER;
    g_header_text_g NUMBER;
    g_header_text_b NUMBER;
    g_header_bold BOOLEAN := FALSE;
    g_header_border BOOLEAN := TRUE;
    g_header_padding NUMBER := 2;
    g_header_valign VARCHAR2(1) := 'M';
    g_header_height NUMBER := 20;
    g_pending_cells t_cell_tab;
    g_pending_cell_count PLS_INTEGER := 0;
    g_header_row_waiting BOOLEAN := FALSE;
    g_offsets t_offsets;
    g_obj_count NUMBER := 0;
    g_pages t_clob_tab;
    g_page_count NUMBER := 0;
    g_current_page NUMBER := 0;

    g_table_start_x NUMBER;
    g_table_x NUMBER;
    g_table_y NUMBER;
    g_table_row_height NUMBER := 20;
    g_table_last_advance_height NUMBER := 0;

    g_page_width NUMBER := 595;
    g_page_height NUMBER := 842;
    g_document_page_width NUMBER := 595;
    g_document_page_height NUMBER := 842;
    g_document_active BOOLEAN := FALSE;
    g_path_open BOOLEAN := FALSE;
    g_points_per_cm CONSTANT NUMBER := 72 / 2.54;
    g_margin_left NUMBER := 40;
    g_margin_right NUMBER := 40;
    g_margin_top NUMBER := 40;
    g_margin_bottom NUMBER := 40;

    g_cursor_y NUMBER;
    g_page_header_text VARCHAR2(4000);
    g_page_header_size NUMBER := 9;
    g_page_header_bold BOOLEAN := FALSE;
    g_page_header_align VARCHAR2(1) := 'C';
    g_page_header_y NUMBER;
    g_page_footer_text VARCHAR2(4000);
    g_page_footer_size NUMBER := 9;
    g_page_footer_bold BOOLEAN := FALSE;
    g_page_footer_align VARCHAR2(1) := 'C';
    g_page_footer_y NUMBER;
    g_metadata_title VARCHAR2(4000);
    g_metadata_author VARCHAR2(4000);
    g_metadata_subject VARCHAR2(4000);
    g_metadata_keywords VARCHAR2(4000);
    g_unicode_font_blob BLOB;
    g_unicode_font_name VARCHAR2(100);
    g_unicode_font_length NUMBER;
    g_unicode_head_offset NUMBER;
    g_unicode_hhea_offset NUMBER;
    g_unicode_hmtx_offset NUMBER;
    g_unicode_maxp_offset NUMBER;
    g_unicode_cmap_offset NUMBER;
    g_unicode_cmap_format NUMBER;
    g_unicode_cmap4_offset NUMBER;
    g_unicode_units_per_em NUMBER;
    g_unicode_ascent NUMBER;
    g_unicode_descent NUMBER;
    g_unicode_x_min NUMBER;
    g_unicode_y_min NUMBER;
    g_unicode_x_max NUMBER;
    g_unicode_y_max NUMBER;
    g_unicode_num_hmetrics NUMBER;
    g_unicode_num_glyphs NUMBER;
    g_unicode_used_glyphs t_unicode_map;
    g_unicode_used_widths t_unicode_map;

        FUNCTION font_byte(p_offset NUMBER) RETURN PLS_INTEGER IS
            l_raw RAW(1);
        BEGIN
            l_raw := DBMS_LOB.SUBSTR(g_unicode_font_blob, 1, p_offset);
            IF l_raw IS NULL OR UTL_RAW.LENGTH(l_raw) <> 1 THEN
                RAISE_APPLICATION_ERROR(-20062, 'Arquivo TrueType truncado ou inválido.');
            END IF;
            RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(
                HEXTORAW('000000' || RAWTOHEX(l_raw)), UTL_RAW.BIG_ENDIAN
            );
        END;

        FUNCTION font_u16(p_offset NUMBER) RETURN PLS_INTEGER IS
        BEGIN
            RETURN font_byte(p_offset) * 256 + font_byte(p_offset + 1);
        END;

        FUNCTION font_s16(p_offset NUMBER) RETURN PLS_INTEGER IS
            l_value PLS_INTEGER := font_u16(p_offset);
        BEGIN
            IF l_value >= 32768 THEN
                RETURN l_value - 65536;
            END IF;
            RETURN l_value;
        END;

        FUNCTION font_u32(p_offset NUMBER) RETURN NUMBER IS
        BEGIN
            RETURN font_byte(p_offset) * 16777216
                 + font_byte(p_offset + 1) * 65536
                 + font_byte(p_offset + 2) * 256
                 + font_byte(p_offset + 3);
        END;

        FUNCTION ttf_glyph(p_codepoint PLS_INTEGER) RETURN PLS_INTEGER IS
            l_seg_count PLS_INTEGER;
            l_end_pos NUMBER;
            l_start_pos NUMBER;
            l_delta_pos NUMBER;
            l_range_pos NUMBER;
            l_start_code PLS_INTEGER;
            l_end_code PLS_INTEGER;
            l_delta PLS_INTEGER;
            l_range_offset PLS_INTEGER;
            l_glyph PLS_INTEGER;
            l_glyph_pos NUMBER;
            l_cmap_end NUMBER;
        BEGIN
            IF p_codepoint < 0 OR p_codepoint > 65535 THEN
                RAISE_APPLICATION_ERROR(-20063, 'Fontes Unicode incorporadas suportam somente caracteres BMP (U+0000..U+FFFF).');
            END IF;
            IF g_unicode_cmap_format <> 4 THEN
                RAISE_APPLICATION_ERROR(-20064, 'A fonte TrueType não possui cmap Unicode BMP no formato 4.');
            END IF;

            l_seg_count := TRUNC(font_u16(g_unicode_cmap4_offset + 6) / 2);
            IF l_seg_count < 1 OR MOD(font_u16(g_unicode_cmap4_offset + 6), 2) <> 0 THEN
                RAISE_APPLICATION_ERROR(-20073, 'Estrutura cmap formato 4 inválida.');
            END IF;
            l_cmap_end := g_unicode_cmap4_offset + font_u16(g_unicode_cmap4_offset + 2) - 1;
            l_end_pos := g_unicode_cmap4_offset + 14;
            l_start_pos := g_unicode_cmap4_offset + 16 + 2 * l_seg_count;
            l_delta_pos := g_unicode_cmap4_offset + 16 + 4 * l_seg_count;
            l_range_pos := g_unicode_cmap4_offset + 16 + 6 * l_seg_count;

            FOR i IN 0 .. l_seg_count - 1 LOOP
                l_end_code := font_u16(l_end_pos + 2 * i);
                IF p_codepoint <= l_end_code THEN
                    l_start_code := font_u16(l_start_pos + 2 * i);
                    IF p_codepoint < l_start_code THEN
                        RETURN 0;
                    END IF;

                    l_delta := font_s16(l_delta_pos + 2 * i);
                    l_range_offset := font_u16(l_range_pos + 2 * i);
                    IF l_range_offset = 0 THEN
                        RETURN MOD(p_codepoint + l_delta, 65536);
                    END IF;

                    l_glyph_pos := l_range_pos + 2 * i + l_range_offset + 2 * (p_codepoint - l_start_code);
                    IF l_glyph_pos < g_unicode_cmap4_offset OR l_glyph_pos + 1 > l_cmap_end THEN
                        RAISE_APPLICATION_ERROR(-20073, 'Offset de glifo inválido na tabela cmap.');
                    END IF;
                    l_glyph := font_u16(l_glyph_pos);
                    IF l_glyph = 0 THEN
                        RETURN 0;
                    END IF;
                    RETURN MOD(l_glyph + l_delta, 65536);
                END IF;
            END LOOP;
            RETURN 0;
        END;

        FUNCTION ttf_width(p_glyph PLS_INTEGER) RETURN NUMBER IS
            l_metric_index PLS_INTEGER;
            l_advance NUMBER;
        BEGIN
            IF p_glyph < 0 OR p_glyph >= g_unicode_num_glyphs THEN
                RAISE_APPLICATION_ERROR(-20065, 'Índice de glifo inválido na fonte TrueType.');
            END IF;
            l_metric_index := LEAST(p_glyph, g_unicode_num_hmetrics - 1);
            l_advance := font_u16(g_unicode_hmtx_offset + 4 * l_metric_index);
            RETURN l_advance * 1000 / g_unicode_units_per_em;
        END;

        PROCEDURE next_utf8_codepoint(
            p_raw IN RAW,
            p_position IN OUT PLS_INTEGER,
            p_codepoint OUT PLS_INTEGER
        ) IS
            l_byte1 PLS_INTEGER;
            l_byte2 PLS_INTEGER;
            l_byte3 PLS_INTEGER;
            l_byte4 PLS_INTEGER;
            l_length PLS_INTEGER := UTL_RAW.LENGTH(p_raw);

            PROCEDURE require_continuation(p_byte PLS_INTEGER) IS
            BEGIN
                IF p_byte < 128 OR p_byte > 191 THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 inválida.');
                END IF;
            END;

            FUNCTION raw_byte(p_pos PLS_INTEGER) RETURN PLS_INTEGER IS
                l_byte RAW(1);
            BEGIN
                l_byte := UTL_RAW.SUBSTR(p_raw, p_pos, 1);
                RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(
                    HEXTORAW('000000' || RAWTOHEX(l_byte)), UTL_RAW.BIG_ENDIAN
                );
            END;
        BEGIN
            IF p_position > l_length THEN
                p_codepoint := NULL;
                RETURN;
            END IF;
            l_byte1 := raw_byte(p_position);
            IF l_byte1 < 128 THEN
                p_codepoint := l_byte1;
                p_position := p_position + 1;
            ELSIF l_byte1 BETWEEN 194 AND 223 THEN
                IF p_position + 1 > l_length THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 truncada.');
                END IF;
                l_byte2 := raw_byte(p_position + 1);
                require_continuation(l_byte2);
                p_codepoint := (l_byte1 - 192) * 64 + l_byte2 - 128;
                p_position := p_position + 2;
            ELSIF l_byte1 BETWEEN 224 AND 239 THEN
                IF p_position + 2 > l_length THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 truncada.');
                END IF;
                l_byte2 := raw_byte(p_position + 1);
                l_byte3 := raw_byte(p_position + 2);
                require_continuation(l_byte3);
                IF (l_byte1 = 224 AND (l_byte2 < 160 OR l_byte2 > 191))
                   OR (l_byte1 = 237 AND (l_byte2 < 128 OR l_byte2 > 159))
                   OR (l_byte1 NOT IN (224, 237) AND (l_byte2 < 128 OR l_byte2 > 191))
                THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 inválida.');
                END IF;
                p_codepoint := (l_byte1 - 224) * 4096 + (l_byte2 - 128) * 64 + l_byte3 - 128;
                p_position := p_position + 3;
            ELSIF l_byte1 BETWEEN 240 AND 244 THEN
                IF p_position + 3 > l_length THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 truncada.');
                END IF;
                l_byte2 := raw_byte(p_position + 1);
                l_byte3 := raw_byte(p_position + 2);
                l_byte4 := raw_byte(p_position + 3);
                require_continuation(l_byte3);
                require_continuation(l_byte4);
                IF (l_byte1 = 240 AND (l_byte2 < 144 OR l_byte2 > 191))
                   OR (l_byte1 = 244 AND (l_byte2 < 128 OR l_byte2 > 143))
                   OR (l_byte1 NOT IN (240, 244) AND (l_byte2 < 128 OR l_byte2 > 191))
                THEN
                    RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 inválida.');
                END IF;
                p_codepoint := (l_byte1 - 240) * 262144 + (l_byte2 - 128) * 4096
                             + (l_byte3 - 128) * 64 + l_byte4 - 128;
                p_position := p_position + 4;
            ELSE
                RAISE_APPLICATION_ERROR(-20066, 'Sequência UTF-8 inválida.');
            END IF;
            IF p_codepoint > 65535 THEN
                RAISE_APPLICATION_ERROR(-20063, 'Fontes Unicode incorporadas suportam somente caracteres BMP (U+0000..U+FFFF).');
            END IF;
            IF p_codepoint BETWEEN 55296 AND 57343 THEN
                RAISE_APPLICATION_ERROR(-20063, 'Surrogates UTF-16 isolados não são suportados pela fonte Unicode.');
            END IF;
        END;

        FUNCTION unicode_pdf_string(p_text VARCHAR2) RETURN VARCHAR2;
        FUNCTION unicode_text_width(p_text VARCHAR2, p_size NUMBER) RETURN NUMBER;
        FUNCTION unicode_hex4(p_value PLS_INTEGER) RETURN VARCHAR2;

    ----------------------------------------------------------------------------
    -- Configuração de página
    ----------------------------------------------------------------------------

    PROCEDURE validate_page_dimensions(
        p_width NUMBER,
        p_height NUMBER
    ) IS
    BEGIN
        IF p_width IS NULL OR p_height IS NULL OR p_width <= 0 OR p_height <= 0 THEN
            RAISE_APPLICATION_ERROR(-20048, 'As dimensões da página devem ser positivas em pontos.');
        END IF;
        IF g_margin_left + g_margin_right >= p_width
           OR g_margin_top + g_margin_bottom >= p_height
        THEN
            RAISE_APPLICATION_ERROR(-20031, 'As margens não deixam área útil na página configurada.');
        END IF;
        IF g_document_active THEN
            RAISE_APPLICATION_ERROR(-20049, 'Configure o tamanho da página antes de new_document.');
        END IF;
    END;

    PROCEDURE set_page_size(
        p_format      VARCHAR2,
        p_orientation VARCHAR2 DEFAULT 'P'
    ) IS
        l_width NUMBER;
        l_height NUMBER;
        l_swap NUMBER;
        l_orientation VARCHAR2(1);
    BEGIN
        IF p_format IS NULL OR UPPER(TRIM(p_format)) NOT IN ('A4', 'LETTER', 'LEGAL') THEN
            RAISE_APPLICATION_ERROR(-20050, 'Formato inválido; use A4, LETTER ou LEGAL.');
        END IF;
        IF p_orientation IS NULL OR UPPER(TRIM(p_orientation)) NOT IN ('P', 'L') THEN
            RAISE_APPLICATION_ERROR(-20051, 'Orientação inválida; use P (retrato) ou L (paisagem).');
        END IF;

        CASE UPPER(TRIM(p_format))
            WHEN 'A4' THEN
                l_width := 595;
                l_height := 842;
            WHEN 'LETTER' THEN
                l_width := 612;
                l_height := 792;
            WHEN 'LEGAL' THEN
                l_width := 612;
                l_height := 1008;
        END CASE;

        l_orientation := UPPER(TRIM(p_orientation));
        IF l_orientation = 'L' THEN
            l_swap := l_width;
            l_width := l_height;
            l_height := l_swap;
        END IF;

        validate_page_dimensions(l_width, l_height);
        g_page_width := l_width;
        g_page_height := l_height;
    END;

    PROCEDURE set_page_size(
        p_width_pts  NUMBER,
        p_height_pts NUMBER
    ) IS
    BEGIN
        validate_page_dimensions(p_width_pts, p_height_pts);
        g_page_width := p_width_pts;
        g_page_height := p_height_pts;
    END;

    PROCEDURE parse_unicode_font IS
        l_signature VARCHAR2(8);
        l_table_count PLS_INTEGER;
        l_record NUMBER;
        l_tag VARCHAR2(4);
        l_table_offset NUMBER;
        l_table_length NUMBER;
        l_head_table_length NUMBER;
        l_hhea_table_length NUMBER;
        l_hmtx_table_length NUMBER;
        l_maxp_table_length NUMBER;
        l_cmap_table_offset NUMBER;
        l_cmap_table_length NUMBER;
        l_encoding_count PLS_INTEGER;
        l_encoding_record NUMBER;
        l_platform PLS_INTEGER;
        l_encoding PLS_INTEGER;
        l_subtable_offset NUMBER;
    BEGIN
        g_unicode_head_offset := NULL;
        g_unicode_hhea_offset := NULL;
        g_unicode_hmtx_offset := NULL;
        g_unicode_maxp_offset := NULL;
        g_unicode_cmap_offset := NULL;
        g_unicode_cmap4_offset := NULL;
        g_unicode_font_length := DBMS_LOB.GETLENGTH(g_unicode_font_blob);
        IF g_unicode_font_length < 12 THEN
            RAISE_APPLICATION_ERROR(-20067, 'Arquivo de fonte TTF incompleto.');
        END IF;
        l_signature := RAWTOHEX(DBMS_LOB.SUBSTR(g_unicode_font_blob, 4, 1));
        IF l_signature NOT IN ('00010000', '74727565') THEN
            RAISE_APPLICATION_ERROR(-20068, 'Forneça uma fonte TrueType TTF; OTF-CFF e WOFF não são suportados.');
        END IF;

        l_table_count := font_u16(5);
        FOR i IN 1 .. l_table_count LOOP
            l_record := 13 + 16 * (i - 1);
            IF l_record + 15 > g_unicode_font_length THEN
                RAISE_APPLICATION_ERROR(-20069, 'Diretório de tabelas TrueType truncado.');
            END IF;
            l_tag := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(g_unicode_font_blob, 4, l_record));
            l_table_offset := font_u32(l_record + 8) + 1;
            l_table_length := font_u32(l_record + 12);
            IF l_table_offset + l_table_length - 1 > g_unicode_font_length THEN
                RAISE_APPLICATION_ERROR(-20069, 'Diretório de tabelas TrueType inválido.');
            END IF;
            CASE l_tag
                WHEN 'head' THEN g_unicode_head_offset := l_table_offset; l_head_table_length := l_table_length;
                WHEN 'hhea' THEN g_unicode_hhea_offset := l_table_offset; l_hhea_table_length := l_table_length;
                WHEN 'hmtx' THEN g_unicode_hmtx_offset := l_table_offset; l_hmtx_table_length := l_table_length;
                WHEN 'maxp' THEN g_unicode_maxp_offset := l_table_offset; l_maxp_table_length := l_table_length;
                WHEN 'cmap' THEN
                    l_cmap_table_offset := l_table_offset;
                    l_cmap_table_length := l_table_length;
                ELSE NULL;
            END CASE;
        END LOOP;

        IF g_unicode_head_offset IS NULL OR g_unicode_hhea_offset IS NULL
           OR g_unicode_hmtx_offset IS NULL OR g_unicode_maxp_offset IS NULL
           OR l_cmap_table_offset IS NULL
        THEN
            RAISE_APPLICATION_ERROR(-20070, 'A fonte precisa conter head, hhea, hmtx, maxp e cmap.');
        END IF;

        IF l_head_table_length < 54 OR l_hhea_table_length < 36 OR l_maxp_table_length < 6
           OR l_cmap_table_length < 4
        THEN
            RAISE_APPLICATION_ERROR(-20070, 'Uma ou mais tabelas TrueType obrigatórias estão truncadas.');
        END IF;
        g_unicode_units_per_em := font_u16(g_unicode_head_offset + 18);
        g_unicode_x_min := font_s16(g_unicode_head_offset + 36);
        g_unicode_y_min := font_s16(g_unicode_head_offset + 38);
        g_unicode_x_max := font_s16(g_unicode_head_offset + 40);
        g_unicode_y_max := font_s16(g_unicode_head_offset + 42);
        g_unicode_ascent := font_s16(g_unicode_hhea_offset + 4);
        g_unicode_descent := font_s16(g_unicode_hhea_offset + 6);
        g_unicode_num_hmetrics := font_u16(g_unicode_hhea_offset + 34);
        g_unicode_num_glyphs := font_u16(g_unicode_maxp_offset + 4);
        IF g_unicode_units_per_em = 0 OR g_unicode_num_hmetrics = 0 OR g_unicode_num_glyphs = 0 THEN
            RAISE_APPLICATION_ERROR(-20071, 'Métricas TrueType inválidas.');
        END IF;

        IF l_cmap_table_offset + l_cmap_table_length - 1 > g_unicode_font_length THEN
            RAISE_APPLICATION_ERROR(-20073, 'Tabela cmap da fonte TrueType truncada.');
        END IF;
        l_encoding_count := font_u16(l_cmap_table_offset + 2);
        IF 4 + 8 * l_encoding_count > l_cmap_table_length THEN
            RAISE_APPLICATION_ERROR(-20073, 'Diretório cmap da fonte TrueType truncado.');
        END IF;
        g_unicode_cmap4_offset := NULL;
        FOR i IN 1 .. l_encoding_count LOOP
            l_encoding_record := l_cmap_table_offset + 4 + 8 * (i - 1);
            l_platform := font_u16(l_encoding_record);
            l_encoding := font_u16(l_encoding_record + 2);
            l_subtable_offset := l_cmap_table_offset + font_u32(l_encoding_record + 4);
            IF l_subtable_offset < l_cmap_table_offset + 4 + 8 * l_encoding_count
               OR l_subtable_offset + 1 > l_cmap_table_offset + l_cmap_table_length - 1
            THEN
                CONTINUE;
            END IF;
            IF font_u16(l_subtable_offset) = 4
               AND (l_platform = 0 OR (l_platform = 3 AND l_encoding = 1))
            THEN
                IF l_subtable_offset + 7 > l_cmap_table_offset + l_cmap_table_length - 1 THEN
                    CONTINUE;
                END IF;
                IF font_u16(l_subtable_offset + 2) < 8
                   OR l_subtable_offset + font_u16(l_subtable_offset + 2) - 1 > l_cmap_table_offset + l_cmap_table_length - 1
                THEN
                    CONTINUE;
                END IF;
                g_unicode_cmap4_offset := l_subtable_offset;
                g_unicode_cmap_format := 4;
                EXIT;
            END IF;
        END LOOP;

        IF g_unicode_cmap4_offset IS NULL THEN
            RAISE_APPLICATION_ERROR(-20072, 'A fonte precisa ter um cmap Unicode BMP no formato 4.');
        END IF;
          IF font_u16(g_unicode_cmap4_offset + 6) = 0
              OR MOD(font_u16(g_unicode_cmap4_offset + 6), 2) <> 0
              OR font_u16(g_unicode_cmap4_offset + 2) < 16 + 8 * TRUNC(font_u16(g_unicode_cmap4_offset + 6) / 2)
              OR g_unicode_cmap4_offset + font_u16(g_unicode_cmap4_offset + 2) - 1 > l_cmap_table_offset + l_cmap_table_length - 1
              OR g_unicode_cmap4_offset + font_u16(g_unicode_cmap4_offset + 2) - 1 > g_unicode_font_length
              OR l_cmap_table_offset + l_cmap_table_length - 1 > g_unicode_font_length
        THEN
            RAISE_APPLICATION_ERROR(-20073, 'Tabela cmap da fonte TrueType truncada.');
        END IF;
        IF g_unicode_num_hmetrics > g_unicode_num_glyphs
           OR l_hmtx_table_length < 4 * g_unicode_num_hmetrics + 2 * (g_unicode_num_glyphs - g_unicode_num_hmetrics)
        THEN
            RAISE_APPLICATION_ERROR(-20071, 'Tabela hmtx da fonte TrueType truncada ou inconsistente.');
        END IF;
        g_unicode_used_glyphs.DELETE;
        g_unicode_used_widths.DELETE;
    END;

    PROCEDURE set_unicode_font(
        p_font_blob IN BLOB,
        p_font_name VARCHAR2 DEFAULT 'PDFGenUnicode'
    ) IS
        l_font_copy BLOB;
    BEGIN
        IF g_document_active THEN
            RAISE_APPLICATION_ERROR(-20074, 'Configure a fonte Unicode antes de new_document.');
        END IF;
        IF p_font_blob IS NULL OR DBMS_LOB.GETLENGTH(p_font_blob) = 0 THEN
            RAISE_APPLICATION_ERROR(-20075, 'O BLOB da fonte TTF está vazio.');
        END IF;
        IF p_font_name IS NULL OR NOT REGEXP_LIKE(p_font_name, '^[A-Za-z0-9_-]{1,80}$') THEN
            RAISE_APPLICATION_ERROR(-20076, 'Nome de fonte inválido; use letras, números, hífen ou sublinhado.');
        END IF;

        DBMS_LOB.CREATETEMPORARY(l_font_copy, TRUE);
        DBMS_LOB.COPY(l_font_copy, p_font_blob, DBMS_LOB.GETLENGTH(p_font_blob), 1, 1);
        IF g_unicode_font_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(g_unicode_font_blob) = 1 THEN
            DBMS_LOB.FREETEMPORARY(g_unicode_font_blob);
        END IF;
        g_unicode_font_blob := l_font_copy;
        l_font_copy := NULL;
        g_unicode_font_name := p_font_name;
        BEGIN
            parse_unicode_font;
        EXCEPTION
            WHEN OTHERS THEN
                IF g_unicode_font_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(g_unicode_font_blob) = 1 THEN
                    DBMS_LOB.FREETEMPORARY(g_unicode_font_blob);
                END IF;
                g_unicode_font_blob := NULL;
                g_unicode_font_name := NULL;
                RAISE;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            IF l_font_copy IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_font_copy) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_font_copy);
            END IF;
            RAISE;
    END;

    PROCEDURE clear_unicode_font IS
    BEGIN
        IF g_document_active THEN
            RAISE_APPLICATION_ERROR(-20074, 'Limpe a fonte Unicode somente fora de um documento ativo.');
        END IF;
        IF g_unicode_font_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(g_unicode_font_blob) = 1 THEN
            DBMS_LOB.FREETEMPORARY(g_unicode_font_blob);
        END IF;
        g_unicode_font_blob := NULL;
        g_unicode_font_name := NULL;
        g_unicode_font_length := NULL;
        g_unicode_used_glyphs.DELETE;
        g_unicode_used_widths.DELETE;
    END;

    FUNCTION get_text_width(
        p_text VARCHAR2,
        p_size NUMBER,
        p_bold BOOLEAN DEFAULT FALSE
    ) RETURN NUMBER
    IS
        l_width  NUMBER := 0;
        l_char   VARCHAR2(4);
        l_char_w NUMBER;
    BEGIN
        IF g_unicode_font_blob IS NOT NULL THEN
            RETURN unicode_text_width(p_text, p_size);
        END IF;
        IF p_text IS NULL THEN
            RETURN 0;
        END IF;

        FOR i IN 1 .. LENGTH(p_text) LOOP
            l_char := SUBSTR(p_text, i, 1);

            IF p_bold THEN
                CASE l_char
                    WHEN ' ' THEN l_char_w := 278;
                    WHEN '!' THEN l_char_w := 333;
                    WHEN '(' THEN l_char_w := 333;
                    WHEN ')' THEN l_char_w := 333;
                    WHEN ',' THEN l_char_w := 278;
                    WHEN '.' THEN l_char_w := 278;
                    WHEN ':' THEN l_char_w := 333;
                    WHEN ';' THEN l_char_w := 333;
                    WHEN '-' THEN l_char_w := 333;
                    WHEN '''' THEN l_char_w := 238;
                    WHEN 'i' THEN l_char_w := 278;
                    WHEN 'j' THEN l_char_w := 278;
                    WHEN 'l' THEN l_char_w := 278;
                    WHEN 'I' THEN l_char_w := 278;
                    WHEN 'f' THEN l_char_w := 333;
                    WHEN 't' THEN l_char_w := 333;
                    WHEN 'r' THEN l_char_w := 389;
                    WHEN 'm' THEN l_char_w := 889;
                    WHEN 'w' THEN l_char_w := 778;
                    WHEN 'W' THEN l_char_w := 944;
                    WHEN 'M' THEN l_char_w := 833;
                    WHEN 'A' THEN l_char_w := 722;
                    WHEN 'B' THEN l_char_w := 667;
                    WHEN 'C' THEN l_char_w := 722;
                    WHEN 'D' THEN l_char_w := 722;
                    WHEN 'E' THEN l_char_w := 667;
                    WHEN 'F' THEN l_char_w := 611;
                    WHEN 'G' THEN l_char_w := 778;
                    WHEN 'H' THEN l_char_w := 722;
                    WHEN 'J' THEN l_char_w := 556;
                    WHEN 'K' THEN l_char_w := 722;
                    WHEN 'L' THEN l_char_w := 611;
                    WHEN 'N' THEN l_char_w := 722;
                    WHEN 'O' THEN l_char_w := 778;
                    WHEN 'P' THEN l_char_w := 667;
                    WHEN 'Q' THEN l_char_w := 778;
                    WHEN 'R' THEN l_char_w := 722;
                    WHEN 'S' THEN l_char_w := 667;
                    WHEN 'T' THEN l_char_w := 611;
                    WHEN 'U' THEN l_char_w := 722;
                    WHEN 'V' THEN l_char_w := 667;
                    WHEN 'X' THEN l_char_w := 667;
                    WHEN 'Y' THEN l_char_w := 667;
                    WHEN 'Z' THEN l_char_w := 611;
                    WHEN 'a' THEN l_char_w := 556;
                    WHEN 'b' THEN l_char_w := 611;
                    WHEN 'c' THEN l_char_w := 556;
                    WHEN 'd' THEN l_char_w := 611;
                    WHEN 'e' THEN l_char_w := 556;
                    WHEN 'g' THEN l_char_w := 611;
                    WHEN 'h' THEN l_char_w := 611;
                    WHEN 'k' THEN l_char_w := 556;
                    WHEN 'n' THEN l_char_w := 611;
                    WHEN 'o' THEN l_char_w := 611;
                    WHEN 'p' THEN l_char_w := 611;
                    WHEN 'q' THEN l_char_w := 611;
                    WHEN 's' THEN l_char_w := 556;
                    WHEN 'u' THEN l_char_w := 611;
                    WHEN 'v' THEN l_char_w := 556;
                    WHEN 'x' THEN l_char_w := 556;
                    WHEN 'y' THEN l_char_w := 556;
                    WHEN 'z' THEN l_char_w := 500;
                    ELSE l_char_w := 556;
                END CASE;
            ELSE
                CASE l_char
                    WHEN ' ' THEN l_char_w := 278;
                    WHEN '!' THEN l_char_w := 278;
                    WHEN '(' THEN l_char_w := 333;
                    WHEN ')' THEN l_char_w := 333;
                    WHEN ',' THEN l_char_w := 278;
                    WHEN '.' THEN l_char_w := 278;
                    WHEN ':' THEN l_char_w := 278;
                    WHEN ';' THEN l_char_w := 278;
                    WHEN '-' THEN l_char_w := 333;
                    WHEN '''' THEN l_char_w := 191;
                    WHEN 'i' THEN l_char_w := 222;
                    WHEN 'j' THEN l_char_w := 222;
                    WHEN 'l' THEN l_char_w := 222;
                    WHEN 'I' THEN l_char_w := 278;
                    WHEN 'f' THEN l_char_w := 278;
                    WHEN 't' THEN l_char_w := 278;
                    WHEN 'r' THEN l_char_w := 333;
                    WHEN 'm' THEN l_char_w := 833;
                    WHEN 'w' THEN l_char_w := 722;
                    WHEN 'W' THEN l_char_w := 944;
                    WHEN 'M' THEN l_char_w := 833;
                    WHEN 'A' THEN l_char_w := 667;
                    WHEN 'B' THEN l_char_w := 667;
                    WHEN 'C' THEN l_char_w := 722;
                    WHEN 'D' THEN l_char_w := 722;
                    WHEN 'E' THEN l_char_w := 667;
                    WHEN 'F' THEN l_char_w := 611;
                    WHEN 'G' THEN l_char_w := 778;
                    WHEN 'H' THEN l_char_w := 722;
                    WHEN 'J' THEN l_char_w := 500;
                    WHEN 'K' THEN l_char_w := 667;
                    WHEN 'L' THEN l_char_w := 556;
                    WHEN 'N' THEN l_char_w := 722;
                    WHEN 'O' THEN l_char_w := 778;
                    WHEN 'P' THEN l_char_w := 667;
                    WHEN 'Q' THEN l_char_w := 778;
                    WHEN 'R' THEN l_char_w := 722;
                    WHEN 'S' THEN l_char_w := 667;
                    WHEN 'T' THEN l_char_w := 611;
                    WHEN 'U' THEN l_char_w := 722;
                    WHEN 'V' THEN l_char_w := 667;
                    WHEN 'X' THEN l_char_w := 667;
                    WHEN 'Y' THEN l_char_w := 667;
                    WHEN 'Z' THEN l_char_w := 611;
                    WHEN 'a' THEN l_char_w := 556;
                    WHEN 'b' THEN l_char_w := 556;
                    WHEN 'c' THEN l_char_w := 500;
                    WHEN 'd' THEN l_char_w := 556;
                    WHEN 'e' THEN l_char_w := 556;
                    WHEN 'g' THEN l_char_w := 556;
                    WHEN 'h' THEN l_char_w := 556;
                    WHEN 'k' THEN l_char_w := 500;
                    WHEN 'n' THEN l_char_w := 556;
                    WHEN 'o' THEN l_char_w := 556;
                    WHEN 'p' THEN l_char_w := 556;
                    WHEN 'q' THEN l_char_w := 556;
                    WHEN 's' THEN l_char_w := 500;
                    WHEN 'u' THEN l_char_w := 556;
                    WHEN 'v' THEN l_char_w := 500;
                    WHEN 'x' THEN l_char_w := 500;
                    WHEN 'y' THEN l_char_w := 500;
                    WHEN 'z' THEN l_char_w := 500;
                    WHEN '1' THEN l_char_w := 556;
                    WHEN '@' THEN l_char_w := 1015;
                    ELSE l_char_w := 556;
                END CASE;
            END IF;

            -- Letras acentuadas WinAnsi usam, para alinhamento, a largura da letra-base.
            IF l_char IN ('á','à','â','ã','ä','å') THEN
                l_char_w := CASE WHEN p_bold THEN 556 ELSE 556 END;
            ELSIF l_char IN ('Á','À','Â','Ã','Ä','Å') THEN
                l_char_w := CASE WHEN p_bold THEN 722 ELSE 667 END;
            ELSIF l_char IN ('é','è','ê','ë') THEN
                l_char_w := 556;
            ELSIF l_char IN ('É','È','Ê','Ë') THEN
                l_char_w := 667;
            ELSIF l_char IN ('í','ì','î','ï') THEN
                l_char_w := CASE WHEN p_bold THEN 278 ELSE 222 END;
            ELSIF l_char IN ('Í','Ì','Î','Ï') THEN
                l_char_w := 278;
            ELSIF l_char IN ('ó','ò','ô','õ','ö','ø') THEN
                l_char_w := CASE WHEN p_bold THEN 611 ELSE 556 END;
            ELSIF l_char IN ('Ó','Ò','Ô','Õ','Ö','Ø') THEN
                l_char_w := 778;
            ELSIF l_char IN ('ú','ù','û','ü') THEN
                l_char_w := CASE WHEN p_bold THEN 611 ELSE 556 END;
            ELSIF l_char IN ('Ú','Ù','Û','Ü') THEN
                l_char_w := 722;
            ELSIF l_char = 'ç' THEN
                l_char_w := CASE WHEN p_bold THEN 556 ELSE 500 END;
            ELSIF l_char = 'Ç' THEN
                l_char_w := 722;
            ELSIF l_char = 'ñ' THEN
                l_char_w := CASE WHEN p_bold THEN 611 ELSE 556 END;
            ELSIF l_char = 'Ñ' THEN
                l_char_w := 722;
            END IF;

            l_width := l_width + l_char_w;
        END LOOP;

        RETURN (l_width * p_size) / 1000;
    END;
    ----------------------------------------------------------------------------
    -- utilitarios
    ----------------------------------------------------------------------------

    PROCEDURE append_page(
        p_text VARCHAR2
    )
    IS
    BEGIN

        IF NOT g_document_active OR g_current_page < 1 OR NOT g_pages.EXISTS(g_current_page) THEN
            RAISE_APPLICATION_ERROR(-20021, 'Inicie um documento com new_document antes de desenhar conteúdo.');
        END IF;
        IF p_text IS NULL THEN
            RETURN;
        END IF;

        DBMS_LOB.WRITEAPPEND(
            g_pages(g_current_page),
            LENGTH(p_text),
            p_text
        );

    END;

    ----------------------------------------------------------------------------
    -- utilitários de cor
    ----------------------------------------------------------------------------

    FUNCTION fmt_num(p_value NUMBER) RETURN VARCHAR2 IS
        l_text VARCHAR2(100);
    BEGIN
        IF p_value IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Valor numérico não pode ser NULL.');
        END IF;

        l_text := TO_CHAR(
            p_value,
            'FM99999999999999999999999999999999999999D999999999999999999',
            'NLS_NUMERIC_CHARACTERS=''.,'''
        );

        IF INSTR(l_text, '#') > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Valor numérico fora do intervalo suportado.');
        END IF;

        IF INSTR(l_text, '.') > 0 THEN
            l_text := RTRIM(RTRIM(l_text, '0'), '.');
        END IF;

        RETURN l_text;
    END;

    FUNCTION fmt_color(p_val NUMBER) RETURN VARCHAR2 IS
        l_decimal NUMBER;
    BEGIN
        IF p_val IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'O componente RGB não pode ser NULL.');
        END IF;
        IF p_val < 0 OR p_val > 255 OR p_val <> TRUNC(p_val) THEN
            RAISE_APPLICATION_ERROR(-20053, 'Componentes RGB devem ser inteiros entre 0 e 255.');
        END IF;

        l_decimal := p_val / 255;
        RETURN fmt_num(l_decimal);
    END;

    PROCEDURE validate_pdf_text(p_text VARCHAR2) IS
        l_raw       RAW(32767);
        l_roundtrip VARCHAR2(32767);
    BEGIN
        IF p_text IS NULL THEN
            RETURN;
        END IF;

        IF g_unicode_font_blob IS NOT NULL THEN
            l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'AL32UTF8');
            DECLARE
                l_position PLS_INTEGER := 1;
                l_codepoint PLS_INTEGER;
            BEGIN
                LOOP
                    next_utf8_codepoint(l_raw, l_position, l_codepoint);
                    EXIT WHEN l_codepoint IS NULL;
                        IF l_codepoint NOT IN (9, 10, 13)
                           AND ttf_glyph(l_codepoint) = 0
                           AND l_codepoint <> 0
                        THEN
                        RAISE_APPLICATION_ERROR(
                            -20077,
                            'A fonte TrueType não contém o caractere Unicode U+' || unicode_hex4(l_codepoint) || '.'
                        );
                    END IF;
                END LOOP;
            END;
            RETURN;
        END IF;

        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'WE8MSWIN1252');
        l_roundtrip := UTL_I18N.RAW_TO_CHAR(l_raw, 'WE8MSWIN1252');
        IF l_roundtrip <> p_text THEN
            RAISE_APPLICATION_ERROR(-20024, 'O texto contém caracteres fora da codificação Windows-1252 suportada.');
        END IF;
    END;

    FUNCTION wrap_text(
        p_text  VARCHAR2,
        p_width NUMBER,
        p_size  NUMBER,
        p_bold  BOOLEAN DEFAULT FALSE
    ) RETURN t_text_lines IS
        l_lines       t_text_lines;
        l_line_count  PLS_INTEGER := 0;
        l_text        VARCHAR2(32767);
        l_segment     VARCHAR2(32767);
        l_line        VARCHAR2(32767);
        l_word        VARCHAR2(32767);
        l_char        VARCHAR2(4);
        l_start       PLS_INTEGER := 1;
        l_break       PLS_INTEGER;
        l_token_no    PLS_INTEGER;
        l_candidate   VARCHAR2(32767);

        PROCEDURE push_line(
            p_value VARCHAR2
        ) IS
        BEGIN
            l_line_count := l_line_count + 1;
            l_lines(l_line_count) := p_value;
        END;

        PROCEDURE wrap_segment(p_value VARCHAR2) IS
        BEGIN
            IF p_value IS NULL THEN
                push_line(NULL);
                RETURN;
            END IF;

            IF TRIM(p_value) IS NULL THEN
                push_line(NULL);
                RETURN;
            END IF;

            l_line := NULL;
            l_token_no := 1;
            LOOP
                l_word := REGEXP_SUBSTR(p_value, '[^ ]+', 1, l_token_no);
                EXIT WHEN l_word IS NULL;

                IF l_line IS NULL THEN
                    l_candidate := l_word;
                ELSE
                    l_candidate := l_line || ' ' || l_word;
                END IF;

                IF get_text_width(l_candidate, p_size, p_bold) <= p_width THEN
                    l_line := l_candidate;
                ELSE
                    IF l_line IS NOT NULL THEN
                        push_line(l_line);
                        l_line := NULL;
                    END IF;

                    IF get_text_width(l_word, p_size, p_bold) <= p_width THEN
                        l_line := l_word;
                    ELSE
                        FOR i IN 1 .. LENGTH(l_word) LOOP
                            l_char := SUBSTR(l_word, i, 1);
                            IF get_text_width(l_char, p_size, p_bold) > p_width THEN
                                RAISE_APPLICATION_ERROR(-20047, 'A largura disponível é menor que a largura de um caractere.');
                            END IF;
                            l_candidate := NVL(l_line, '') || l_char;
                            IF l_line IS NOT NULL
                               AND get_text_width(l_candidate, p_size, p_bold) > p_width
                            THEN
                                push_line(l_line);
                                l_line := l_char;
                            ELSE
                                l_line := l_candidate;
                            END IF;
                        END LOOP;
                    END IF;
                END IF;

                l_token_no := l_token_no + 1;
            END LOOP;

            IF l_line IS NOT NULL THEN
                push_line(l_line);
            ELSIF l_line_count = 0 THEN
                push_line(NULL);
            END IF;
        END;
    BEGIN
        IF p_width IS NULL OR p_width <= 0 OR p_size IS NULL OR p_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20015, 'Largura e tamanho da fonte devem ser positivos.');
        END IF;

        IF p_text IS NULL THEN
            RETURN l_lines;
        END IF;

        l_text := REPLACE(REPLACE(p_text, CHR(13) || CHR(10), CHR(10)), CHR(13), CHR(10));
        l_text := REPLACE(l_text, CHR(9), ' ');

        LOOP
            l_break := INSTR(l_text, CHR(10), l_start);
            IF l_break = 0 THEN
                l_segment := SUBSTR(l_text, l_start);
                wrap_segment(l_segment);
                EXIT;
            END IF;

            l_segment := SUBSTR(l_text, l_start, l_break - l_start);
            wrap_segment(l_segment);
            l_start := l_break + 1;

            IF l_start > LENGTH(l_text) THEN
                push_line(NULL);
                EXIT;
            END IF;
        END LOOP;

        RETURN l_lines;
    END;

    FUNCTION measure_text_width(
        p_text VARCHAR2,
        p_size NUMBER DEFAULT 10,
        p_bold BOOLEAN DEFAULT FALSE
    ) RETURN NUMBER IS
    BEGIN
        IF p_size IS NULL OR p_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20015, 'O tamanho da fonte deve ser positivo.');
        END IF;
        validate_pdf_text(p_text);
        RETURN get_text_width(p_text, p_size, p_bold);
    END;

    FUNCTION measure_paragraph_height(
        p_text         VARCHAR2,
        p_width        NUMBER,
        p_size         NUMBER DEFAULT 10,
        p_line_spacing NUMBER DEFAULT 4,
        p_bold         BOOLEAN DEFAULT FALSE
    ) RETURN NUMBER IS
        l_lines t_text_lines;
    BEGIN
        IF p_line_spacing IS NULL OR p_line_spacing < 0 THEN
            RAISE_APPLICATION_ERROR(-20015, 'O espaçamento entre linhas deve ser não negativo.');
        END IF;
        validate_pdf_text(p_text);
        IF p_text IS NULL THEN
            RETURN 0;
        END IF;
        l_lines := wrap_text(p_text, p_width, p_size, p_bold);
        RETURN l_lines.COUNT * (p_size + p_line_spacing);
    END;

    ----------------------------------------------------------------------------

    PROCEDURE set_fill_color(
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    ) IS
    BEGIN
        -- Operador 'rg' para cor de preenchimento e texto
        append_page(
            fmt_color(p_r) || ' ' ||
            fmt_color(p_g) || ' ' ||
            fmt_color(p_b) || ' rg' || CHR(10)
        );
    END;

    ----------------------------------------------------------------------------

    PROCEDURE set_stroke_color(
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    ) IS
    BEGIN
        -- Operador 'RG' para cor de contorno/linhas
        append_page(
            fmt_color(p_r) || ' ' ||
            fmt_color(p_g) || ' ' ||
            fmt_color(p_b) || ' RG' || CHR(10)
        );
    END;

    ----------------------------------------------------------------------------

    PROCEDURE validate_optional_rgb(
        p_r NUMBER,
        p_g NUMBER,
        p_b NUMBER
    ) IS
    BEGIN
        IF (p_r IS NULL AND (p_g IS NOT NULL OR p_b IS NOT NULL))
           OR (p_g IS NULL AND (p_r IS NOT NULL OR p_b IS NOT NULL))
           OR (p_b IS NULL AND (p_r IS NOT NULL OR p_g IS NOT NULL))
        THEN
            RAISE_APPLICATION_ERROR(-20052, 'Informe todos os componentes RGB ou deixe todos NULL.');
        END IF;
        IF p_r IS NOT NULL AND (p_r < 0 OR p_r > 255
           OR p_g < 0 OR p_g > 255 OR p_b < 0 OR p_b > 255)
        THEN
            RAISE_APPLICATION_ERROR(-20053, 'Os componentes RGB devem estar entre 0 e 255.');
        END IF;
        IF p_r IS NOT NULL AND (p_r <> TRUNC(p_r) OR p_g <> TRUNC(p_g) OR p_b <> TRUNC(p_b)) THEN
            RAISE_APPLICATION_ERROR(-20053, 'Os componentes RGB devem ser números inteiros.');
        END IF;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE render_cell(
        p_text VARCHAR2,
        p_x NUMBER,
        p_y NUMBER,
        p_width NUMBER,
        p_height NUMBER,
        p_align VARCHAR2,
        p_wrap BOOLEAN DEFAULT TRUE,
        p_border BOOLEAN DEFAULT TRUE,
        p_border_r NUMBER DEFAULT NULL,
        p_border_g NUMBER DEFAULT NULL,
        p_border_b NUMBER DEFAULT NULL,
        p_fill_r NUMBER DEFAULT NULL,
        p_fill_g NUMBER DEFAULT NULL,
        p_fill_b NUMBER DEFAULT NULL,
        p_padding NUMBER DEFAULT 2,
        p_valign VARCHAR2 DEFAULT 'M',
        p_text_r NUMBER DEFAULT NULL,
        p_text_g NUMBER DEFAULT NULL,
        p_text_b NUMBER DEFAULT NULL,
        p_bold BOOLEAN DEFAULT FALSE
    ) IS
        l_text_x NUMBER;
        l_lines t_text_lines;
        l_baseline NUMBER;
        l_text_height NUMBER;
        l_inner_height NUMBER;
        l_line_height CONSTANT NUMBER := 11;
    BEGIN
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial antes de desenhar uma célula.');
        END IF;
        validate_optional_rgb(p_fill_r, p_fill_g, p_fill_b);
        validate_optional_rgb(p_text_r, p_text_g, p_text_b);
        validate_optional_rgb(p_border_r, p_border_g, p_border_b);
        IF p_padding IS NULL OR p_padding < 0 OR p_padding * 2 >= p_width THEN
            RAISE_APPLICATION_ERROR(-20054, 'O padding deve ser não negativo e menor que metade da largura da célula.');
        END IF;
        IF p_valign IS NULL OR UPPER(TRIM(p_valign)) NOT IN ('T', 'M', 'B') THEN
            RAISE_APPLICATION_ERROR(-20055, 'Alinhamento vertical inválido; use T, M ou B.');
        END IF;

        append_page('q' || CHR(10));
        IF p_fill_r IS NOT NULL THEN
            append_page(
                fmt_color(p_fill_r) || ' ' || fmt_color(p_fill_g) || ' ' ||
                fmt_color(p_fill_b) || ' rg' || CHR(10) ||
                fmt_num(p_x) || ' ' || fmt_num(p_y) || ' ' ||
                fmt_num(p_width) || ' ' || fmt_num(p_height) || ' re f' || CHR(10)
            );
        END IF;
        IF p_border THEN
            IF p_border_r IS NOT NULL THEN
                append_page(
                    fmt_color(p_border_r) || ' ' || fmt_color(p_border_g) || ' ' ||
                    fmt_color(p_border_b) || ' RG' || CHR(10)
                );
            END IF;
            append_page(
                fmt_num(p_x) || ' ' || fmt_num(p_y) || ' ' ||
                fmt_num(p_width) || ' ' || fmt_num(p_height) || ' re S' || CHR(10)
            );
        END IF;

        IF p_align = 'C' THEN
            l_text_x := p_x + p_width / 2;
        ELSIF p_align = 'R' THEN
            l_text_x := p_x + p_width - p_padding;
        ELSE
            l_text_x := p_x + p_padding;
        END IF;

        append_page(
            fmt_num(p_x) || ' ' || fmt_num(p_y) || ' ' ||
            fmt_num(p_width) || ' ' || fmt_num(p_height) || ' re W n' || CHR(10)
        );
        IF p_text_r IS NOT NULL THEN
            append_page(
                fmt_color(p_text_r) || ' ' || fmt_color(p_text_g) || ' ' ||
                fmt_color(p_text_b) || ' rg' || CHR(10)
            );
        END IF;
        IF p_wrap THEN
            l_lines := wrap_text(p_text, p_width - 2 * p_padding, 9, p_bold);
            l_text_height := GREATEST(l_lines.COUNT, 1) * l_line_height - 2;
            l_inner_height := p_height - 2 * p_padding;
            IF UPPER(p_valign) = 'T' THEN
                l_baseline := p_y + p_height - p_padding - 9;
            ELSIF UPPER(p_valign) = 'B' THEN
                l_baseline := p_y + p_padding + 2 + (GREATEST(l_lines.COUNT, 1) - 1) * l_line_height;
            ELSE
                l_baseline := p_y + p_padding + (l_inner_height - l_text_height) / 2 + 2
                              + (GREATEST(l_lines.COUNT, 1) - 1) * l_line_height;
            END IF;
            FOR i IN 1 .. l_lines.COUNT LOOP
                write_text(
                    p_x      => l_text_x,
                    p_y      => l_baseline,
                    p_text   => l_lines(i),
                    p_size   => 9,
                    p_bold   => p_bold,
                    p_italic => FALSE,
                    p_align  => p_align
                );
                l_baseline := l_baseline - l_line_height;
            END LOOP;
        ELSE
            IF UPPER(p_valign) = 'T' THEN
                l_baseline := p_y + p_height - p_padding - 9;
            ELSIF UPPER(p_valign) = 'B' THEN
                l_baseline := p_y + p_padding + 2;
            ELSE
                l_baseline := p_y + (p_height - 9) / 2 + 2;
            END IF;
            write_text(
                p_x      => l_text_x,
                p_y      => l_baseline,
                p_text   => p_text,
                p_size   => 9,
                p_bold   => p_bold,
                p_italic => FALSE,
                p_align  => p_align
            );
        END IF;
        append_page('Q' || CHR(10));
    END;

    ----------------------------------------------------------------------------

    PROCEDURE set_table_header_style(
        p_fill_r   NUMBER DEFAULT NULL,
        p_fill_g   NUMBER DEFAULT NULL,
        p_fill_b   NUMBER DEFAULT NULL,
        p_border_r NUMBER DEFAULT NULL,
        p_border_g NUMBER DEFAULT NULL,
        p_border_b NUMBER DEFAULT NULL,
        p_text_r   NUMBER DEFAULT NULL,
        p_text_g   NUMBER DEFAULT NULL,
        p_text_b   NUMBER DEFAULT NULL,
        p_bold     BOOLEAN DEFAULT FALSE,
        p_border   BOOLEAN DEFAULT TRUE,
        p_padding  NUMBER DEFAULT 2,
        p_valign   VARCHAR2 DEFAULT 'M'
    ) IS
        l_header_height NUMBER;
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20017, 'Chame new_document antes de configurar o estilo do cabeçalho.');
        END IF;
        IF g_table_x IS NULL OR g_table_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20017, 'Inicialize a tabela com begin_table antes de configurar o estilo do cabeçalho.');
        END IF;
        IF g_header_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20056, 'Configure o estilo antes de adicionar o primeiro cabeçalho.');
        END IF;
        validate_optional_rgb(p_fill_r, p_fill_g, p_fill_b);
        validate_optional_rgb(p_border_r, p_border_g, p_border_b);
        validate_optional_rgb(p_text_r, p_text_g, p_text_b);
        IF p_padding IS NULL OR p_padding < 0 THEN
            RAISE_APPLICATION_ERROR(-20054, 'O padding do cabeçalho deve ser não negativo.');
        END IF;
        IF p_valign IS NULL OR UPPER(TRIM(p_valign)) NOT IN ('T', 'M', 'B') THEN
            RAISE_APPLICATION_ERROR(-20055, 'Alinhamento vertical inválido; use T, M ou B.');
        END IF;
        l_header_height := GREATEST(20, 9 + 2 * p_padding);
        IF l_header_height > g_page_height - g_margin_top - g_margin_bottom THEN
            RAISE_APPLICATION_ERROR(-20056, 'O estilo do cabeçalho gera uma altura maior que a área útil da página.');
        END IF;

        g_header_fill_r := p_fill_r;
        g_header_fill_g := p_fill_g;
        g_header_fill_b := p_fill_b;
        g_header_border_r := p_border_r;
        g_header_border_g := p_border_g;
        g_header_border_b := p_border_b;
        g_header_text_r := p_text_r;
        g_header_text_g := p_text_g;
        g_header_text_b := p_text_b;
        g_header_bold := p_bold;
        IF g_header_bold IS NULL THEN
            g_header_bold := FALSE;
        END IF;
        g_header_border := p_border;
        IF g_header_border IS NULL THEN
            g_header_border := TRUE;
        END IF;
        g_header_padding := p_padding;
        g_header_valign := UPPER(TRIM(p_valign));
        g_header_height := l_header_height;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE add_header(
        p_text  VARCHAR2,
        p_width NUMBER,
        p_align VARCHAR2 DEFAULT 'L'
    )
    IS
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20017, 'Chame new_document antes de add_header.');
        END IF;
        validate_pdf_text(p_text);
        IF g_table_x IS NULL OR g_table_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20017, 'Inicialize a tabela com begin_table antes de adicionar cabeçalhos.');
        END IF;
        IF p_text IS NOT NULL AND LENGTHB(p_text) > 4000 THEN
            RAISE_APPLICATION_ERROR(-20016, 'O texto do cabeçalho excede 4000 bytes.');
        END IF;
        IF p_width IS NULL OR p_width <= 0 THEN
            RAISE_APPLICATION_ERROR(-20018, 'A largura do cabeçalho deve ser positiva.');
        END IF;
        IF p_align IS NULL OR UPPER(TRIM(p_align)) NOT IN ('L', 'C', 'R') THEN
            RAISE_APPLICATION_ERROR(-20029, 'Alinhamento inválido; use L, C ou R.');
        END IF;
        IF g_table_x < 0 OR g_table_x + p_width > g_page_width THEN
            RAISE_APPLICATION_ERROR(-20088, 'O cabeçalho ultrapassa os limites horizontais da página.');
        END IF;

        IF g_header_count = 0 AND g_table_y - g_header_height < g_margin_bottom THEN
            add_page;
        END IF;

        g_header_count := g_header_count + 1;
        g_header_text(g_header_count) := p_text;
        g_header_width(g_header_count) := p_width;
        g_header_align(g_header_count) := UPPER(TRIM(p_align));

        g_table_row_height := GREATEST(NVL(g_table_row_height, 0), g_header_height);
        g_header_row_waiting := TRUE;
        render_cell(
            p_text, g_table_x, g_table_y, p_width, g_header_height, g_header_align(g_header_count), FALSE,
            g_header_border, g_header_border_r, g_header_border_g, g_header_border_b,
            g_header_fill_r, g_header_fill_g, g_header_fill_b,
            g_header_padding, g_header_valign,
            g_header_text_r, g_header_text_g, g_header_text_b, g_header_bold
        );
        g_table_x := g_table_x + p_width;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE draw_headers
    IS
    BEGIN
        g_table_x := g_table_start_x;
        g_table_row_height := 0;

        FOR i IN 1 .. g_header_count LOOP
            render_cell(
                g_header_text(i),
                g_table_x,
                g_table_y,
                g_header_width(i),
                g_header_height,
                g_header_align(i),
                FALSE,
                g_header_border,
                g_header_border_r,
                g_header_border_g,
                g_header_border_b,
                g_header_fill_r,
                g_header_fill_g,
                g_header_fill_b,
                g_header_padding,
                g_header_valign,
                g_header_text_r,
                g_header_text_g,
                g_header_text_b,
                g_header_bold
            );
            g_table_x := g_table_x + g_header_width(i);
        END LOOP;

        g_table_y := g_table_y - g_header_height;
        g_table_last_advance_height := g_header_height;
        g_table_x := g_table_start_x;
        g_table_row_height := 0;
        g_cursor_y := g_table_y;
        g_header_row_waiting := FALSE;
    END;

    ----------------------------------------------------------------------------

    FUNCTION esc(
        p_text VARCHAR2
    )
    RETURN VARCHAR2
    IS
        l_result VARCHAR2(32767);
        l_char   VARCHAR2(4);
        l_code   PLS_INTEGER;
        l_octal  VARCHAR2(3);
        l_value  PLS_INTEGER;
    BEGIN
        IF p_text IS NULL THEN
            RETURN NULL;
        END IF;

        FOR i IN 1 .. LENGTH(p_text) LOOP
            l_char := SUBSTR(p_text, i, 1);
            l_code := ASCII(l_char);
            IF l_char = '\' THEN
                l_result := l_result || '\\';
            ELSIF l_char = '(' THEN
                l_result := l_result || '\(';
            ELSIF l_char = ')' THEN
                l_result := l_result || '\)';
            ELSIF l_code < 32 OR l_code = 127 THEN
                l_value := l_code;
                l_octal := NULL;
                LOOP
                    l_octal := TO_CHAR(MOD(l_value, 8), 'FM0') || l_octal;
                    l_value := TRUNC(l_value / 8);
                    EXIT WHEN l_value = 0;
                END LOOP;
                l_result := l_result || '\' || LPAD(l_octal, 3, '0');
            ELSE
                l_result := l_result || l_char;
            END IF;
        END LOOP;

        RETURN l_result;
    END;

    FUNCTION unicode_hex4(p_value PLS_INTEGER) RETURN VARCHAR2 IS
        l_hex VARCHAR2(8);
    BEGIN
        l_hex := RAWTOHEX(UTL_RAW.CAST_FROM_BINARY_INTEGER(p_value, UTL_RAW.BIG_ENDIAN));
        RETURN SUBSTR(l_hex, 5, 4);
    END;

    FUNCTION unicode_pdf_string(p_text VARCHAR2) RETURN VARCHAR2 IS
        l_raw RAW(32767);
        l_position PLS_INTEGER := 1;
        l_codepoint PLS_INTEGER;
        l_glyph PLS_INTEGER;
        l_hex VARCHAR2(32767);
    BEGIN
        IF p_text IS NULL THEN
            RETURN '<>';
        END IF;
        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'AL32UTF8');
        LOOP
            next_utf8_codepoint(l_raw, l_position, l_codepoint);
            EXIT WHEN l_codepoint IS NULL;
            l_glyph := ttf_glyph(l_codepoint);
            IF l_codepoint <> 0 AND l_glyph = 0 THEN
                RAISE_APPLICATION_ERROR(
                    -20077,
                    'A fonte TrueType não contém o caractere Unicode U+' || unicode_hex4(l_codepoint) || '.'
                );
            END IF;
            g_unicode_used_glyphs(l_codepoint) := l_glyph;
            g_unicode_used_widths(l_codepoint) := ttf_width(l_glyph);
            IF NVL(LENGTH(l_hex), 0) + 4 > 32000 THEN
                RAISE_APPLICATION_ERROR(-20078, 'Texto Unicode excede o limite de codificação de uma operação PDF.');
            END IF;
            l_hex := l_hex || unicode_hex4(l_codepoint);
        END LOOP;
        RETURN '<' || l_hex || '>';
    END;

    FUNCTION unicode_text_width(p_text VARCHAR2, p_size NUMBER) RETURN NUMBER IS
        l_raw RAW(32767);
        l_position PLS_INTEGER := 1;
        l_codepoint PLS_INTEGER;
        l_glyph PLS_INTEGER;
        l_width NUMBER := 0;
    BEGIN
        IF p_text IS NULL THEN
            RETURN 0;
        END IF;
        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'AL32UTF8');
        LOOP
            next_utf8_codepoint(l_raw, l_position, l_codepoint);
            EXIT WHEN l_codepoint IS NULL;
            l_glyph := ttf_glyph(l_codepoint);
            IF l_codepoint <> 0 AND l_glyph = 0 THEN
                RAISE_APPLICATION_ERROR(
                    -20077,
                    'A fonte TrueType não contém o caractere Unicode U+' || unicode_hex4(l_codepoint) || '.'
                );
            END IF;
            g_unicode_used_glyphs(l_codepoint) := l_glyph;
            g_unicode_used_widths(l_codepoint) := ttf_width(l_glyph);
            l_width := l_width + ttf_width(l_glyph);
        END LOOP;
        RETURN l_width * p_size / 1000;
    END;

    FUNCTION pdf_string(p_text VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF g_unicode_font_blob IS NOT NULL THEN
            RETURN unicode_pdf_string(p_text);
        END IF;
        RETURN '(' || esc(p_text) || ')';
    END;

    FUNCTION metadata_pdf_string(p_text VARCHAR2) RETURN VARCHAR2 IS
        l_raw RAW(32767);
    BEGIN
        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'AL16UTF16');
        RETURN '<FEFF' || RAWTOHEX(l_raw) || '>';
    END;

    ----------------------------------------------------------------------------

    FUNCTION get_font_alias(
        p_bold   BOOLEAN,
        p_italic BOOLEAN
    )
    RETURN VARCHAR2
    IS
    BEGIN

        IF g_unicode_font_blob IS NOT NULL THEN
            RETURN 'F5';
        END IF;

        IF p_bold AND p_italic THEN
            RETURN 'F4';
        ELSIF p_bold THEN
            RETURN 'F2';
        ELSIF p_italic THEN
            RETURN 'F3';
        ELSE
            RETURN 'F1';
        END IF;

    END;

    ----------------------------------------------------------------------------

    PROCEDURE write_blob(
        p_blob IN OUT NOCOPY BLOB,
        p_text VARCHAR2
    )
    IS
        l_raw RAW(32767);
    BEGIN

        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'WE8MSWIN1252');

        DBMS_LOB.WRITEAPPEND(
            p_blob,
            UTL_RAW.LENGTH(l_raw),
            l_raw
        );

    END;

    ----------------------------------------------------------------------------

    PROCEDURE append_clob_to_blob(
        p_blob IN OUT NOCOPY BLOB,
        p_clob CLOB
    )
    IS

        l_pos   NUMBER := 1;
        l_chunk VARCHAR2(32767);

    BEGIN

        LOOP

            l_chunk :=
                DBMS_LOB.SUBSTR(
                    p_clob,
                    32767,
                    l_pos
                );

            EXIT WHEN l_chunk IS NULL;

            write_blob(
                p_blob,
                l_chunk
            );

            l_pos := l_pos + LENGTH(l_chunk);

        END LOOP;

    END;

    ----------------------------------------------------------------------------

    PROCEDURE begin_object(
        p_blob   IN OUT NOCOPY BLOB,
        p_obj_no OUT NUMBER
    )
    IS
    BEGIN

        g_obj_count := g_obj_count + 1;

        p_obj_no := g_obj_count;

        g_offsets(p_obj_no) :=
            DBMS_LOB.GETLENGTH(p_blob);

    END;

    ----------------------------------------------------------------------------

    FUNCTION blob_len(
        p_blob BLOB
    )
    RETURN NUMBER
    IS
    BEGIN
        RETURN DBMS_LOB.GETLENGTH(p_blob);
    END;

    PROCEDURE validate_page_chrome(
        p_text VARCHAR2,
        p_size NUMBER,
        p_align VARCHAR2,
        p_y NUMBER
    ) IS
    BEGIN
        IF g_document_active THEN
            RAISE_APPLICATION_ERROR(-20057, 'Configure cabeçalho e rodapé antes de new_document.');
        END IF;
        IF p_size IS NULL OR p_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20058, 'O tamanho do texto de cabeçalho/rodapé deve ser positivo.');
        END IF;
        IF p_align IS NULL OR UPPER(TRIM(p_align)) NOT IN ('L', 'C', 'R') THEN
            RAISE_APPLICATION_ERROR(-20059, 'Alinhamento inválido; use L, C ou R.');
        END IF;
        IF p_y IS NOT NULL AND (p_y < 0 OR p_y > g_page_height) THEN
            RAISE_APPLICATION_ERROR(-20060, 'A coordenada Y do cabeçalho/rodapé deve estar dentro da página.');
        END IF;
        validate_pdf_text(p_text);
        IF p_text IS NOT NULL AND LENGTHB(p_text) > 4000 THEN
            RAISE_APPLICATION_ERROR(-20061, 'O texto de cabeçalho/rodapé excede 4000 bytes.');
        END IF;
    END;

    PROCEDURE set_page_header(
        p_text VARCHAR2,
        p_size NUMBER DEFAULT 9,
        p_bold BOOLEAN DEFAULT FALSE,
        p_align VARCHAR2 DEFAULT 'C',
        p_y NUMBER DEFAULT NULL
    ) IS
    BEGIN
        validate_page_chrome(p_text, p_size, p_align, p_y);
        g_page_header_text := p_text;
        g_page_header_size := p_size;
        g_page_header_bold := p_bold;
        g_page_header_align := UPPER(TRIM(p_align));
        g_page_header_y := p_y;
    END;

    PROCEDURE set_page_footer(
        p_text VARCHAR2,
        p_size NUMBER DEFAULT 9,
        p_bold BOOLEAN DEFAULT FALSE,
        p_align VARCHAR2 DEFAULT 'C',
        p_y NUMBER DEFAULT NULL
    ) IS
    BEGIN
        validate_page_chrome(p_text, p_size, p_align, p_y);
        g_page_footer_text := p_text;
        g_page_footer_size := p_size;
        g_page_footer_bold := p_bold;
        g_page_footer_align := UPPER(TRIM(p_align));
        g_page_footer_y := p_y;
    END;

    PROCEDURE draw_page_chrome IS
        l_text VARCHAR2(4000);
        l_x NUMBER;
        l_y NUMBER;
        l_width NUMBER;
        l_font VARCHAR2(2);

        PROCEDURE draw_one(
            p_text VARCHAR2,
            p_size NUMBER,
            p_bold BOOLEAN,
            p_align VARCHAR2,
            p_y NUMBER,
            p_is_header BOOLEAN
        ) IS
        BEGIN
            IF p_text IS NULL THEN
                RETURN;
            END IF;

            l_text := REPLACE(p_text, '{PAGE}', fmt_num(g_current_page));
            l_y := NVL(p_y, CASE WHEN p_is_header
                                 THEN g_page_height - g_margin_top / 2
                                 ELSE g_margin_bottom / 2
                            END);
            l_width := get_text_width(l_text, p_size, p_bold);
            IF p_align = 'C' THEN
                l_x := (g_page_width - l_width) / 2;
            ELSIF p_align = 'R' THEN
                l_x := g_page_width - g_margin_right - l_width;
            ELSE
                l_x := g_margin_left;
            END IF;
            l_font := get_font_alias(p_bold, FALSE);

            append_page(
                'BT' || CHR(10) ||
                '/' || l_font || ' ' || fmt_num(p_size) || ' Tf' || CHR(10) ||
                fmt_num(l_x) || ' ' || fmt_num(l_y) || ' Td' || CHR(10) ||
                pdf_string(l_text) || ' Tj' || CHR(10) ||
                'ET' || CHR(10)
            );
        END;
    BEGIN
        draw_one(
            g_page_header_text,
            g_page_header_size,
            g_page_header_bold,
            g_page_header_align,
            g_page_header_y,
            TRUE
        );
        draw_one(
            g_page_footer_text,
            g_page_footer_size,
            g_page_footer_bold,
            g_page_footer_align,
            g_page_footer_y,
            FALSE
        );
    END;

    ----------------------------------------------------------------------------
    -- documento
    ----------------------------------------------------------------------------

    PROCEDURE new_document
    IS
    BEGIN
        FOR i IN 1 .. g_page_count LOOP
            IF g_pages.EXISTS(i) AND DBMS_LOB.ISTEMPORARY(g_pages(i)) = 1 THEN
                DBMS_LOB.FREETEMPORARY(g_pages(i));
            END IF;
        END LOOP;

        FOR i IN 1 .. g_image_count LOOP
            IF g_images.EXISTS(i)
               AND g_images(i).blob_data IS NOT NULL
               AND DBMS_LOB.ISTEMPORARY(g_images(i).blob_data) = 1
            THEN
                DBMS_LOB.FREETEMPORARY(g_images(i).blob_data);
            END IF;
        END LOOP;

        g_pages.DELETE;
        g_page_count := 0;
        g_current_page := 0;

        g_header_text.DELETE;
        g_header_width.DELETE;
        g_header_align.DELETE;
        g_header_count := 0;
        g_pending_cells.DELETE;
        g_pending_cell_count := 0;
        g_header_row_waiting := FALSE;
        g_table_start_x := NULL;
        g_table_x := NULL;
        g_table_y := NULL;
        g_table_row_height := 0;
        g_path_open := FALSE;
        g_images.DELETE;
        g_image_count := 0;
        g_unicode_used_glyphs.DELETE;
        g_unicode_used_widths.DELETE;

        g_offsets.DELETE;
        g_obj_count := 0;

        g_document_page_width := g_page_width;
        g_document_page_height := g_page_height;
        g_document_active := TRUE;

        add_page;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE add_page
    IS
      l_temp_clob CLOB;

    BEGIN
            IF NOT g_document_active THEN
                    RAISE_APPLICATION_ERROR(-20021, 'Chame new_document antes de add_page.');
            END IF;
            IF g_path_open THEN
                    RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial antes de iniciar outra página.');
            END IF;

      g_page_count := g_page_count + 1;

      g_current_page := g_page_count;

      DBMS_LOB.CREATETEMPORARY(
          l_temp_clob,
          TRUE
      );

      g_pages(g_current_page) := l_temp_clob;

      g_cursor_y :=
          g_page_height - g_margin_top;

      IF g_table_start_x IS NOT NULL THEN
          g_table_x := g_table_start_x;
          g_table_y := g_page_height - g_margin_top;
          g_table_row_height := 0;
          g_table_last_advance_height := 0;
      END IF;
      draw_page_chrome;

    END;

    PROCEDURE set_metadata(
        p_title VARCHAR2,
        p_author VARCHAR2,
        p_subject VARCHAR2,
        p_keywords VARCHAR2
    ) IS
    BEGIN
        IF p_title IS NOT NULL AND LENGTHB(p_title) > 4000
           OR p_author IS NOT NULL AND LENGTHB(p_author) > 4000
           OR p_subject IS NOT NULL AND LENGTHB(p_subject) > 4000
           OR p_keywords IS NOT NULL AND LENGTHB(p_keywords) > 4000
        THEN
            RAISE_APPLICATION_ERROR(-20081, 'Cada campo de metadados deve ter no máximo 4000 bytes.');
        END IF;

        g_metadata_title := p_title;
        g_metadata_author := p_author;
        g_metadata_subject := p_subject;
        g_metadata_keywords := p_keywords;
    END;

    ----------------------------------------------------------------------------
    -- Configuração de margens (parâmetros em centímetros)
    ----------------------------------------------------------------------------

    PROCEDURE set_margins_cm(
        p_top_cm    NUMBER,
        p_left_cm   NUMBER,
        p_right_cm  NUMBER,
        p_bottom_cm NUMBER
    ) IS
        l_top_pt    NUMBER;
        l_left_pt   NUMBER;
        l_right_pt  NUMBER;
        l_bottom_pt NUMBER;
    BEGIN
        IF g_document_active THEN
            RAISE_APPLICATION_ERROR(-20087, 'Configure as margens antes de new_document.');
        END IF;
        IF p_top_cm IS NULL OR p_left_cm IS NULL
           OR p_right_cm IS NULL OR p_bottom_cm IS NULL
           OR p_top_cm < 0 OR p_left_cm < 0
           OR p_right_cm < 0 OR p_bottom_cm < 0
        THEN
            RAISE_APPLICATION_ERROR(-20030, 'As margens devem ser valores não negativos em centímetros.');
        END IF;

        l_top_pt := p_top_cm * g_points_per_cm;
        l_left_pt := p_left_cm * g_points_per_cm;
        l_right_pt := p_right_cm * g_points_per_cm;
        l_bottom_pt := p_bottom_cm * g_points_per_cm;

        IF l_left_pt + l_right_pt >= g_page_width
           OR l_top_pt + l_bottom_pt >= g_page_height
        THEN
            RAISE_APPLICATION_ERROR(-20031, 'As margens não deixam área útil na página.');
        END IF;

        g_margin_top := l_top_pt;
        g_margin_left := l_left_pt;
        g_margin_right := l_right_pt;
        g_margin_bottom := l_bottom_pt;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE ensure_page_space(
        p_required_height NUMBER
    )
    IS
    BEGIN
      IF NOT g_document_active OR g_current_page < 1 THEN
          RAISE_APPLICATION_ERROR(-20021, 'Inicie um documento com new_document antes de paginar conteúdo.');
      END IF;

      IF p_required_height IS NULL OR p_required_height < 0 THEN
          RAISE_APPLICATION_ERROR(-20034, 'A altura solicitada para paginação deve ser não negativa.');
      END IF;

      IF p_required_height > g_page_height - g_margin_top - g_margin_bottom THEN
          RAISE_APPLICATION_ERROR(-20035, 'O bloco excede a área útil vertical da página.');
      END IF;

      IF g_cursor_y - p_required_height
          < g_margin_bottom
      THEN

          add_page;

      END IF;

    END;

    ----------------------------------------------------------------------------

    PROCEDURE write_line(
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_bold      BOOLEAN DEFAULT FALSE,
        p_italic    BOOLEAN DEFAULT FALSE
    )
    IS
    BEGIN
        IF p_size IS NULL OR p_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20015, 'O tamanho da fonte de write_line deve ser positivo.');
        END IF;

        ensure_page_space(
            p_size + 4
        );

        write_text(
            p_x       => g_margin_left,
            p_y       => g_cursor_y,
            p_text    => p_text,
            p_size    => p_size,
            p_bold    => p_bold,
            p_italic  => p_italic
        );

        g_cursor_y :=
            g_cursor_y - p_size - 4;

    END;

    ----------------------------------------------------------------------------
    -- Posição atual
    ----------------------------------------------------------------------------

    FUNCTION current_y
    RETURN NUMBER
    IS
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20021, 'current_y só pode ser consultado durante um documento ativo.');
        END IF;
        RETURN g_cursor_y;
    END;

    ----------------------------------------------------------------------------
    -- texto
    ----------------------------------------------------------------------------

    PROCEDURE write_text(
        p_x         NUMBER,
        p_y         NUMBER,
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_bold      BOOLEAN DEFAULT FALSE,
        p_italic    BOOLEAN DEFAULT FALSE,
        p_align     VARCHAR2 DEFAULT 'L'
    )
    IS
        l_font VARCHAR2(100);
        l_x    NUMBER := p_x;
        l_w    NUMBER;
        l_align VARCHAR2(1) := UPPER(TRIM(p_align));
    BEGIN
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20029, 'As coordenadas X e Y de write_text são obrigatórias.');
        END IF;
        IF p_x < 0 OR p_x > g_page_width OR p_y < 0 OR p_y > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20029, 'As coordenadas de write_text devem estar dentro da página.');
        END IF;
        IF p_size IS NULL OR p_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20015, 'O tamanho da fonte de write_text deve ser positivo.');
        END IF;
        validate_pdf_text(p_text);
        IF l_align IS NULL OR l_align NOT IN ('L', 'C', 'R') THEN
            RAISE_APPLICATION_ERROR(-20029, 'Alinhamento inválido; use L, C ou R.');
        END IF;
        l_w := get_text_width(p_text, p_size, p_bold);
        IF l_align IN ('C', 'R') THEN
            IF l_align = 'C' THEN
                l_x := p_x - (l_w / 2);
            ELSIF l_align = 'R' THEN
                l_x := p_x - l_w;
            END IF;
        END IF;
        IF l_x < 0 OR l_x + l_w > g_page_width THEN
            RAISE_APPLICATION_ERROR(-20029, 'O texto alinhado ultrapassa os limites horizontais da página.');
        END IF;


        l_font := get_font_alias(
                    p_bold,
                    p_italic
                  );

        append_page(
            'BT' || CHR(10) ||
            '/' || l_font || ' ' || fmt_num(p_size) || ' Tf' || CHR(10) ||
            fmt_num(l_x) || ' ' || fmt_num(p_y) || ' Td' || CHR(10) ||
            pdf_string(p_text) || ' Tj' || CHR(10) ||
            'ET' || CHR(10)
        );

    END;

    ----------------------------------------------------------------------------

    PROCEDURE write_paragraph_legacy(
        p_x         NUMBER,
        p_y         NUMBER,
        p_width     NUMBER,
        p_text      VARCHAR2,
        p_size      NUMBER DEFAULT 10,
        p_paragraph_spacing NUMBER DEFAULT 0,
        p_align     VARCHAR2 DEFAULT 'L'
    )
    IS
        l_text      VARCHAR2(32767);
        l_segment   VARCHAR2(32767);
        l_line_pos  PLS_INTEGER := 1;
        l_break_pos PLS_INTEGER;

        PROCEDURE write_segment(p_segment VARCHAR2) IS
            l_word         VARCHAR2(32767);
            l_line         VARCHAR2(32767);
            l_pos          PLS_INTEGER := 1;
            l_char         VARCHAR2(4);
            l_space_count  PLS_INTEGER;

            PROCEDURE write_justified_line IS
                l_tj_content VARCHAR2(32767) := '[';
                l_tj_word    VARCHAR2(32767);
                l_tj_char    VARCHAR2(4);
                l_extra      NUMBER;
                l_adjustment NUMBER;
            BEGIN
                -- Os espaços são removidos dos fragmentos TJ; repõe-se o espaço
                -- normal além da folga distribuída para justificar a linha.
                l_extra := GREATEST(
                    0,
                    ((p_width - 1 - get_text_width(l_line, p_size)) * 0.95) / l_space_count
                    + get_text_width(' ', p_size)
                );
                l_adjustment := -l_extra * 1000 / p_size;

                FOR i IN 1 .. LENGTH(l_line) LOOP
                    l_tj_char := SUBSTR(l_line, i, 1);
                    IF l_tj_char = ' ' THEN
                        l_tj_content := l_tj_content || pdf_string(l_tj_word) || ' ' ||
                                        fmt_num(l_adjustment) || ' ';
                        l_tj_word := NULL;
                    ELSE
                        l_tj_word := l_tj_word || l_tj_char;
                    END IF;
                END LOOP;

                l_tj_content := l_tj_content || pdf_string(l_tj_word) || ']';
                append_page(
                    'BT' || CHR(10) ||
                    '/' || get_font_alias(FALSE, FALSE) || ' ' || fmt_num(p_size) || ' Tf' || CHR(10) ||
                    fmt_num(p_x) || ' ' || fmt_num(g_cursor_y) || ' Td' || CHR(10) ||
                    l_tj_content || ' TJ' || CHR(10) ||
                    'ET' || CHR(10)
                );
            END;

            PROCEDURE write_aligned_line IS
            BEGIN
                IF p_align = 'C' THEN
                    write_text(p_x + p_width / 2, g_cursor_y, l_line, p_size, p_align => 'C');
                ELSIF p_align = 'R' THEN
                    write_text(p_x + p_width, g_cursor_y, l_line, p_size, p_align => 'R');
                ELSE
                    write_text(p_x, g_cursor_y, l_line, p_size);
                END IF;
            END;

            PROCEDURE flush_line(p_justify BOOLEAN) IS
            BEGIN
                IF l_line IS NOT NULL THEN
                    l_line := TRIM(l_line);
                    ensure_page_space(p_size + 4);
                    l_space_count := LENGTH(l_line) - LENGTH(REPLACE(l_line, ' ', ''));

                    IF p_justify AND p_align = 'J' AND l_space_count > 0
                       AND get_text_width(l_line, p_size) < p_width - 1
                    THEN
                        write_justified_line;
                    ELSE
                        write_aligned_line;
                    END IF;

                    g_cursor_y := g_cursor_y - p_size - 4;
                    l_line := NULL;
                END IF;
            END;
        BEGIN
            IF p_segment IS NULL THEN
                ensure_page_space(p_size + 4);
                g_cursor_y := g_cursor_y - p_size - 4;
                RETURN;
            END IF;

            LOOP
                l_word := REGEXP_SUBSTR(p_segment, '[^ ]+| +', 1, l_pos);
                EXIT WHEN l_word IS NULL;

                IF SUBSTR(l_word, 1, 1) = ' ' THEN
                    FOR i IN 1 .. LENGTH(l_word) LOOP
                        IF l_line IS NOT NULL
                           AND get_text_width(l_line || ' ', p_size) > p_width
                        THEN
                            flush_line(p_align = 'J');
                        END IF;
                        l_line := NVL(l_line, '') || ' ';
                    END LOOP;
                ELSE
                    IF l_line IS NOT NULL
                       AND get_text_width(l_line || l_word, p_size) > p_width
                    THEN
                        flush_line(p_align = 'J');
                    END IF;

                    IF get_text_width(l_word, p_size) <= p_width THEN
                        l_line := NVL(l_line, '') || l_word;
                    ELSE
                        flush_line(FALSE);
                        FOR i IN 1 .. LENGTH(l_word) LOOP
                            l_char := SUBSTR(l_word, i, 1);
                            IF l_line IS NOT NULL
                               AND get_text_width(l_line || l_char, p_size) > p_width
                            THEN
                                flush_line(FALSE);
                            END IF;
                            l_line := NVL(l_line, '') || l_char;
                        END LOOP;
                    END IF;
                END IF;

                l_pos := l_pos + 1;
            END LOOP;

            -- A última linha de cada segmento explícito não é justificada.
            flush_line(FALSE);
        END;

    BEGIN
        IF p_width IS NULL OR p_width <= 0 OR p_size IS NULL OR p_size <= 0
           OR p_paragraph_spacing IS NULL OR p_paragraph_spacing < 0
        THEN
            RAISE_APPLICATION_ERROR(-20015, 'Largura e tamanho da fonte devem ser positivos; o espaçamento deve ser não negativo.');
        END IF;
        IF p_align IS NULL OR UPPER(TRIM(p_align)) NOT IN ('L', 'C', 'R', 'J') THEN
            RAISE_APPLICATION_ERROR(-20032, 'Alinhamento de parágrafo inválido; use L, C, R ou J.');
        END IF;

        validate_pdf_text(p_text);
        g_cursor_y := p_y;
        l_text := REPLACE(REPLACE(p_text, CHR(13) || CHR(10), CHR(10)), CHR(13), CHR(10));
        l_text := REPLACE(l_text, CHR(9), ' ');

        IF l_text IS NULL THEN
            RETURN;
        END IF;

        LOOP
            l_break_pos := INSTR(l_text, CHR(10), l_line_pos);
            IF l_break_pos = 0 THEN
                l_segment := SUBSTR(l_text, l_line_pos);
                write_segment(l_segment);
                EXIT;
            END IF;

            l_segment := SUBSTR(l_text, l_line_pos, l_break_pos - l_line_pos);
            write_segment(l_segment);
            l_line_pos := l_break_pos + 1;
            IF l_line_pos > LENGTH(l_text) THEN
                write_segment(NULL);
                EXIT;
            END IF;
        END LOOP;

        g_cursor_y := g_cursor_y - p_paragraph_spacing;

    END;

    PROCEDURE write_paragraph(
        p_x NUMBER,
        p_y NUMBER,
        p_width NUMBER,
        p_text VARCHAR2,
        p_size NUMBER DEFAULT 10,
        p_paragraph_spacing NUMBER DEFAULT 0,
        p_align VARCHAR2 DEFAULT 'L'
    ) IS
        l_lines t_text_lines;
        l_line VARCHAR2(32767);
        l_space_count PLS_INTEGER;
        l_extra NUMBER;
        l_adjustment NUMBER;
        l_tj_content VARCHAR2(32767);
        l_tj_word VARCHAR2(32767);
        l_align VARCHAR2(1) := UPPER(TRIM(p_align));
    BEGIN
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20032, 'As coordenadas X e Y de write_paragraph são obrigatórias.');
        END IF;
        IF p_x < 0 OR p_y < 0 OR p_y > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20032, 'As coordenadas do parágrafo devem estar dentro da página.');
        END IF;
        IF p_width IS NULL OR p_width <= 0 OR p_size IS NULL OR p_size <= 0
           OR p_paragraph_spacing IS NULL OR p_paragraph_spacing < 0
        THEN
            RAISE_APPLICATION_ERROR(-20015, 'Largura e tamanho da fonte devem ser positivos; o espaçamento deve ser não negativo.');
        END IF;
        IF p_x + p_width > g_page_width THEN
            RAISE_APPLICATION_ERROR(-20032, 'A largura do parágrafo ultrapassa o limite direito da página.');
        END IF;
        IF l_align IS NULL OR l_align NOT IN ('L', 'C', 'R', 'J') THEN
            RAISE_APPLICATION_ERROR(-20032, 'Alinhamento de parágrafo inválido; use L, C, R ou J.');
        END IF;

        validate_pdf_text(p_text);
        IF p_text IS NULL THEN
            RETURN;
        END IF;

        l_lines := wrap_text(p_text, p_width, p_size);
        g_cursor_y := p_y;
        FOR i IN 1 .. l_lines.COUNT LOOP
            l_line := l_lines(i);
            ensure_page_space(p_size + 4);

            l_space_count := LENGTH(l_line) - LENGTH(REPLACE(l_line, ' ', ''));
            IF l_align = 'J' AND i < l_lines.COUNT AND l_space_count > 0
               AND get_text_width(l_line, p_size) < p_width
            THEN
                l_extra := (p_width - get_text_width(l_line, p_size)) / l_space_count
                           + get_text_width(' ', p_size);
                l_adjustment := -l_extra * 1000 / p_size;
                l_tj_content := '[';
                l_tj_word := NULL;
                FOR j IN 1 .. LENGTH(l_line) LOOP
                    IF SUBSTR(l_line, j, 1) = ' ' THEN
                        l_tj_content := l_tj_content || pdf_string(l_tj_word) || ' ' ||
                                        fmt_num(l_adjustment) || ' ';
                        l_tj_word := NULL;
                    ELSE
                        l_tj_word := l_tj_word || SUBSTR(l_line, j, 1);
                    END IF;
                END LOOP;
                l_tj_content := l_tj_content || pdf_string(l_tj_word) || ']';
                append_page(
                    'BT' || CHR(10) ||
                    '/' || get_font_alias(FALSE, FALSE) || ' ' || fmt_num(p_size) || ' Tf' || CHR(10) ||
                    fmt_num(p_x) || ' ' || fmt_num(g_cursor_y) || ' Td' || CHR(10) ||
                    l_tj_content || ' TJ' || CHR(10) ||
                    'ET' || CHR(10)
                );
            ELSIF l_align = 'C' THEN
                write_text(p_x + p_width / 2, g_cursor_y, l_line, p_size, p_align => 'C');
            ELSIF l_align = 'R' THEN
                write_text(p_x + p_width, g_cursor_y, l_line, p_size, p_align => 'R');
            ELSE
                write_text(p_x, g_cursor_y, l_line, p_size);
            END IF;

            g_cursor_y := g_cursor_y - p_size - 4;
        END LOOP;
        g_cursor_y := g_cursor_y - p_paragraph_spacing;
    END;

    ----------------------------------------------------------------------------
    -- desenho
    ----------------------------------------------------------------------------

    PROCEDURE draw_line(
        p_x1 NUMBER,
        p_y1 NUMBER,
        p_x2 NUMBER,
        p_y2 NUMBER
    )
    IS
    BEGIN
        IF p_x1 IS NULL OR p_y1 IS NULL OR p_x2 IS NULL OR p_y2 IS NULL THEN
            RAISE_APPLICATION_ERROR(-20082, 'draw_line exige quatro coordenadas numéricas.');
        END IF;
        IF p_x1 < 0 OR p_x1 > g_page_width OR p_x2 < 0 OR p_x2 > g_page_width
           OR p_y1 < 0 OR p_y1 > g_page_height OR p_y2 < 0 OR p_y2 > g_page_height
        THEN
            RAISE_APPLICATION_ERROR(-20082, 'As coordenadas de draw_line devem estar dentro da página.');
        END IF;
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial atual antes de chamar draw_line.');
        END IF;

        append_page(
            fmt_num(p_x1) || ' ' || fmt_num(p_y1) || ' m' || CHR(10) ||
            fmt_num(p_x2) || ' ' || fmt_num(p_y2) || ' l' || CHR(10) ||
            'S' || CHR(10)
        );

    END;

    ----------------------------------------------------------------------------

    PROCEDURE draw_rect(
        p_x      NUMBER,
        p_y      NUMBER,
        p_width  NUMBER,
        p_height NUMBER
    )
    IS
    BEGIN
        IF p_x IS NULL OR p_y IS NULL OR p_width IS NULL OR p_height IS NULL
           OR p_width <= 0 OR p_height <= 0
        THEN
            RAISE_APPLICATION_ERROR(-20083, 'draw_rect exige coordenadas e dimensões positivas.');
        END IF;
        IF p_x < 0 OR p_y < 0 OR p_x + p_width > g_page_width OR p_y + p_height > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20083, 'draw_rect ultrapassa os limites da página.');
        END IF;
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial atual antes de chamar draw_rect.');
        END IF;

        append_page(
            fmt_num(p_x) || ' ' || fmt_num(p_y) || ' ' ||
            fmt_num(p_width) || ' ' || fmt_num(p_height) || ' re' || CHR(10) ||
            'S' || CHR(10)
        );

    END;

    ----------------------------------------------------------------------------
    -- tabela
    ----------------------------------------------------------------------------

    PROCEDURE begin_table(
        p_x NUMBER,
        p_y NUMBER
    )
    IS
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20017, 'Chame new_document antes de begin_table.');
        END IF;
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20017, 'begin_table exige coordenadas X e Y.');
        END IF;
        IF p_x < 0 OR p_x >= g_page_width OR p_y < 0 OR p_y > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20017, 'begin_table deve iniciar dentro dos limites da página.');
        END IF;
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial com stroke_path ou fill_path antes de iniciar uma tabela.');
        END IF;
        g_header_text.DELETE;
        g_header_width.DELETE;
        g_header_align.DELETE;
        g_header_count := 0;
        g_header_fill_r := NULL;
        g_header_fill_g := NULL;
        g_header_fill_b := NULL;
        g_header_border_r := NULL;
        g_header_border_g := NULL;
        g_header_border_b := NULL;
        g_header_text_r := NULL;
        g_header_text_g := NULL;
        g_header_text_b := NULL;
        g_header_bold := FALSE;
        g_header_border := TRUE;
        g_header_padding := 2;
        g_header_valign := 'M';
        g_header_height := 20;
        g_pending_cells.DELETE;
        g_pending_cell_count := 0;
        g_header_row_waiting := FALSE;
        g_table_start_x := p_x;
        g_table_x       := p_x;
        g_table_y       := p_y;
        g_table_row_height := 0;
        g_table_last_advance_height := 0;
        g_cursor_y := p_y;
    END;

    ----------------------------------------------------------------------------

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
    )
    IS
        l_lines t_text_lines;
        l_cell_height NUMBER;
        l_inner_width NUMBER;
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20017, 'Chame new_document antes de add_cell.');
        END IF;
        IF g_table_x IS NULL OR g_table_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20017, 'Inicialize a tabela com begin_table antes de adicionar células.');
        END IF;
        IF p_width IS NULL OR p_width <= 0 OR p_height IS NULL OR p_height <= 0 THEN
            RAISE_APPLICATION_ERROR(-20018, 'Largura e altura da célula devem ser positivas.');
        END IF;
        IF g_table_x < 0 OR g_table_x + p_width > g_page_width THEN
            RAISE_APPLICATION_ERROR(-20088, 'A célula ultrapassa os limites horizontais da página.');
        END IF;
        IF p_align IS NULL OR UPPER(TRIM(p_align)) NOT IN ('L', 'C', 'R') THEN
            RAISE_APPLICATION_ERROR(-20029, 'Alinhamento inválido; use L, C ou R.');
        END IF;
        IF p_padding IS NULL OR p_padding < 0 OR p_padding * 2 >= p_width THEN
            RAISE_APPLICATION_ERROR(-20054, 'O padding deve ser não negativo e menor que metade da largura da célula.');
        END IF;
        IF p_valign IS NULL OR UPPER(TRIM(p_valign)) NOT IN ('T', 'M', 'B') THEN
            RAISE_APPLICATION_ERROR(-20055, 'Alinhamento vertical inválido; use T, M ou B.');
        END IF;
        validate_optional_rgb(p_fill_r, p_fill_g, p_fill_b);
        validate_optional_rgb(p_border_r, p_border_g, p_border_b);
        validate_optional_rgb(p_text_r, p_text_g, p_text_b);

        validate_pdf_text(p_text);
        l_inner_width := p_width - 2 * p_padding;
        IF p_text IS NULL THEN
            l_cell_height := p_height;
        ELSE
            l_lines := wrap_text(p_text, l_inner_width, 9, p_bold);
            l_cell_height := GREATEST(p_height, l_lines.COUNT * 11 - 2 + 2 * p_padding);
        END IF;

        g_pending_cell_count := g_pending_cell_count + 1;
        g_pending_cells(g_pending_cell_count).text := p_text;
        g_pending_cells(g_pending_cell_count).width := p_width;
        g_pending_cells(g_pending_cell_count).height := l_cell_height;
        g_pending_cells(g_pending_cell_count).align := UPPER(TRIM(p_align));
        g_pending_cells(g_pending_cell_count).border := p_border;
        IF p_border IS NULL THEN
            g_pending_cells(g_pending_cell_count).border := TRUE;
        END IF;
        g_pending_cells(g_pending_cell_count).border_r := p_border_r;
        g_pending_cells(g_pending_cell_count).border_g := p_border_g;
        g_pending_cells(g_pending_cell_count).border_b := p_border_b;
        g_pending_cells(g_pending_cell_count).fill_r := p_fill_r;
        g_pending_cells(g_pending_cell_count).fill_g := p_fill_g;
        g_pending_cells(g_pending_cell_count).fill_b := p_fill_b;
        g_pending_cells(g_pending_cell_count).text_r := p_text_r;
        g_pending_cells(g_pending_cell_count).text_g := p_text_g;
        g_pending_cells(g_pending_cell_count).text_b := p_text_b;
        g_pending_cells(g_pending_cell_count).padding := p_padding;
        g_pending_cells(g_pending_cell_count).valign := UPPER(TRIM(p_valign));
        g_pending_cells(g_pending_cell_count).bold := p_bold;
        IF g_pending_cells(g_pending_cell_count).bold IS NULL THEN
            g_pending_cells(g_pending_cell_count).bold := FALSE;
        END IF;
        g_table_row_height := GREATEST(NVL(g_table_row_height, 0), l_cell_height);
        g_table_x := g_table_x + p_width;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE place_pending_row(
        p_row_height NUMBER,
        p_advance BOOLEAN
    ) IS
        l_x NUMBER;
        l_required_height NUMBER := p_row_height;
        l_row_y NUMBER;
        l_available_height NUMBER := g_page_height - g_margin_top - g_margin_bottom;
    BEGIN
        IF g_pending_cell_count = 0 THEN
            RETURN;
        END IF;

        IF g_header_count > 0 THEN
            l_available_height := l_available_height - g_header_height;
        END IF;
        IF l_required_height > l_available_height THEN
            RAISE_APPLICATION_ERROR(-20033, 'A altura da linha da tabela excede a área útil de uma página.');
        END IF;

        l_row_y := g_table_y + g_table_last_advance_height - l_required_height;
        IF l_row_y < g_margin_bottom THEN
            add_page;
            IF g_header_count > 0 THEN
                draw_headers;
            END IF;
            l_row_y := g_table_y + g_table_last_advance_height - l_required_height;
        END IF;

        l_x := g_table_start_x;
        FOR i IN 1 .. g_pending_cell_count LOOP
            render_cell(
                g_pending_cells(i).text,
                l_x,
                l_row_y,
                g_pending_cells(i).width,
                l_required_height,
                g_pending_cells(i).align,
                TRUE,
                g_pending_cells(i).border,
                g_pending_cells(i).border_r,
                g_pending_cells(i).border_g,
                g_pending_cells(i).border_b,
                g_pending_cells(i).fill_r,
                g_pending_cells(i).fill_g,
                g_pending_cells(i).fill_b,
                g_pending_cells(i).padding,
                g_pending_cells(i).valign,
                g_pending_cells(i).text_r,
                g_pending_cells(i).text_g,
                g_pending_cells(i).text_b,
                g_pending_cells(i).bold
            );
            l_x := l_x + g_pending_cells(i).width;
        END LOOP;

        g_pending_cells.DELETE;
        g_pending_cell_count := 0;
        g_table_row_height := 0;
        g_table_x := g_table_start_x;
        g_header_row_waiting := FALSE;

        IF p_advance THEN
            g_table_y := l_row_y - l_required_height;
            g_table_last_advance_height := l_required_height;
        END IF;
        g_cursor_y := g_table_y;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE next_row(
        p_height NUMBER DEFAULT 20
    )
    IS
        l_row_height NUMBER;
    BEGIN
        IF NOT g_document_active THEN
            RAISE_APPLICATION_ERROR(-20019, 'Chame new_document antes de next_row.');
        END IF;
        IF g_table_y IS NULL OR g_table_start_x IS NULL THEN
            RAISE_APPLICATION_ERROR(-20019, 'Inicialize a tabela com begin_table antes de avançar a linha.');
        END IF;
        IF p_height IS NULL OR p_height <= 0 THEN
            RAISE_APPLICATION_ERROR(-20020, 'A altura da linha deve ser positiva.');
        END IF;

        l_row_height := GREATEST(p_height, NVL(g_table_row_height, 0));
        IF l_row_height > g_page_height - g_margin_top - g_margin_bottom THEN
            RAISE_APPLICATION_ERROR(-20033, 'A altura da linha excede a área útil vertical da página.');
        END IF;
        IF g_pending_cell_count > 0 THEN
            place_pending_row(l_row_height, TRUE);
        ELSIF g_header_row_waiting THEN
            IF g_table_y - l_row_height < g_margin_bottom THEN
                add_page;
                draw_headers;
            ELSE
                g_table_y := g_table_y - l_row_height;
                g_table_last_advance_height := l_row_height;
            END IF;
            g_header_row_waiting := FALSE;
            g_table_x := g_table_start_x;
            g_table_row_height := 0;
            g_cursor_y := g_table_y;
        ELSE
            IF g_table_y - l_row_height < g_margin_bottom THEN
                add_page;
                IF g_header_count > 0 THEN
                    draw_headers;
                END IF;
                g_table_y := g_table_y - l_row_height;
            ELSE
                g_table_y := g_table_y - l_row_height;
            END IF;
            g_table_last_advance_height := l_row_height;
            g_table_x := g_table_start_x;
            g_table_row_height := 0;
            g_cursor_y := g_table_y;
        END IF;
    END;

    ----------------------------------------------------------------------------
    -- vetores e curvas de bézier
    ----------------------------------------------------------------------------

    PROCEDURE begin_path(
        p_x NUMBER,
        p_y NUMBER
    ) IS
    BEGIN
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial atual antes de chamar begin_path novamente.');
        END IF;
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20084, 'begin_path exige coordenadas X e Y.');
        END IF;
        IF p_x < 0 OR p_x > g_page_width OR p_y < 0 OR p_y > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20084, 'begin_path deve iniciar dentro dos limites da página.');
        END IF;
        append_page(fmt_num(p_x) || ' ' || fmt_num(p_y) || ' m' || CHR(10));
        g_path_open := TRUE;
    END;


    PROCEDURE add_curve(
        p_cx1 NUMBER, p_cy1 NUMBER,
        p_cx2 NUMBER, p_cy2 NUMBER,
        p_x   NUMBER, p_y   NUMBER
    ) IS
    BEGIN
        IF NOT g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'add_curve exige um caminho aberto; chame begin_path primeiro.');
        END IF;
        IF p_cx1 IS NULL OR p_cy1 IS NULL OR p_cx2 IS NULL OR p_cy2 IS NULL
           OR p_x IS NULL OR p_y IS NULL
        THEN
            RAISE_APPLICATION_ERROR(-20086, 'add_curve exige seis coordenadas numéricas.');
        END IF;
        IF p_cx1 < 0 OR p_cx1 > g_page_width OR p_cx2 < 0 OR p_cx2 > g_page_width
           OR p_x < 0 OR p_x > g_page_width OR p_cy1 < 0 OR p_cy1 > g_page_height
           OR p_cy2 < 0 OR p_cy2 > g_page_height OR p_y < 0 OR p_y > g_page_height
        THEN
            RAISE_APPLICATION_ERROR(-20086, 'Os pontos de controle e o destino de add_curve devem estar dentro da página.');
        END IF;
        append_page(
            fmt_num(p_cx1) || ' ' || fmt_num(p_cy1) || ' ' ||
            fmt_num(p_cx2) || ' ' || fmt_num(p_cy2) || ' ' ||
            fmt_num(p_x) || ' ' || fmt_num(p_y) || ' c' || CHR(10)
        );
    END;

    ----------------------------------------------------------------------------

    PROCEDURE add_line_to(
        p_x NUMBER,
        p_y NUMBER
    ) IS
    BEGIN
        IF NOT g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'add_line_to exige um caminho aberto; chame begin_path primeiro.');
        END IF;
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20084, 'add_line_to exige coordenadas X e Y.');
        END IF;
        IF p_x < 0 OR p_x > g_page_width OR p_y < 0 OR p_y > g_page_height THEN
            RAISE_APPLICATION_ERROR(-20084, 'add_line_to deve permanecer dentro dos limites da página.');
        END IF;
        append_page(fmt_num(p_x) || ' ' || fmt_num(p_y) || ' l' || CHR(10));
    END;

    ----------------------------------------------------------------------------

    PROCEDURE close_path IS
    BEGIN
        IF NOT g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'close_path exige um caminho aberto; chame begin_path primeiro.');
        END IF;
        append_page('h' || CHR(10));
    END;

    ----------------------------------------------------------------------------

    PROCEDURE stroke_path IS
    BEGIN
        IF NOT g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'stroke_path exige um caminho aberto; chame begin_path primeiro.');
        END IF;
        append_page('S' || CHR(10));
        g_path_open := FALSE;
    END;

    ----------------------------------------------------------------------------

    PROCEDURE fill_path IS
    BEGIN
        IF NOT g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'fill_path exige um caminho aberto; chame begin_path primeiro.');
        END IF;
        append_page('f' || CHR(10));
        g_path_open := FALSE;
    END;

    ----------------------------------------------------------------------------
    -- utilitário para ler dimensões de um JPEG em BLOB
    ----------------------------------------------------------------------------
    FUNCTION jpeg_u16(p_raw RAW) RETURN NUMBER IS
    BEGIN
        IF p_raw IS NULL OR UTL_RAW.LENGTH(p_raw) <> 2 THEN
            RAISE_APPLICATION_ERROR(-20014, 'Campo JPEG de 16 bits inválido.');
        END IF;

        RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(
            HEXTORAW('0000' || RAWTOHEX(p_raw)),
            UTL_RAW.BIG_ENDIAN
        );
    END;

    PROCEDURE get_jpeg_dims(
        p_blob       IN BLOB,
        p_width      OUT NUMBER,
        p_height     OUT NUMBER,
        p_components OUT NUMBER,
        p_precision  OUT NUMBER
    ) IS
        l_offset  NUMBER := 3;
        l_len     NUMBER;
        l_raw     RAW(4);
        l_marker  NUMBER;
        l_seg_len NUMBER;
        l_is_sof  BOOLEAN;
    BEGIN
        IF p_blob IS NULL THEN
            RAISE_APPLICATION_ERROR(-20004, 'O BLOB JPEG não pode ser NULL.');
        END IF;

        l_len := DBMS_LOB.GETLENGTH(p_blob);
        IF l_len < 4 OR RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 2, 1)) <> 'FFD8' THEN
            RAISE_APPLICATION_ERROR(-20005, 'Cabeçalho JPEG inválido.');
        END IF;

        WHILE l_offset <= l_len LOOP
            l_raw := DBMS_LOB.SUBSTR(p_blob, 1, l_offset);
            IF RAWTOHEX(l_raw) <> 'FF' THEN
                RAISE_APPLICATION_ERROR(-20006, 'Marcador JPEG inválido.');
            END IF;

            -- Consome os bytes FF repetidos (fill bytes) antes do código do marcador.
            WHILE l_offset <= l_len
              AND DBMS_LOB.SUBSTR(p_blob, 1, l_offset) = HEXTORAW('FF')
            LOOP
                l_offset := l_offset + 1;
            END LOOP;
            IF l_offset > l_len THEN
                RAISE_APPLICATION_ERROR(-20007, 'Marcador JPEG truncado.');
            END IF;

            l_raw := DBMS_LOB.SUBSTR(p_blob, 1, l_offset);
            l_marker := jpeg_u16(HEXTORAW('FF' || RAWTOHEX(l_raw)));
            l_offset := l_offset + 1;

            IF l_marker = 65498 OR l_marker = 65497 THEN
                EXIT;
            ELSIF l_marker = 65281 OR l_marker BETWEEN 65488 AND 65495 THEN
                NULL; -- TEM e marcadores restart não têm campo de comprimento.
            ELSE
                IF l_offset + 1 > l_len THEN
                    RAISE_APPLICATION_ERROR(-20007, 'Segmento JPEG truncado.');
                END IF;

                l_raw := DBMS_LOB.SUBSTR(p_blob, 2, l_offset);
                l_seg_len := jpeg_u16(l_raw);
                IF l_seg_len < 2 OR l_offset + l_seg_len - 1 > l_len THEN
                    RAISE_APPLICATION_ERROR(-20008, 'Comprimento de segmento JPEG inválido.');
                END IF;

                l_is_sof :=
                       l_marker BETWEEN 65472 AND 65475
                    OR l_marker BETWEEN 65477 AND 65479
                    OR l_marker BETWEEN 65481 AND 65483
                    OR l_marker BETWEEN 65485 AND 65487;

                IF l_is_sof THEN
                    IF l_seg_len < 8 THEN
                        RAISE_APPLICATION_ERROR(-20009, 'Segmento SOF JPEG inválido.');
                    END IF;

                    l_raw := DBMS_LOB.SUBSTR(p_blob, 2, l_offset + 3);
                    p_height := jpeg_u16(l_raw);
                    l_raw := DBMS_LOB.SUBSTR(p_blob, 2, l_offset + 5);
                    p_width := jpeg_u16(l_raw);
                    l_raw := DBMS_LOB.SUBSTR(p_blob, 1, l_offset + 2);
                    p_precision := UTL_RAW.CAST_TO_BINARY_INTEGER(
                        HEXTORAW('000000' || RAWTOHEX(l_raw)), UTL_RAW.BIG_ENDIAN
                    );
                    l_raw := DBMS_LOB.SUBSTR(p_blob, 1, l_offset + 7);
                    p_components := UTL_RAW.CAST_TO_BINARY_INTEGER(
                        HEXTORAW('000000' || RAWTOHEX(l_raw)), UTL_RAW.BIG_ENDIAN
                    );

                    IF l_seg_len < 8 + 3 * p_components THEN
                        RAISE_APPLICATION_ERROR(-20009, 'Segmento SOF JPEG incompleto.');
                    END IF;
                    IF p_width <= 0 OR p_height <= 0 THEN
                        RAISE_APPLICATION_ERROR(-20010, 'Dimensões JPEG inválidas.');
                    END IF;
                    RETURN;
                END IF;

                l_offset := l_offset + l_seg_len;
            END IF;
        END LOOP;

        RAISE_APPLICATION_ERROR(-20011, 'Não foram encontradas dimensões SOF no JPEG.');
    END;

    FUNCTION raw_byte_num(p_raw RAW) RETURN NUMBER IS
    BEGIN
        IF p_raw IS NULL OR UTL_RAW.LENGTH(p_raw) <> 1 THEN
            RAISE_APPLICATION_ERROR(-20033, 'Byte inválido no cabeçalho da imagem.');
        END IF;

        RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(
            HEXTORAW('000000' || RAWTOHEX(p_raw)),
            UTL_RAW.BIG_ENDIAN
        );
    END;

    FUNCTION png_u32(p_blob BLOB, p_offset NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, p_offset)) * 16777216
             + raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, p_offset + 1)) * 65536
             + raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, p_offset + 2)) * 256
             + raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, p_offset + 3));
    END;

    PROCEDURE extract_png_data(
        p_blob       IN BLOB,
        p_width      OUT NUMBER,
        p_height     OUT NUMBER,
        p_components OUT NUMBER,
        p_image_data OUT BLOB,
        p_bits_per_component OUT NUMBER,
        p_palette_hex OUT VARCHAR2,
        p_palette_entries OUT NUMBER,
        p_mask_values OUT VARCHAR2
    ) IS
        l_len          NUMBER;
        l_offset       NUMBER := 9;
        l_chunk_len    NUMBER;
        l_data_offset  NUMBER;
        l_dest_offset  NUMBER := 1;
        l_bit_depth    NUMBER;
        l_color_type   NUMBER;
        l_interlace    NUMBER;
        l_seen_ihdr    BOOLEAN := FALSE;
        l_seen_idat    BOOLEAN := FALSE;
        l_seen_iend    BOOLEAN := FALSE;
        l_idat_ended   BOOLEAN := FALSE;
        l_seen_plte    BOOLEAN := FALSE;
        l_seen_trns    BOOLEAN := FALSE;
        l_chunk_type   VARCHAR2(8);
        l_palette_raw  RAW(768);
        l_transparency PLS_INTEGER;
        l_palette_alpha PLS_INTEGER;
        l_sample       NUMBER;
        l_mask_text    VARCHAR2(1000);
        l_seen_opaque  BOOLEAN;
    BEGIN
        p_palette_hex := NULL;
        p_palette_entries := NULL;
        p_mask_values := NULL;
        IF p_blob IS NULL OR DBMS_LOB.GETLENGTH(p_blob) < 8
           OR RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 8, 1)) <> '89504E470D0A1A0A'
        THEN
            RAISE_APPLICATION_ERROR(-20034, 'Assinatura PNG inválida.');
        END IF;

        l_len := DBMS_LOB.GETLENGTH(p_blob);
        DBMS_LOB.CREATETEMPORARY(p_image_data, TRUE);

        WHILE l_offset + 11 <= l_len LOOP
            l_chunk_len := png_u32(p_blob, l_offset);
            l_chunk_type := RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 4, l_offset + 4));
            l_data_offset := l_offset + 8;

            IF l_seen_idat AND l_chunk_type NOT IN ('49444154', '49454E44') THEN
                l_idat_ended := TRUE;
            END IF;

            IF l_chunk_len > l_len OR l_data_offset + l_chunk_len + 3 > l_len THEN
                RAISE_APPLICATION_ERROR(-20035, 'Chunk PNG truncado.');
            END IF;

            IF l_chunk_type = '49484452' THEN -- IHDR
                IF l_seen_ihdr OR l_chunk_len <> 13 OR l_offset <> 9 THEN
                    RAISE_APPLICATION_ERROR(-20036, 'Cabeçalho IHDR PNG inválido.');
                END IF;

                p_width := png_u32(p_blob, l_data_offset);
                p_height := png_u32(p_blob, l_data_offset + 4);
                l_bit_depth := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 8));
                l_color_type := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 9));
                l_interlace := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 12));

                IF p_width <= 0 OR p_height <= 0 OR l_interlace <> 0 THEN
                    RAISE_APPLICATION_ERROR(-20037, 'PNG deve ter dimensões válidas e não ser entrelaçado.');
                END IF;
                IF l_color_type IN (4, 6) THEN
                    RAISE_APPLICATION_ERROR(-20038, 'PNG com canal alpha explícito (grayscale+alpha/RGBA) não é suportado; use PNG RGB/grayscale com tRNS binário.');
                END IF;
                IF l_color_type = 0 THEN
                    IF l_bit_depth <> 8 THEN
                        RAISE_APPLICATION_ERROR(-20037, 'PNG grayscale deve usar 8 bits por componente.');
                    END IF;
                    p_components := 1;
                ELSIF l_color_type = 2 THEN
                    IF l_bit_depth <> 8 THEN
                        RAISE_APPLICATION_ERROR(-20037, 'PNG RGB deve usar 8 bits por componente.');
                    END IF;
                    p_components := 3;
                ELSIF l_color_type = 3 AND l_bit_depth IN (1, 2, 4, 8) THEN
                    p_components := 1;
                ELSE
                    RAISE_APPLICATION_ERROR(-20038, 'PNG suportado em grayscale/RGB de 8 bits ou paleta indexada de 1, 2, 4 ou 8 bits; canal alpha não é suportado.');
                END IF;
                p_bits_per_component := l_bit_depth;
                IF raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 10)) <> 0
                   OR raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 11)) <> 0
                THEN
                    RAISE_APPLICATION_ERROR(-20039, 'Métodos de compressão ou filtro PNG não suportados.');
                END IF;
                l_seen_ihdr := TRUE;
            ELSIF l_chunk_type = '504C5445' THEN -- PLTE
                IF NOT l_seen_ihdr OR l_seen_plte OR l_seen_idat
                   OR l_chunk_len = 0 OR l_chunk_len > 768 OR MOD(l_chunk_len, 3) <> 0
                         OR l_color_type = 0
                THEN
                    RAISE_APPLICATION_ERROR(-20038, 'Chunk PLTE ausente, duplicado ou inválido.');
                END IF;
                IF l_color_type = 3 THEN
                    p_palette_entries := l_chunk_len / 3;
                    IF p_palette_entries > POWER(2, l_bit_depth) THEN
                        RAISE_APPLICATION_ERROR(-20038, 'A paleta PNG excede a profundidade de bits dos índices.');
                    END IF;
                    l_palette_raw := DBMS_LOB.SUBSTR(p_blob, l_chunk_len, l_data_offset);
                    p_palette_hex := RAWTOHEX(l_palette_raw);
                END IF;
                l_seen_plte := TRUE;
            ELSIF l_chunk_type = '74524E53' THEN -- tRNS
                IF NOT l_seen_ihdr OR l_seen_trns OR l_seen_idat THEN
                    RAISE_APPLICATION_ERROR(-20044, 'Chunk tRNS duplicado ou em posição inválida.');
                END IF;
                IF l_color_type = 0 AND l_chunk_len = 2 THEN
                    l_sample := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset)) * 256
                                + raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + 1));
                    IF l_sample > 255 THEN
                        RAISE_APPLICATION_ERROR(-20044, 'Valor transparente tRNS grayscale fora do intervalo de 8 bits.');
                    END IF;
                    p_mask_values := '[' || TO_CHAR(l_sample, 'FM9990') || ' ' || TO_CHAR(l_sample, 'FM9990') || ']';
                ELSIF l_color_type = 2 AND l_chunk_len = 6 THEN
                    l_mask_text := '[';
                    FOR i IN 0 .. 2 LOOP
                        l_sample := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + i * 2)) * 256
                                    + raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + i * 2 + 1));
                        IF l_sample > 255 THEN
                            RAISE_APPLICATION_ERROR(-20044, 'Valor transparente tRNS RGB fora do intervalo de 8 bits.');
                        END IF;
                        l_mask_text := l_mask_text || TO_CHAR(l_sample, 'FM9990') || ' ' || TO_CHAR(l_sample, 'FM9990') ||
                                       CASE WHEN i < 2 THEN ' ' ELSE '' END;
                    END LOOP;
                    p_mask_values := l_mask_text || ']';
                ELSIF l_color_type = 3 AND l_seen_plte AND l_chunk_len > 0
                      AND l_chunk_len <= p_palette_entries
                THEN
                    l_transparency := 0;
                    l_seen_opaque := FALSE;
                    FOR i IN 0 .. l_chunk_len - 1 LOOP
                        l_palette_alpha := raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_data_offset + i));
                        IF l_palette_alpha = 0 THEN
                            IF l_seen_opaque THEN
                                RAISE_APPLICATION_ERROR(-20044, 'Índices transparentes da paleta PNG devem formar um prefixo contíguo.');
                            END IF;
                            l_transparency := l_transparency + 1;
                        ELSIF l_palette_alpha = 255 THEN
                            l_seen_opaque := TRUE;
                        ELSE
                            RAISE_APPLICATION_ERROR(-20044, 'Paleta PNG com alpha parcial; são aceitos somente alpha 0 ou 255.');
                        END IF;
                    END LOOP;
                    IF l_transparency > 0 THEN
                        p_mask_values := '[0 ' || TO_CHAR(l_transparency - 1, 'FM9990') || ']';
                    END IF;
                ELSE
                    RAISE_APPLICATION_ERROR(-20044, 'Chunk tRNS incompatível com o tipo de cor PNG ou com suporte binário.');
                END IF;
                l_seen_trns := TRUE;
            ELSIF l_chunk_type = '49444154' THEN -- IDAT
                IF NOT l_seen_ihdr OR l_seen_iend OR l_idat_ended THEN
                    RAISE_APPLICATION_ERROR(-20040, 'Ordem de chunks PNG inválida.');
                END IF;
                IF l_color_type = 3 AND NOT l_seen_plte THEN
                    RAISE_APPLICATION_ERROR(-20038, 'PNG indexado exige chunk PLTE antes de IDAT.');
                END IF;
                IF l_chunk_len > 0 THEN
                    DBMS_LOB.COPY(
                        p_image_data,
                        p_blob,
                        l_chunk_len,
                        l_dest_offset,
                        l_data_offset
                    );
                    l_dest_offset := l_dest_offset + l_chunk_len;
                END IF;
                l_seen_idat := TRUE;
            ELSIF l_chunk_type = '49454E44' THEN -- IEND
                IF l_chunk_len <> 0 THEN
                    RAISE_APPLICATION_ERROR(-20041, 'Chunk IEND PNG inválido.');
                END IF;
                l_seen_iend := TRUE;
                EXIT;
            ELSIF l_chunk_type = '6163544C' THEN -- acTL
                RAISE_APPLICATION_ERROR(-20045, 'PNG animado (APNG) não é suportado.');
            ELSE
                IF raw_byte_num(DBMS_LOB.SUBSTR(p_blob, 1, l_offset + 4)) BETWEEN 65 AND 90
                   AND l_chunk_type <> '504C5445'
                THEN
                    RAISE_APPLICATION_ERROR(-20046, 'Chunk crítico PNG não suportado.');
                END IF;
            END IF;

            l_offset := l_offset + l_chunk_len + 12;
        END LOOP;

        IF NOT l_seen_ihdr OR NOT l_seen_idat OR NOT l_seen_iend
           OR DBMS_LOB.GETLENGTH(p_image_data) = 0
              OR (l_color_type = 3 AND NOT l_seen_plte)
        THEN
            RAISE_APPLICATION_ERROR(-20042, 'PNG incompleto ou sem dados IDAT.');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF p_image_data IS NOT NULL AND DBMS_LOB.ISTEMPORARY(p_image_data) = 1 THEN
                DBMS_LOB.FREETEMPORARY(p_image_data);
            END IF;
            RAISE;
    END;

    ----------------------------------------------------------------------------
    -- Inclusão de Imagem
    ----------------------------------------------------------------------------

    PROCEDURE add_image(
        p_image_blob IN BLOB,
        p_x          NUMBER,
        p_y          NUMBER,
        p_width      NUMBER,
        p_height     NUMBER,
        p_scale      NUMBER,
        p_text_align VARCHAR2,
        p_text_size  NUMBER
    ) IS
        l_pixel_w    NUMBER;
        l_pixel_h    NUMBER;
        l_components NUMBER;
        l_precision  NUMBER;
        l_draw_w     NUMBER;
        l_draw_h     NUMBER;
        l_draw_y     NUMBER;
        l_image_no   PLS_INTEGER;
        l_format     VARCHAR2(4);
        l_image_data BLOB;
        l_palette_hex VARCHAR2(1536);
        l_palette_entries NUMBER;
        l_mask_values VARCHAR2(1000);
    BEGIN
        IF p_image_blob IS NULL OR DBMS_LOB.GETLENGTH(p_image_blob) = 0 THEN
            RAISE_APPLICATION_ERROR(-20012, 'A imagem está vazia.');
        END IF;
        IF g_current_page < 1 OR NOT g_pages.EXISTS(g_current_page) THEN
            RAISE_APPLICATION_ERROR(-20021, 'Chame new_document antes de adicionar imagens.');
        END IF;
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial antes de adicionar uma imagem.');
        END IF;
        IF p_x IS NULL OR p_y IS NULL THEN
            RAISE_APPLICATION_ERROR(-20022, 'As coordenadas da imagem não podem ser NULL.');
        END IF;
        IF (p_width IS NOT NULL AND p_width < 0)
           OR (p_height IS NOT NULL AND p_height < 0)
        THEN
            RAISE_APPLICATION_ERROR(-20013, 'Largura e altura da imagem devem ser não negativas; use 0 para cálculo automático.');
        END IF;
        IF p_scale IS NOT NULL AND p_scale <= 0 THEN
            RAISE_APPLICATION_ERROR(-20013, 'A escala da imagem deve ser positiva.');
        END IF;
        IF p_scale IS NOT NULL AND (NVL(p_width, 0) <> 0 OR NVL(p_height, 0) <> 0) THEN
            RAISE_APPLICATION_ERROR(-20013, 'Use p_scale ou p_width/p_height, não ambos.');
        END IF;
        IF p_text_align IS NULL OR UPPER(TRIM(p_text_align)) NOT IN ('B', 'T', 'M') THEN
            RAISE_APPLICATION_ERROR(-20013, 'Alinhamento à linha de texto inválido; use B, T ou M.');
        END IF;
        IF p_text_size IS NULL OR p_text_size <= 0 THEN
            RAISE_APPLICATION_ERROR(-20013, 'O tamanho da linha de texto deve ser positivo.');
        END IF;

        IF RAWTOHEX(DBMS_LOB.SUBSTR(p_image_blob, 2, 1)) = 'FFD8' THEN
            get_jpeg_dims(p_image_blob, l_pixel_w, l_pixel_h, l_components, l_precision);
            IF l_components <> 3 OR l_precision <> 8 THEN
                RAISE_APPLICATION_ERROR(-20023, 'JPEG suportado apenas em RGB de 8 bits e três componentes.');
            END IF;
            l_format := 'JPEG';
            DBMS_LOB.CREATETEMPORARY(l_image_data, TRUE);
            DBMS_LOB.COPY(l_image_data, p_image_blob, DBMS_LOB.GETLENGTH(p_image_blob), 1, 1);
        ELSIF RAWTOHEX(DBMS_LOB.SUBSTR(p_image_blob, 8, 1)) = '89504E470D0A1A0A' THEN
            extract_png_data(
                p_image_blob, l_pixel_w, l_pixel_h, l_components, l_image_data,
                l_precision, l_palette_hex, l_palette_entries, l_mask_values
            );
            l_format := 'PNG';
        ELSE
            RAISE_APPLICATION_ERROR(-20043, 'Formato não suportado. Use JPEG RGB8 ou PNG grayscale/RGB8/indexado sem canal alpha nem entrelaçamento.');
        END IF;

        IF p_scale IS NOT NULL THEN
            l_draw_w := l_pixel_w * p_scale;
            l_draw_h := l_pixel_h * p_scale;
        ELSIF p_width IS NULL OR p_width = 0 THEN
            IF p_height IS NULL OR p_height = 0 THEN
                l_draw_w := l_pixel_w;
                l_draw_h := l_pixel_h;
            ELSE
                l_draw_h := p_height;
                l_draw_w := p_height * l_pixel_w / l_pixel_h;
            END IF;
        ELSIF p_height IS NULL OR p_height = 0 THEN
            l_draw_w := p_width;
            l_draw_h := p_width * l_pixel_h / l_pixel_w;
        ELSE
            l_draw_w := p_width;
            l_draw_h := p_height;
        END IF;
        IF l_draw_w <= 0 OR l_draw_h <= 0 THEN
            RAISE_APPLICATION_ERROR(-20013, 'Largura e altura devem ser positivas.');
        END IF;
        l_draw_y := p_y;
        IF UPPER(TRIM(p_text_align)) = 'T' THEN
            l_draw_y := p_y + p_text_size - l_draw_h;
        ELSIF UPPER(TRIM(p_text_align)) = 'M' THEN
            l_draw_y := p_y + (p_text_size - l_draw_h) / 2;
        END IF;
        IF p_x < 0 OR p_x + l_draw_w > g_page_width
           OR l_draw_y < 0 OR l_draw_y + l_draw_h > g_page_height
        THEN
            RAISE_APPLICATION_ERROR(-20089, 'A imagem posicionada ultrapassa os limites da página.');
        END IF;

        g_image_count := g_image_count + 1;
        l_image_no := g_image_count;
        BEGIN
            g_images(l_image_no).blob_data := l_image_data;
            l_image_data := NULL;
            g_images(l_image_no).filter_name :=
                CASE l_format WHEN 'JPEG' THEN 'DCTDecode' ELSE 'FlateDecode' END;
            g_images(l_image_no).color_components := l_components;
            g_images(l_image_no).bits_per_component := l_precision;
            g_images(l_image_no).page_no := g_current_page;
            g_images(l_image_no).x := p_x;
            g_images(l_image_no).y := p_y;
            g_images(l_image_no).width := l_draw_w;
            g_images(l_image_no).height := l_draw_h;
            g_images(l_image_no).pixel_width := l_pixel_w;
            g_images(l_image_no).pixel_height := l_pixel_h;
            g_images(l_image_no).palette_hex := l_palette_hex;
            g_images(l_image_no).palette_entries := l_palette_entries;
            g_images(l_image_no).mask_values := l_mask_values;

            append_page(
                'q' || CHR(10) ||
                fmt_num(l_draw_w) || ' 0 0 ' || fmt_num(l_draw_h) || ' ' ||
                fmt_num(p_x) || ' ' || fmt_num(l_draw_y) || ' cm' || CHR(10) ||
                '/Im' || fmt_num(l_image_no) || ' Do' || CHR(10) ||
                'Q' || CHR(10)
            );
        EXCEPTION
            WHEN OTHERS THEN
                IF l_image_data IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_image_data) = 1 THEN
                    DBMS_LOB.FREETEMPORARY(l_image_data);
                END IF;
                IF g_images.EXISTS(l_image_no)
                   AND g_images(l_image_no).blob_data IS NOT NULL
                   AND DBMS_LOB.ISTEMPORARY(g_images(l_image_no).blob_data) = 1
                THEN
                    DBMS_LOB.FREETEMPORARY(g_images(l_image_no).blob_data);
                END IF;
                g_images.DELETE(l_image_no);
                g_image_count := g_image_count - 1;
                RAISE;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            IF l_image_data IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_image_data) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_image_data);
            END IF;
            RAISE;
    END;

    ----------------------------------------------------------------------------
    -- geração do pdf
    ----------------------------------------------------------------------------

    FUNCTION generate
    RETURN BLOB
    IS
        l_pdf BLOB;

        TYPE t_num IS TABLE OF NUMBER
        INDEX BY PLS_INTEGER;
        l_img_objs      t_num;
        l_page_objs     t_num;
        l_stream_objs   t_num;
        l_font_objs     t_num;
        l_catalog_obj   NUMBER;
        l_pages_obj     NUMBER;
        l_info_obj      NUMBER;
        l_metadata_active BOOLEAN := g_metadata_title IS NOT NULL
                      OR g_metadata_author IS NOT NULL
                      OR g_metadata_subject IS NOT NULL
                      OR g_metadata_keywords IS NOT NULL;
        l_xref_pos      NUMBER;
        l_pages_kids    VARCHAR2(32767);
        l_xobjects_str  VARCHAR2(32767);
        l_page_blob     BLOB;
        l_page_len      NUMBER;
        l_image_len     NUMBER;
        l_base_font     VARCHAR2(40);
        l_unicode_active BOOLEAN := g_unicode_font_blob IS NOT NULL;
        l_unicode_type0_obj NUMBER;
        l_unicode_cidfont_obj NUMBER;
        l_unicode_descriptor_obj NUMBER;
        l_unicode_file_obj NUMBER;
        l_unicode_map_obj NUMBER;
        l_unicode_tounicode_obj NUMBER;
        l_unicode_map BLOB;
        l_unicode_cmap CLOB;
        l_unicode_map_length NUMBER;
        l_zero_raw RAW(32767);
        l_zero_amount PLS_INTEGER;
        l_write_amount PLS_INTEGER;
        l_write_offset PLS_INTEGER;
        l_remaining NUMBER;
        l_cid PLS_INTEGER;
        l_glyph PLS_INTEGER;
        l_used_count PLS_INTEGER;
        l_block_count PLS_INTEGER;
        l_index PLS_INTEGER;
        l_cmap_line VARCHAR2(200);
        l_font_scaled_bbox VARCHAR2(300);
        l_raw_glyph RAW(2);

        PROCEDURE allocate_obj(p_obj_no OUT NUMBER) IS
        BEGIN
            g_obj_count := g_obj_count + 1;
            p_obj_no := g_obj_count;
        END;

        PROCEDURE start_obj(p_obj_no NUMBER) IS
        BEGIN
            g_offsets(p_obj_no) := DBMS_LOB.GETLENGTH(l_pdf);
            write_blob(l_pdf, fmt_num(p_obj_no) || ' 0 obj' || CHR(10));
        END;

        PROCEDURE end_obj IS
        BEGIN
            write_blob(l_pdf, 'endobj' || CHR(10));
        END;

        PROCEDURE append_cmap(p_text VARCHAR2) IS
        BEGIN
            DBMS_LOB.WRITEAPPEND(l_unicode_cmap, LENGTH(p_text), p_text);
        END;

        FUNCTION scale_font_metric(p_value NUMBER) RETURN NUMBER IS
        BEGIN
            RETURN ROUND(p_value * 1000 / g_unicode_units_per_em);
        END;
    BEGIN
        IF g_page_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20028, 'Crie ao menos uma página com new_document antes de gerar o PDF.');
        END IF;
        IF g_path_open THEN
            RAISE_APPLICATION_ERROR(-20085, 'Finalize o caminho vetorial com stroke_path ou fill_path antes de generate.');
        END IF;

        IF g_pending_cell_count > 0 THEN
            place_pending_row(g_table_row_height, FALSE);
        END IF;

        g_offsets.DELETE;
        g_obj_count := 0;

        allocate_obj(l_catalog_obj);
        allocate_obj(l_pages_obj);
        IF l_metadata_active THEN
            allocate_obj(l_info_obj);
        END IF;

        FOR i IN 1 .. g_page_count LOOP
            allocate_obj(l_page_objs(i));
            allocate_obj(l_stream_objs(i));

            IF NVL(LENGTH(l_pages_kids), 0) + LENGTH(fmt_num(l_page_objs(i))) + 5 > 32000 THEN
                RAISE_APPLICATION_ERROR(-20025, 'O documento excede o limite suportado de páginas.');
            END IF;
            l_pages_kids := l_pages_kids || fmt_num(l_page_objs(i)) || ' 0 R ';
        END LOOP;

        FOR i IN 1 .. 4 LOOP
            allocate_obj(l_font_objs(i));
        END LOOP;

        IF l_unicode_active THEN
            allocate_obj(l_unicode_type0_obj);
            allocate_obj(l_unicode_cidfont_obj);
            allocate_obj(l_unicode_descriptor_obj);
            allocate_obj(l_unicode_file_obj);
            allocate_obj(l_unicode_map_obj);
            allocate_obj(l_unicode_tounicode_obj);

            l_cid := NVL(g_unicode_used_glyphs.LAST, 0);
            l_unicode_map_length := (l_cid + 1) * 2;
            DBMS_LOB.CREATETEMPORARY(l_unicode_map, TRUE);
            l_zero_raw := HEXTORAW(RPAD('00', 16384, '0'));
            l_remaining := l_unicode_map_length;
            WHILE l_remaining > 0 LOOP
                l_zero_amount := LEAST(l_remaining, 8192);
                DBMS_LOB.WRITEAPPEND(
                    l_unicode_map,
                    l_zero_amount,
                    UTL_RAW.SUBSTR(l_zero_raw, 1, l_zero_amount)
                );
                l_remaining := l_remaining - l_zero_amount;
            END LOOP;

            l_cid := g_unicode_used_glyphs.FIRST;
            WHILE l_cid IS NOT NULL LOOP
                l_glyph := g_unicode_used_glyphs(l_cid);
                l_raw_glyph := HEXTORAW(unicode_hex4(l_glyph));
                l_write_amount := 2;
                l_write_offset := l_cid * 2 + 1;
                DBMS_LOB.WRITE(
                    lob_loc => l_unicode_map,
                    amount => l_write_amount,
                    buffer => l_raw_glyph,
                    offset => l_write_offset
                );
                l_cid := g_unicode_used_glyphs.NEXT(l_cid);
            END LOOP;

            DBMS_LOB.CREATETEMPORARY(l_unicode_cmap, TRUE);
            append_cmap('/CIDInit /ProcSet findresource begin' || CHR(10));
            append_cmap('12 dict begin' || CHR(10));
            append_cmap('begincmap' || CHR(10));
            append_cmap('/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def' || CHR(10));
            append_cmap('/CMapName /PDFGen-ToUnicode def' || CHR(10));
            append_cmap('/CMapType 2 def' || CHR(10));
            append_cmap('1 begincodespacerange <0000> <FFFF> endcodespacerange' || CHR(10));
            l_used_count := g_unicode_used_glyphs.COUNT;
            l_cid := g_unicode_used_glyphs.FIRST;
            WHILE l_cid IS NOT NULL LOOP
                l_block_count := LEAST(100, l_used_count);
                append_cmap(fmt_num(l_block_count) || ' beginbfchar' || CHR(10));
                FOR i IN 1 .. l_block_count LOOP
                    append_cmap('<' || unicode_hex4(l_cid) || '> <' || unicode_hex4(l_cid) || '>' || CHR(10));
                    l_cid := g_unicode_used_glyphs.NEXT(l_cid);
                END LOOP;
                append_cmap('endbfchar' || CHR(10));
                l_used_count := l_used_count - l_block_count;
            END LOOP;
            append_cmap('endcmap' || CHR(10));
            append_cmap('CMapName currentdict /CMap defineresource pop' || CHR(10));
            append_cmap('end' || CHR(10) || 'end' || CHR(10));
        END IF;

        FOR i IN 1 .. g_image_count LOOP
            allocate_obj(l_img_objs(i));
        END LOOP;

        DBMS_LOB.CREATETEMPORARY(l_pdf, TRUE);
        write_blob(l_pdf, '%PDF-1.4' || CHR(10));

        start_obj(l_catalog_obj);
        write_blob(
            l_pdf,
            '<<' || CHR(10) ||
            '/Type /Catalog' || CHR(10) ||
            '/Pages ' || fmt_num(l_pages_obj) || ' 0 R' || CHR(10) ||
            '>>' || CHR(10)
        );
        end_obj;

        start_obj(l_pages_obj);
        write_blob(
            l_pdf,
            '<<' || CHR(10) ||
            '/Type /Pages' || CHR(10) ||
            '/Count ' || fmt_num(g_page_count) || CHR(10) ||
            '/Kids [' || l_pages_kids || ']' || CHR(10) ||
            '>>' || CHR(10)
        );
        end_obj;

        FOR i IN 1 .. g_image_count LOOP
            start_obj(l_img_objs(i));
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /XObject' || CHR(10) ||
                '/Subtype /Image' || CHR(10) ||
                '/Width ' || fmt_num(g_images(i).pixel_width) || CHR(10) ||
                '/Height ' || fmt_num(g_images(i).pixel_height) || CHR(10) ||
                '/ColorSpace ' || CASE
                    WHEN g_images(i).palette_entries IS NOT NULL THEN
                        '[/Indexed /DeviceRGB ' || fmt_num(g_images(i).palette_entries - 1) ||
                        ' <' || g_images(i).palette_hex || '>]'
                    WHEN g_images(i).color_components = 1 THEN '/DeviceGray'
                    ELSE '/DeviceRGB'
                END || CHR(10) ||
                '/BitsPerComponent ' || fmt_num(g_images(i).bits_per_component) || CHR(10) ||
                CASE WHEN g_images(i).mask_values IS NOT NULL THEN '/Mask ' || g_images(i).mask_values || CHR(10) ELSE '' END ||
                '/Filter /' || g_images(i).filter_name || CHR(10) ||
                CASE WHEN g_images(i).filter_name = 'FlateDecode' THEN
                    '/DecodeParms << /Predictor 15 /Colors ' || fmt_num(g_images(i).color_components) ||
                    ' /BitsPerComponent ' || fmt_num(g_images(i).bits_per_component) ||
                    ' /Columns ' || fmt_num(g_images(i).pixel_width) || ' >>' || CHR(10)
                ELSE '' END ||
                '/Length ' || fmt_num(DBMS_LOB.GETLENGTH(g_images(i).blob_data)) || CHR(10) ||
                '>>' || CHR(10) ||
                'stream' || CHR(10)
            );
            l_image_len := DBMS_LOB.GETLENGTH(g_images(i).blob_data);
            IF l_image_len > 0 THEN
                DBMS_LOB.COPY(
                    l_pdf,
                    g_images(i).blob_data,
                    l_image_len,
                    DBMS_LOB.GETLENGTH(l_pdf) + 1,
                    1
                );
            END IF;
            write_blob(l_pdf, CHR(10) || 'endstream' || CHR(10));
            end_obj;
        END LOOP;

        FOR i IN 1 .. g_page_count LOOP
            l_xobjects_str := NULL;
            FOR idx IN 1 .. g_image_count LOOP
                IF g_images(idx).page_no = i THEN
                    IF NVL(LENGTH(l_xobjects_str), 0) + LENGTH(fmt_num(idx)) + LENGTH(fmt_num(l_img_objs(idx))) + 10 > 32000 THEN
                        RAISE_APPLICATION_ERROR(-20026, 'A página excede o limite suportado de imagens.');
                    END IF;
                    l_xobjects_str := l_xobjects_str || '/Im' || fmt_num(idx) || ' ' || fmt_num(l_img_objs(idx)) || ' 0 R ';
                END IF;
            END LOOP;

            start_obj(l_page_objs(i));
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /Page' || CHR(10) ||
                '/Parent ' || fmt_num(l_pages_obj) || ' 0 R' || CHR(10) ||
                '/MediaBox [0 0 ' || fmt_num(g_document_page_width) || ' ' || fmt_num(g_document_page_height) || ']' || CHR(10) ||
                '/Resources <<' || CHR(10) ||
                '/Font <<' || CHR(10) ||
                '/F1 ' || fmt_num(l_font_objs(1)) || ' 0 R' || CHR(10) ||
                '/F2 ' || fmt_num(l_font_objs(2)) || ' 0 R' || CHR(10) ||
                '/F3 ' || fmt_num(l_font_objs(3)) || ' 0 R' || CHR(10) ||
                '/F4 ' || fmt_num(l_font_objs(4)) || ' 0 R' || CHR(10) ||
                CASE WHEN l_unicode_active THEN
                    '/F5 ' || fmt_num(l_unicode_type0_obj) || ' 0 R' || CHR(10)
                ELSE '' END ||
                '>>' || CHR(10) ||
                CASE WHEN l_xobjects_str IS NOT NULL THEN '/XObject << ' || l_xobjects_str || ' >>' || CHR(10) ELSE '' END ||
                '>>' || CHR(10) ||
                '/Contents ' || fmt_num(l_stream_objs(i)) || ' 0 R' || CHR(10) ||
                '>>' || CHR(10)
            );
            end_obj;

            DBMS_LOB.CREATETEMPORARY(l_page_blob, TRUE);
            BEGIN
                append_clob_to_blob(l_page_blob, g_pages(i));
                l_page_len := DBMS_LOB.GETLENGTH(l_page_blob);

                start_obj(l_stream_objs(i));
                write_blob(
                    l_pdf,
                    '<<' || CHR(10) ||
                    '/Length ' || fmt_num(l_page_len) || CHR(10) ||
                    '>>' || CHR(10) ||
                    'stream' || CHR(10)
                );
                IF l_page_len > 0 THEN
                    DBMS_LOB.COPY(
                        l_pdf,
                        l_page_blob,
                        l_page_len,
                        DBMS_LOB.GETLENGTH(l_pdf) + 1,
                        1
                    );
                END IF;
                write_blob(l_pdf, CHR(10) || 'endstream' || CHR(10));
                end_obj;
                DBMS_LOB.FREETEMPORARY(l_page_blob);
            EXCEPTION
                WHEN OTHERS THEN
                    IF l_page_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_page_blob) = 1 THEN
                        DBMS_LOB.FREETEMPORARY(l_page_blob);
                    END IF;
                    RAISE;
            END;
        END LOOP;

        FOR i IN 1 .. 4 LOOP
            IF i = 1 THEN
                l_base_font := 'Helvetica';
            ELSIF i = 2 THEN
                l_base_font := 'Helvetica-Bold';
            ELSIF i = 3 THEN
                l_base_font := 'Helvetica-Oblique';
            ELSE
                l_base_font := 'Helvetica-BoldOblique';
            END IF;

            start_obj(l_font_objs(i));
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /Font' || CHR(10) ||
                '/Subtype /Type1' || CHR(10) ||
                '/BaseFont /' || l_base_font || CHR(10) ||
                '/Encoding /WinAnsiEncoding' || CHR(10) ||
                '>>' || CHR(10)
            );
            end_obj;
        END LOOP;

        IF l_unicode_active THEN
            start_obj(l_unicode_file_obj);
            write_blob(
                l_pdf,
                '<< /Length ' || fmt_num(g_unicode_font_length) ||
                ' /Length1 ' || fmt_num(g_unicode_font_length) || ' >>' || CHR(10) ||
                'stream' || CHR(10)
            );
            DBMS_LOB.COPY(
                l_pdf,
                g_unicode_font_blob,
                g_unicode_font_length,
                DBMS_LOB.GETLENGTH(l_pdf) + 1,
                1
            );
            write_blob(l_pdf, CHR(10) || 'endstream' || CHR(10));
            end_obj;

            start_obj(l_unicode_map_obj);
            write_blob(
                l_pdf,
                '<< /Length ' || fmt_num(l_unicode_map_length) || ' >>' || CHR(10) ||
                'stream' || CHR(10)
            );
            DBMS_LOB.COPY(
                l_pdf,
                l_unicode_map,
                l_unicode_map_length,
                DBMS_LOB.GETLENGTH(l_pdf) + 1,
                1
            );
            write_blob(l_pdf, CHR(10) || 'endstream' || CHR(10));
            end_obj;

            start_obj(l_unicode_tounicode_obj);
            write_blob(
                l_pdf,
                '<< /Length ' || fmt_num(DBMS_LOB.GETLENGTH(l_unicode_cmap)) || ' >>' || CHR(10) ||
                'stream' || CHR(10)
            );
            append_clob_to_blob(l_pdf, l_unicode_cmap);
            write_blob(l_pdf, CHR(10) || 'endstream' || CHR(10));
            end_obj;

            start_obj(l_unicode_descriptor_obj);
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /FontDescriptor' || CHR(10) ||
                '/FontName /' || g_unicode_font_name || CHR(10) ||
                '/Flags 32' || CHR(10) ||
                '/FontBBox [' || fmt_num(scale_font_metric(g_unicode_x_min)) || ' ' ||
                    fmt_num(scale_font_metric(g_unicode_y_min)) || ' ' ||
                    fmt_num(scale_font_metric(g_unicode_x_max)) || ' ' ||
                    fmt_num(scale_font_metric(g_unicode_y_max)) || ']' || CHR(10) ||
                '/ItalicAngle 0' || CHR(10) ||
                '/Ascent ' || fmt_num(scale_font_metric(g_unicode_ascent)) || CHR(10) ||
                '/Descent ' || fmt_num(scale_font_metric(g_unicode_descent)) || CHR(10) ||
                '/CapHeight ' || fmt_num(scale_font_metric(g_unicode_ascent)) || CHR(10) ||
                '/StemV 80' || CHR(10) ||
                '/FontFile2 ' || fmt_num(l_unicode_file_obj) || ' 0 R' || CHR(10) ||
                '>>' || CHR(10)
            );
            end_obj;

            start_obj(l_unicode_cidfont_obj);
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /Font' || CHR(10) ||
                '/Subtype /CIDFontType2' || CHR(10) ||
                '/BaseFont /' || g_unicode_font_name || CHR(10) ||
                '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>' || CHR(10) ||
                '/FontDescriptor ' || fmt_num(l_unicode_descriptor_obj) || ' 0 R' || CHR(10) ||
                '/DW 1000' || CHR(10) ||
                '/CIDToGIDMap ' || fmt_num(l_unicode_map_obj) || ' 0 R' || CHR(10) ||
                '/W [' || CHR(10)
            );
            l_cid := g_unicode_used_widths.FIRST;
            WHILE l_cid IS NOT NULL LOOP
                write_blob(
                    l_pdf,
                    fmt_num(l_cid) || ' [' || fmt_num(g_unicode_used_widths(l_cid)) || '] ' || CHR(10)
                );
                l_cid := g_unicode_used_widths.NEXT(l_cid);
            END LOOP;
            write_blob(l_pdf, ']' || CHR(10) || '>>' || CHR(10));
            end_obj;

            start_obj(l_unicode_type0_obj);
            write_blob(
                l_pdf,
                '<<' || CHR(10) ||
                '/Type /Font' || CHR(10) ||
                '/Subtype /Type0' || CHR(10) ||
                '/BaseFont /' || g_unicode_font_name || CHR(10) ||
                '/Encoding /Identity-H' || CHR(10) ||
                '/DescendantFonts [' || fmt_num(l_unicode_cidfont_obj) || ' 0 R]' || CHR(10) ||
                '/ToUnicode ' || fmt_num(l_unicode_tounicode_obj) || ' 0 R' || CHR(10) ||
                '>>' || CHR(10)
            );
            end_obj;

            IF l_unicode_map IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_unicode_map) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_unicode_map);
                l_unicode_map := NULL;
            END IF;
            IF l_unicode_cmap IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_unicode_cmap) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_unicode_cmap);
                l_unicode_cmap := NULL;
            END IF;
        END IF;

        IF l_metadata_active THEN
            start_obj(l_info_obj);
            write_blob(l_pdf, '<<' || CHR(10));
            IF g_metadata_title IS NOT NULL THEN
                write_blob(l_pdf, '/Title ' || metadata_pdf_string(g_metadata_title) || CHR(10));
            END IF;
            IF g_metadata_author IS NOT NULL THEN
                write_blob(l_pdf, '/Author ' || metadata_pdf_string(g_metadata_author) || CHR(10));
            END IF;
            IF g_metadata_subject IS NOT NULL THEN
                write_blob(l_pdf, '/Subject ' || metadata_pdf_string(g_metadata_subject) || CHR(10));
            END IF;
            IF g_metadata_keywords IS NOT NULL THEN
                write_blob(l_pdf, '/Keywords ' || metadata_pdf_string(g_metadata_keywords) || CHR(10));
            END IF;
            write_blob(l_pdf, '>>' || CHR(10));
            end_obj;
        END IF;

        l_xref_pos := DBMS_LOB.GETLENGTH(l_pdf);
        write_blob(
            l_pdf,
            'xref' || CHR(10) ||
            '0 ' || fmt_num(g_obj_count + 1) || CHR(10) ||
            '0000000000 65535 f ' || CHR(10)
        );

        FOR i IN 1 .. g_obj_count LOOP
            IF g_offsets(i) IS NULL OR g_offsets(i) > 9999999999 THEN
                RAISE_APPLICATION_ERROR(-20027, 'O PDF excedeu o limite de offsets da tabela xref clássica.');
            END IF;
            write_blob(l_pdf, LPAD(fmt_num(g_offsets(i)), 10, '0') || ' 00000 n ' || CHR(10));
        END LOOP;

        write_blob(
            l_pdf,
            'trailer' || CHR(10) ||
            '<<' || CHR(10) ||
            '/Size ' || fmt_num(g_obj_count + 1) || CHR(10) ||
            '/Root ' || fmt_num(l_catalog_obj) || ' 0 R' || CHR(10) ||
            CASE WHEN l_metadata_active THEN '/Info ' || fmt_num(l_info_obj) || ' 0 R' || CHR(10) ELSE '' END ||
            '>>' || CHR(10) ||
            'startxref' || CHR(10) ||
            fmt_num(l_xref_pos) || CHR(10) ||
            '%%EOF'
        );

        g_document_active := FALSE;
        RETURN l_pdf;
    EXCEPTION
        WHEN OTHERS THEN
            IF l_unicode_map IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_unicode_map) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_unicode_map);
            END IF;
            IF l_unicode_cmap IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_unicode_cmap) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_unicode_cmap);
            END IF;
            IF l_pdf IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_pdf);
            END IF;
            RAISE;
    END;

END pdfpkgen;
/
