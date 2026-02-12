-- migration: 010_slidemind_deckforge_core
-- SaaS Preparation + SlideMind/DeckForge functional core
-- 1. SaaS Base (Preparation)
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL unique,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- 2. Themes (Folders for Knowledge/Seeds)
CREATE TABLE IF NOT EXISTS themes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(tenant_id, name)
);
-- 3. SlideMind: Knowledge Repository
-- This is where analyzed slide content lives for searching/reuse.
CREATE TABLE IF NOT EXISTS slide_knowledge (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    theme_id UUID REFERENCES themes(id) ON DELETE
    SET NULL,
        pptx_file_id INTEGER REFERENCES pptx_files(id) ON DELETE CASCADE,
        slide_number INTEGER NOT NULL,
        content TEXT,
        -- RAW CONTENT
        ai_summary TEXT,
        -- AI SUMMARY
        metadata JSONB DEFAULT '{}',
        -- Key/Value extracted
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- 4. DeckForge: MCP Templates (The Blueprint)
CREATE TABLE IF NOT EXISTS mcp_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    theme_id UUID REFERENCES themes(id) ON DELETE CASCADE,
    version INTEGER NOT NULL DEFAULT 1,
    structure JSONB NOT NULL,
    -- The slide order and placeholders
    knowledge_requirements JSONB NOT NULL,
    -- What knowledge keys we need
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(theme_id, version)
);
-- 5. DeckForge: Metadata Instances (The Enrichment Work-in-Progress)
CREATE TABLE IF NOT EXISTS metadata_instances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    theme_id UUID REFERENCES themes(id) ON DELETE CASCADE,
    mcp_template_id UUID REFERENCES mcp_templates(id),
    input_data JSONB NOT NULL,
    -- User input
    enriched_data JSONB,
    -- AI enriched final values
    status TEXT NOT NULL DEFAULT 'draft',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- 6. DeckForge: Generated Decks (Outputs)
CREATE TABLE IF NOT EXISTS generated_decks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    metadata_instance_id UUID REFERENCES metadata_instances(id) ON DELETE CASCADE,
    object_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'generating',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- Add padding to existing tables
ALTER TABLE pptx_files
ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants(id);
ALTER TABLE collected_slides
ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants(id);
-- GIN Indexes for fast JSONB search
CREATE INDEX IF NOT EXISTS idx_sk_metadata ON slide_knowledge USING GIN (metadata);
CREATE INDEX IF NOT EXISTS idx_mcp_structure ON mcp_templates USING GIN (structure);
CREATE INDEX IF NOT EXISTS idx_mi_enriched ON metadata_instances USING GIN (enriched_data);