# DeckForge SaaS Architecture Guide

Comprehensive Technical Blueprint Version 1.0

------------------------------------------------------------------------

# 1. System Vision

DeckForge is a Theme-Aware Generative Presentation Engine.

Architecture layers:

1.  SlideMind (Training Layer)
2.  DeckForge (Generation Layer)
3.  SaaS Infrastructure Layer
4.  Storage Layer
5.  AI Enrichment Layer

------------------------------------------------------------------------

# 2. High-Level Architecture

Codebase Root: deckforge-app/

Runtime Data Root: /DeckForgeFiles/

Separation is mandatory.

deckforge-app → contains Go code only\
DeckForgeFiles → contains themes, jobs, outputs

------------------------------------------------------------------------

# 3. Multi-Tenancy Strategy

Recommended: Row-Level Security (RLS) with tenant_id UUID.

Every domain table contains:

tenant_id UUID NOT NULL

Application sets:

SET app.current_tenant = '`<tenant_uuid>`{=html}'

RLS Policy Example:

CREATE POLICY tenant_isolation ON themes USING (tenant_id =
current_setting('app.current_tenant')::UUID);

------------------------------------------------------------------------

# 4. Database Schema (Postgres 16.2)

## 4.1 Tenants & Users

CREATE TABLE tenants ( id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
name TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now() );

CREATE TABLE users ( id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE, email
TEXT NOT NULL UNIQUE, password_hash TEXT, role TEXT NOT NULL CHECK (role
IN ('admin','editor','viewer')), created_at TIMESTAMPTZ NOT NULL DEFAULT
now() );

------------------------------------------------------------------------

## 4.2 Themes

CREATE TABLE themes ( id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE, name
TEXT NOT NULL, description TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT
now(), UNIQUE (tenant_id, name) );

------------------------------------------------------------------------

## 4.3 Source Files

CREATE TABLE source_files ( id UUID PRIMARY KEY DEFAULT
gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES tenants(id) ON
DELETE CASCADE, theme_id UUID NOT NULL REFERENCES themes(id) ON DELETE
CASCADE, file_name TEXT NOT NULL, object_path TEXT NOT NULL, uploaded_at
TIMESTAMPTZ NOT NULL DEFAULT now() );

------------------------------------------------------------------------

## 4.4 MCP Templates

CREATE TABLE mcp_templates ( id UUID PRIMARY KEY DEFAULT
gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES tenants(id) ON
DELETE CASCADE, theme_id UUID NOT NULL REFERENCES themes(id) ON DELETE
CASCADE, version INTEGER NOT NULL DEFAULT 1, structure JSONB NOT NULL,
placeholder_map JSONB NOT NULL, knowledge JSONB NOT NULL, created_at
TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (theme_id, version) );

CREATE INDEX idx_mcp_templates_theme ON mcp_templates(theme_id);

------------------------------------------------------------------------

## 4.5 Seed Files

CREATE TABLE seed_files ( id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
theme_id UUID NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
mcp_template_id UUID NOT NULL REFERENCES mcp_templates(id) ON DELETE
CASCADE, object_path TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL
DEFAULT now() );

------------------------------------------------------------------------

## 4.6 Metadata Instances

CREATE TABLE metadata_instances ( id UUID PRIMARY KEY DEFAULT
gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES tenants(id) ON
DELETE CASCADE, theme_id UUID NOT NULL REFERENCES themes(id) ON DELETE
CASCADE, mcp_template_id UUID NOT NULL REFERENCES mcp_templates(id),
input_data JSONB NOT NULL, enriched_data JSONB, status TEXT NOT NULL
CHECK (status IN ('draft','enriched','approved','archived')), created_by
UUID REFERENCES users(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_metadata_instances_theme ON
metadata_instances(theme_id);

------------------------------------------------------------------------

## 4.7 Generated Decks

CREATE TABLE generated_decks ( id UUID PRIMARY KEY DEFAULT
gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES tenants(id) ON
DELETE CASCADE, metadata_instance_id UUID NOT NULL REFERENCES
metadata_instances(id) ON DELETE CASCADE, seed_file_id UUID NOT NULL
REFERENCES seed_files(id), object_path TEXT NOT NULL, status TEXT NOT
NULL CHECK (status IN ('generating','completed','failed')), created_at
TIMESTAMPTZ NOT NULL DEFAULT now() );

------------------------------------------------------------------------

## 4.8 Overrides

CREATE TABLE overrides ( id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
metadata_instance_id UUID NOT NULL REFERENCES metadata_instances(id) ON
DELETE CASCADE, slide_index INTEGER NOT NULL, placeholder_key TEXT NOT
NULL, override_value TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL
DEFAULT now() );

------------------------------------------------------------------------

# 5. Storage Strategy

Do NOT store PPTX binaries in Postgres.

Use:

-   MinIO (local Ubuntu)
-   AWS S3 (production)

Store only object_path in DB.

------------------------------------------------------------------------

# 6. Go Application Structure

deckforge-app/

cmd/server/main.go internal/slidemind/ internal/deckforge/
internal/pptx/ internal/ai/ internal/repository/ internal/domain/ pkg/
config/

------------------------------------------------------------------------

# 7. Core Go Interfaces

## PPTX Parser

type Parser interface { Parse(r io.Reader) (\*PresentationStructure,
error) }

## AI Provider

type AIProvider interface { EnrichMetadata(ctx context.Context, input
Metadata) (Metadata, error) }

## Deck Generator

type Generator interface { Generate(ctx context.Context, seed Seed,
metadata Metadata) (\[\]byte, error) }

------------------------------------------------------------------------

# 8. HTMX Routing Strategy

POST /upload GET /mcp/{id}/editor POST /metadata/{id}/enrich POST
/deck/generate GET /deck/{id}/status

Long-running tasks: - HTMX polling - or Server-Sent Events

------------------------------------------------------------------------

# 9. OOXML (PPTX) Parsing Targets

Important XML locations:

ppt/slides/slide1.xml ppt/slideLayouts/ ppt/slideMasters/
ppt/presentation.xml

Text nodes:

a:t p:sp p:txBody

Placeholders:

p:ph

------------------------------------------------------------------------

# 10. MCP JSON Structure Example

{ "theme": "FDD", "version": 1, "slides": \[ { "index": 1, "type":
"title", "placeholders": \[ {"key": "company_name", "type": "text"},
{"key": "report_date", "type": "date"} \] } \] }

------------------------------------------------------------------------

# 11. Deployment Model

Ubuntu Server:

/srv/deckforge/app /srv/deckforge/data

Docker:

/app /data (volume mounted)

------------------------------------------------------------------------

# 12. Development Priorities

1.  Database schema migration
2.  Basic auth + RLS enforcement
3.  PPTX parser prototype
4.  MCP builder logic
5.  Metadata enrichment
6.  PPTX compiler
7.  UI integration

------------------------------------------------------------------------

End of Document
