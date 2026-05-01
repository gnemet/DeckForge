-- migration: 021_rag_processing_log (v3 - partitioned by tenant_id)
-- RAG Processing Registry with upsert-based dedup + history audit
-- LIST partitioned by tenant_id for multi-tenant SaaS isolation
-- Target: bdo_db (PostgreSQL 16+)
SET search_path TO meta,
    public;
-- ================================================================
-- RAG Processing Log (Active Registry) — Partitioned
-- ================================================================
DROP TABLE IF EXISTS meta.rag_processing_history CASCADE;
DROP TABLE IF EXISTS meta.rag_processing_log CASCADE;
DROP FUNCTION IF EXISTS meta.needs_processing CASCADE;
CREATE TABLE meta.rag_processing_log (
    id SERIAL,
    tenant_id TEXT NOT NULL DEFAULT 'BDO',
    source_file TEXT NOT NULL,
    source_path TEXT,
    collection TEXT NOT NULL DEFAULT 'pptx',
    md5_checksum TEXT NOT NULL,
    content_size INTEGER,
    slide_count INTEGER,
    mcp_chain_file TEXT,
    embed_dims INTEGER,
    extract_state TEXT NOT NULL DEFAULT 'pending',
    embed_state TEXT NOT NULL DEFAULT 'pending',
    error_detail TEXT,
    extract_ms INTEGER,
    embed_ms INTEGER,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, tenant_id),
    UNIQUE (source_file, tenant_id)
) PARTITION BY LIST (tenant_id);
-- Default partition
CREATE TABLE meta.rag_processing_log_default PARTITION OF meta.rag_processing_log DEFAULT;
-- BDO tenant partition
CREATE TABLE meta.rag_processing_log_bdo PARTITION OF meta.rag_processing_log FOR
VALUES IN ('BDO');
-- ================================================================
-- SCD2 History (Audit Trail) — Partitioned
-- ================================================================
CREATE TABLE meta.rag_processing_history (
    id SERIAL,
    tenant_id TEXT NOT NULL DEFAULT 'BDO',
    log_id INTEGER,
    source_file TEXT NOT NULL,
    md5_checksum TEXT NOT NULL,
    extract_state TEXT,
    embed_state TEXT,
    version INTEGER,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, tenant_id)
) PARTITION BY LIST (tenant_id);
-- Default partition
CREATE TABLE meta.rag_processing_history_default PARTITION OF meta.rag_processing_history DEFAULT;
-- BDO tenant partition
CREATE TABLE meta.rag_processing_history_bdo PARTITION OF meta.rag_processing_history FOR
VALUES IN ('BDO');
-- Indexes
CREATE INDEX idx_rpl_checksum ON meta.rag_processing_log (md5_checksum);
CREATE INDEX idx_rpl_collection ON meta.rag_processing_log (collection);
CREATE INDEX idx_rpl_states ON meta.rag_processing_log (extract_state, embed_state);
CREATE INDEX idx_rpl_tenant ON meta.rag_processing_log (tenant_id);
CREATE INDEX idx_rph_source ON meta.rag_processing_history (source_file);
CREATE INDEX idx_rph_tenant ON meta.rag_processing_history (tenant_id);
-- Comments
COMMENT ON TABLE meta.rag_processing_log IS 'RAG Processing Registry (Partitioned): one active row per source file per tenant. Dedup via UNIQUE(source_file, tenant_id).';
COMMENT ON TABLE meta.rag_processing_history IS 'SCD2 audit trail (Partitioned): archived states when files are re-processed.';
-- needs_processing: tenant-aware dedup check
CREATE OR REPLACE FUNCTION meta.needs_processing(
        p_source TEXT,
        p_md5 TEXT,
        p_tenant TEXT DEFAULT 'BDO'
    ) RETURNS BOOLEAN AS $$ BEGIN RETURN NOT EXISTS (
        SELECT 1
        FROM meta.rag_processing_log
        WHERE source_file = p_source
            AND tenant_id = p_tenant
            AND md5_checksum = p_md5
            AND embed_state = 'embedded'
    );
END;
$$ LANGUAGE plpgsql;
-- Grant access
GRANT SELECT ON meta.rag_processing_log TO PUBLIC;
GRANT SELECT ON meta.rag_processing_log_bdo TO PUBLIC;
GRANT SELECT ON meta.rag_processing_log_default TO PUBLIC;
GRANT SELECT ON meta.rag_processing_history TO PUBLIC;
GRANT SELECT ON meta.rag_processing_history_bdo TO PUBLIC;
GRANT SELECT ON meta.rag_processing_history_default TO PUBLIC;
GRANT EXECUTE ON FUNCTION meta.needs_processing TO PUBLIC;