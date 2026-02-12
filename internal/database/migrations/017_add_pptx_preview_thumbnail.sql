-- migration: 017_add_pptx_preview_thumbnail
-- Add preview_thumbnail to pptx_files for fast dashboard rendering
ALTER TABLE deckforge.pptx_files
ADD COLUMN IF NOT EXISTS preview_thumbnail TEXT;