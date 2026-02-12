-- Migration to add Title to pptx_files
-- PostgreSQL 18
ALTER TABLE pptx_files
ADD COLUMN IF NOT EXISTS title TEXT DEFAULT '';