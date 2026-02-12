-- migration: 002_fts_search
-- Full Text Search implementation for collected_slides
-- 1. Extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
-- 2. Add content column if not exists
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'collected_slides'
        AND column_name = 'content'
) THEN
ALTER TABLE collected_slides
ADD COLUMN content TEXT DEFAULT '';
END IF;
END $$;
-- 3. Add search vectors
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'collected_slides'
        AND column_name = 'fts_en'
) THEN
ALTER TABLE collected_slides
ADD COLUMN fts_en tsvector,
    ADD COLUMN fts_hu tsvector,
    ADD COLUMN fts_combined tsvector;
END IF;
END $$;
-- 4. Search Settings
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_name = 'search_settings'
) THEN CREATE TABLE search_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO search_settings (key, value)
VALUES ('similarity_threshold', '0.3'),
    ('word_similarity_threshold', '0.3');
END IF;
END $$;
-- 5. Trigger Function
CREATE OR REPLACE FUNCTION update_slide_search_vectors() RETURNS trigger AS $$ BEGIN NEW.fts_en := to_tsvector('english', coalesce(NEW.content, ''));
NEW.fts_hu := to_tsvector('hungarian', unaccent(coalesce(NEW.content, '')));
NEW.fts_combined := setweight(
    to_tsvector('english', coalesce(NEW.content, '')),
    'A'
) || setweight(
    to_tsvector('hungarian', unaccent(coalesce(NEW.content, ''))),
    'A'
);
RETURN NEW;
END $$ LANGUAGE plpgsql;
-- 6. Trigger
DROP TRIGGER IF EXISTS trg_update_slide_search_vectors ON collected_slides;
CREATE TRIGGER trg_update_slide_search_vectors BEFORE
INSERT
    OR
UPDATE ON collected_slides FOR EACH ROW EXECUTE FUNCTION update_slide_search_vectors();
-- 7. Indexes
CREATE INDEX IF NOT EXISTS idx_slides_fts_en ON collected_slides USING GIN (fts_en);
CREATE INDEX IF NOT EXISTS idx_slides_fts_hu ON collected_slides USING GIN (fts_hu);
CREATE INDEX IF NOT EXISTS idx_slides_fts_combined ON collected_slides USING GIN (fts_combined);
CREATE INDEX IF NOT EXISTS idx_slides_content_trgm ON collected_slides USING GIN (content gin_trgm_ops);