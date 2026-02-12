-- migration: 019_add_summarized_slides
-- 1. Add theme_id to pptx_files for explicit thematic linking
ALTER TABLE deckforge.pptx_files
ADD COLUMN IF NOT EXISTS theme_id UUID REFERENCES deckforge.themes(id) ON DELETE
SET NULL;
-- 2. Create summarized_slides table for DeckForge seed data
CREATE TABLE IF NOT EXISTS deckforge.summarized_slides (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES deckforge.tenants(id) ON DELETE CASCADE,
    theme_id UUID REFERENCES deckforge.themes(id) ON DELETE CASCADE,
    title TEXT,
    seed_content TEXT,
    placeholders JSONB DEFAULT '[]',
    -- List of {name, description, distinct_values}
    reference_slide_ids INTEGER [],
    -- IDs from collected_slides that were merged
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_summarized_tenant_theme ON deckforge.summarized_slides(tenant_id, theme_id);