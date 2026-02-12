-- migration: 016_jsonb_crud_functions
-- Stored functions for JSONB-based CRUD operations
-- As per /pg technical standards: input JSONB, output JSONB
-- 1. Upsert PPTX File
CREATE OR REPLACE FUNCTION deckforge.upsert_pptx_file(p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
v_result JSONB;
BEGIN
INSERT INTO deckforge.pptx_files (
        filename,
        original_file_path,
        thumbnail_dir_path,
        metadata,
        is_template,
        ai_summary,
        title,
        checksum,
        status,
        unpacked_path,
        tenant_id,
        theme_id
    )
VALUES (
        p_data->>'filename',
        p_data->>'original_file_path',
        p_data->>'thumbnail_dir_path',
        COALESCE((p_data->'metadata')::JSONB, '{}'::JSONB),
        COALESCE((p_data->>'is_template')::BOOLEAN, FALSE),
        COALESCE(p_data->>'ai_summary', ''),
        COALESCE(p_data->>'title', ''),
        p_data->>'checksum',
        COALESCE(p_data->>'status', 'uploaded'),
        p_data->>'unpacked_path',
        (p_data->>'tenant_id')::UUID,
        (p_data->>'theme_id')::UUID
    ) ON CONFLICT (checksum)
WHERE checksum != '' DO
UPDATE
SET status = CASE
        WHEN EXCLUDED.status NOT IN ('unpacked', 'uploaded') THEN EXCLUDED.status
        ELSE deckforge.pptx_files.status
    END,
    title = CASE
        WHEN EXCLUDED.title != '' THEN EXCLUDED.title
        ELSE deckforge.pptx_files.title
    END,
    ai_summary = CASE
        WHEN EXCLUDED.ai_summary != '' THEN EXCLUDED.ai_summary
        ELSE deckforge.pptx_files.ai_summary
    END,
    unpacked_path = COALESCE(
        EXCLUDED.unpacked_path,
        deckforge.pptx_files.unpacked_path
    ),
    theme_id = COALESCE(
        EXCLUDED.theme_id,
        deckforge.pptx_files.theme_id
    ),
    metadata = deckforge.pptx_files.metadata || EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP
RETURNING id INTO v_id;
SELECT to_jsonb(f) INTO v_result
FROM deckforge.pptx_files f
WHERE f.id = v_id;
RETURN v_result;
END;
$$;
-- 2. Upsert Collected Slide
CREATE OR REPLACE FUNCTION deckforge.upsert_collected_slide(p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
v_result JSONB;
BEGIN
INSERT INTO deckforge.collected_slides (
        pptx_file_id,
        slide_number,
        png_path,
        content,
        style_info,
        ai_analysis,
        ai_summary,
        title,
        comments,
        tenant_id,
        htmx_content
    )
VALUES (
        (p_data->>'pptx_file_id')::INTEGER,
        (p_data->>'slide_number')::INTEGER,
        COALESCE(p_data->>'png_path', ''),
        COALESCE(p_data->>'content', ''),
        COALESCE((p_data->'style_info')::JSONB, '{}'::JSONB),
        COALESCE((p_data->'ai_analysis')::JSONB, '{}'::JSONB),
        COALESCE(p_data->>'ai_summary', ''),
        COALESCE(p_data->>'title', ''),
        COALESCE(p_data->>'comments', ''),
        (p_data->>'tenant_id')::UUID,
        COALESCE(p_data->>'htmx_content', '')
    ) ON CONFLICT (pptx_file_id, slide_number) DO
UPDATE
SET png_path = CASE
        WHEN EXCLUDED.png_path != '' THEN EXCLUDED.png_path
        ELSE deckforge.collected_slides.png_path
    END,
    content = CASE
        WHEN EXCLUDED.content != '' THEN EXCLUDED.content
        ELSE deckforge.collected_slides.content
    END,
    style_info = deckforge.collected_slides.style_info || EXCLUDED.style_info,
    ai_analysis = deckforge.collected_slides.ai_analysis || EXCLUDED.ai_analysis,
    ai_summary = CASE
        WHEN EXCLUDED.ai_summary != '' THEN EXCLUDED.ai_summary
        ELSE deckforge.collected_slides.ai_summary
    END,
    title = CASE
        WHEN EXCLUDED.title != '' THEN EXCLUDED.title
        ELSE deckforge.collected_slides.title
    END,
    comments = CASE
        WHEN EXCLUDED.comments != '' THEN EXCLUDED.comments
        ELSE deckforge.collected_slides.comments
    END,
    htmx_content = CASE
        WHEN EXCLUDED.htmx_content != '' THEN EXCLUDED.htmx_content
        ELSE deckforge.collected_slides.htmx_content
    END
RETURNING id INTO v_id;
SELECT to_jsonb(s) INTO v_result
FROM deckforge.collected_slides s
WHERE s.id = v_id;
RETURN v_result;
END;
$$;
-- 3. Capture Slide Knowledge
CREATE OR REPLACE FUNCTION deckforge.capture_slide_knowledge(p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
v_result JSONB;
BEGIN
INSERT INTO deckforge.slide_knowledge (
        tenant_id,
        theme_id,
        pptx_file_id,
        slide_number,
        content,
        ai_summary,
        metadata
    )
VALUES (
        (p_data->>'tenant_id')::UUID,
        (p_data->>'theme_id')::UUID,
        (p_data->>'pptx_file_id')::INTEGER,
        (p_data->>'slide_number')::INTEGER,
        p_data->>'content',
        p_data->>'ai_summary',
        COALESCE((p_data->'metadata')::JSONB, '{}'::JSONB)
    )
RETURNING id INTO v_id;
SELECT to_jsonb(sk) INTO v_result
FROM deckforge.slide_knowledge sk
WHERE sk.id = v_id;
RETURN v_result;
END;
$$;
-- 4. Save Placeholder Discovery
CREATE OR REPLACE FUNCTION deckforge.save_placeholder_discovery(p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
v_result JSONB;
BEGIN
INSERT INTO deckforge.placeholder_discovery (
        pptx_file_id,
        slide_number,
        placeholder_text,
        metadata_key
    )
VALUES (
        (p_data->>'pptx_file_id')::INTEGER,
        (p_data->>'slide_number')::INTEGER,
        p_data->>'placeholder_text',
        p_data->>'metadata_key'
    ) ON CONFLICT (pptx_file_id, slide_number, placeholder_text) DO
UPDATE
SET metadata_key = EXCLUDED.metadata_key,
    discovered_at = CURRENT_TIMESTAMP
RETURNING id INTO v_id;
SELECT to_jsonb(pd) INTO v_result
FROM deckforge.placeholder_discovery pd
WHERE pd.id = v_id;
RETURN v_result;
END;
$$;
-- 5. Get PPTX File by ID or Checksum
CREATE OR REPLACE FUNCTION deckforge.get_pptx_file(p_id INTEGER, p_checksum TEXT) RETURNS JSONB LANGUAGE SQL IMMUTABLE AS $$
SELECT to_jsonb(f)
FROM deckforge.pptx_files f
WHERE (
        p_id IS NOT NULL
        AND f.id = p_id
    )
    OR (
        p_checksum IS NOT NULL
        AND f.checksum = p_checksum
    );
$$;
-- 6. Get All Slides for a File
CREATE OR REPLACE FUNCTION deckforge.get_slides_by_file(p_file_id INTEGER) RETURNS JSONB LANGUAGE SQL IMMUTABLE AS $$
SELECT jsonb_agg(
        to_jsonb(s)
        ORDER BY s.slide_number
    )
FROM deckforge.collected_slides s
WHERE s.pptx_file_id = p_file_id;
$$;
-- 7. Get All PPTX Files
CREATE OR REPLACE FUNCTION deckforge.get_all_pptx() RETURNS JSONB LANGUAGE SQL IMMUTABLE AS $$
SELECT jsonb_agg(
        to_jsonb(f)
        ORDER BY f.created_at DESC
    )
FROM deckforge.pptx_files f;
$$;