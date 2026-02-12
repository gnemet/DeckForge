-- migration: 018_add_tenant_id_to_all_tables
-- This migration ensures all tables in the deckforge schema have a tenant_id column
-- and are populated with a default tenant ("BDO") to prepare for RLS.
-- 1. Ensure a unique BDO tenant exists
-- And fix unaccent usage in trigger function
DO $$
DECLARE default_tenant_id UUID;
BEGIN -- Fix trigger function to use qualified unaccent
CREATE OR REPLACE FUNCTION deckforge.update_slide_search_vectors() RETURNS trigger AS $TRG$ BEGIN NEW.fts_en := to_tsvector(
        'english',
        coalesce(NEW.content, '') || ' ' || coalesce(NEW.comments, '')
    );
NEW.fts_hu := to_tsvector(
    'hungarian',
    deckforge.unaccent(
        coalesce(NEW.content, '') || ' ' || coalesce(NEW.comments, '')
    )
);
NEW.fts_combined := setweight(
    to_tsvector(
        'english',
        coalesce(NEW.content, '') || ' ' || coalesce(NEW.comments, '')
    ),
    'A'
) || setweight(
    to_tsvector(
        'hungarian',
        deckforge.unaccent(
            coalesce(NEW.content, '') || ' ' || coalesce(NEW.comments, '')
        )
    ),
    'A'
);
RETURN NEW;
END $TRG$ LANGUAGE plpgsql;
-- Get or create the BDO tenant
INSERT INTO deckforge.tenants (name)
VALUES ('BDO') ON CONFLICT DO NOTHING;
SELECT id INTO default_tenant_id
FROM deckforge.tenants
WHERE name = 'BDO'
LIMIT 1;
-- 2. Add tenant_id to missing tables
-- placeholder_discovery
IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'deckforge'
        AND table_name = 'placeholder_discovery'
        AND column_name = 'tenant_id'
) THEN
ALTER TABLE deckforge.placeholder_discovery
ADD COLUMN tenant_id UUID REFERENCES deckforge.tenants(id);
END IF;
UPDATE deckforge.placeholder_discovery
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
ALTER TABLE deckforge.placeholder_discovery
ALTER COLUMN tenant_id
SET NOT NULL;
-- comment_overrides
IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'deckforge'
        AND table_name = 'comment_overrides'
        AND column_name = 'tenant_id'
) THEN
ALTER TABLE deckforge.comment_overrides
ADD COLUMN tenant_id UUID REFERENCES deckforge.tenants(id);
END IF;
UPDATE deckforge.comment_overrides
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
ALTER TABLE deckforge.comment_overrides
ALTER COLUMN tenant_id
SET NOT NULL;
-- search_settings
IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'deckforge'
        AND table_name = 'search_settings'
        AND column_name = 'tenant_id'
) THEN
ALTER TABLE deckforge.search_settings
ADD COLUMN tenant_id UUID REFERENCES deckforge.tenants(id);
END IF;
UPDATE deckforge.search_settings
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
-- For search_settings, we need to handle the PK update if we want per-tenant settings
-- But for now, just adding the column and populating it.
-- ALTER TABLE deckforge.search_settings DROP CONSTRAINT search_settings_pkey;
-- ALTER TABLE deckforge.search_settings ADD PRIMARY KEY (tenant_id, key);
ALTER TABLE deckforge.search_settings
ALTER COLUMN tenant_id
SET NOT NULL;
-- 3. Ensure existing tables have NOT NULL tenant_id
-- pptx_files
UPDATE deckforge.pptx_files
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
ALTER TABLE deckforge.pptx_files
ALTER COLUMN tenant_id
SET NOT NULL;
-- collected_slides
UPDATE deckforge.collected_slides
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
ALTER TABLE deckforge.collected_slides
ALTER COLUMN tenant_id
SET NOT NULL;
-- generated_decks, metadata_instances, mcp_templates, slide_knowledge, themes 
-- should already have tenant_id from migration 010, but let's be sure.
UPDATE deckforge.generated_decks
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
UPDATE deckforge.metadata_instances
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
UPDATE deckforge.mcp_templates
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
UPDATE deckforge.slide_knowledge
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
UPDATE deckforge.themes
SET tenant_id = default_tenant_id
WHERE tenant_id IS NULL;
-- 4. Ensure tenants.name is UNIQUE (as per migration 010 update)
IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'tenants_name_key'
) THEN
ALTER TABLE deckforge.tenants
ADD CONSTRAINT tenants_name_key UNIQUE (name);
END IF;
-- 5. Update CRUD function for placeholder discovery to be tenant-aware
CREATE OR REPLACE FUNCTION deckforge.save_placeholder_discovery(p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $PD$
DECLARE v_id INTEGER;
v_result JSONB;
BEGIN
INSERT INTO deckforge.placeholder_discovery (
        pptx_file_id,
        slide_number,
        placeholder_text,
        metadata_key,
        tenant_id
    )
VALUES (
        (p_data->>'pptx_file_id')::INTEGER,
        (p_data->>'slide_number')::INTEGER,
        p_data->>'placeholder_text',
        p_data->>'metadata_key',
        (p_data->>'tenant_id')::UUID
    ) ON CONFLICT (pptx_file_id, slide_number, placeholder_text) DO
UPDATE
SET metadata_key = EXCLUDED.metadata_key,
    tenant_id = EXCLUDED.tenant_id,
    discovered_at = CURRENT_TIMESTAMP
RETURNING id INTO v_id;
SELECT to_jsonb(pd) INTO v_result
FROM deckforge.placeholder_discovery pd
WHERE pd.id = v_id;
RETURN v_result;
END;
$PD$;
END $$;