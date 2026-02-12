-- Migration to add checksum to pptx_files
-- PostgreSQL 18
ALTER TABLE pptx_files
ADD COLUMN IF NOT EXISTS checksum TEXT DEFAULT '';
CREATE UNIQUE INDEX IF NOT EXISTS idx_pptx_files_checksum ON pptx_files(checksum)
WHERE checksum != '';