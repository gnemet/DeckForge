-- migration: 020_bdo_rag_bootstrap (v2 - partitioned by tenant_id)
-- RAG Tables for pgvector (SaaS: bdo_db)
-- Same schema as jiramntr's meta.mcp_embeddings for Johanna compatibility
-- LIST partitioned by tenant_id for multi-tenant SaaS isolation
-- Target: PostgreSQL 16+ with pgvector extension
SET search_path TO meta,
    public;
-- Ensure meta schema exists
CREATE SCHEMA IF NOT EXISTS meta;
-- Ensure extensions
CREATE EXTENSION IF NOT EXISTS vector SCHEMA public;
-- ================================================================
-- MCP Embeddings (LIST partitioned by tenant_id)
-- ================================================================
DROP TABLE IF EXISTS meta.mcp_embeddings CASCADE;
CREATE TABLE meta.mcp_embeddings (
    id SERIAL,
    tenant_id TEXT NOT NULL DEFAULT 'BDO',
    collection TEXT NOT NULL DEFAULT 'pptx',
    source_file TEXT NOT NULL,
    topic TEXT NOT NULL,
    description TEXT,
    content TEXT NOT NULL,
    embedding VECTOR(3072),
    updated_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (id, tenant_id),
    UNIQUE (source_file, tenant_id)
) PARTITION BY LIST (tenant_id);
-- Default partition (catches any tenant not explicitly defined)
CREATE TABLE meta.mcp_embeddings_default PARTITION OF meta.mcp_embeddings DEFAULT;
-- BDO tenant partition
CREATE TABLE meta.mcp_embeddings_bdo PARTITION OF meta.mcp_embeddings FOR
VALUES IN ('BDO');
-- Indexes (on parent, inherited by partitions)
CREATE INDEX idx_mcp_emb_collection ON meta.mcp_embeddings (collection);
CREATE INDEX idx_mcp_emb_tenant ON meta.mcp_embeddings (tenant_id);
-- Comments
COMMENT ON TABLE meta.mcp_embeddings IS 'RAG Knowledge Base (Partitioned): Vector embeddings of PPTX presentation content. Partitioned by tenant_id for SaaS isolation.';
COMMENT ON COLUMN meta.mcp_embeddings.tenant_id IS 'SaaS tenant identifier. Each tenant gets its own partition for data isolation.';
-- Grant access
GRANT SELECT ON meta.mcp_embeddings TO PUBLIC;
GRANT SELECT ON meta.mcp_embeddings_bdo TO PUBLIC;
GRANT SELECT ON meta.mcp_embeddings_default TO PUBLIC;