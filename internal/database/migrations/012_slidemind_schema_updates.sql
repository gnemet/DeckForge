-- migration: 012_slidemind_schema_updates
-- Consolidates PPTX status, slide styles, uniqueness constraints, and HTMX content
-- As per /pg technical standards: explicit schema references, no SET search_path
-- 1. PPTX Files: Status and Unpacked Path
ALTER TABLE deckforge.pptx_files
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'uploaded',
    ADD COLUMN IF NOT EXISTS unpacked_path TEXT;
CREATE INDEX IF NOT EXISTS idx_pptx_files_status ON deckforge.pptx_files(status);
UPDATE deckforge.pptx_files
SET status = 'processed'
WHERE status IS NULL;
-- 2. Collected Slides: Styles and HTMX Content
ALTER TABLE deckforge.collected_slides
ADD COLUMN IF NOT EXISTS style_info JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS htmx_content TEXT DEFAULT '';
-- 3. Collected Slides: Uniqueness Constraint for Idempotency
-- Clean up potential duplicates first
DELETE FROM deckforge.collected_slides a USING deckforge.collected_slides b
WHERE a.id > b.id
    AND a.pptx_file_id = b.pptx_file_id
    AND a.slide_number = b.slide_number;
-- Add the unique constraint
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'unq_collected_slides_pptx_slide'
) THEN
ALTER TABLE deckforge.collected_slides
ADD CONSTRAINT UNQ_collected_slides_pptx_slide UNIQUE (pptx_file_id, slide_number);
END IF;
END $$;