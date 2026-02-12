# DeckForge System -- Agent Context Specification

## 1. Purpose

DeckForge is a PPTX intelligence and generation platform consisting of
two main subsystems:

1.  **SlideMind** -- Learning & Structuring Engine\
2.  **DeckForge** -- Metadata-driven PPTX Generation Engine

The system analyzes similar PowerPoint files (e.g., financial offers),
extracts structural knowledge, creates a reusable seed template, and
generates new presentations from structured metadata with optional AI
enrichment.

This document defines: - System architecture - Core concepts - Module
responsibilities - Database structure - Processing flows - Coding
rules - Regeneration principles - Constraints

The AI agent must strictly follow this specification.

------------------------------------------------------------------------

# 2. Core Concepts

## 2.1 SlideMind (Learning Phase)

SlideMind processes similar PPTX files and:

-   Parses slide XML
-   Detects constant vs variable text
-   Extracts placeholder candidates
-   Identifies slide types
-   Generates MCP (Meta Content Protocol)
-   Produces a cleaned Seed PPTX
-   Allows human review & correction

Output: - MCP template - Seed PPTX - Seed Metadata Schema

------------------------------------------------------------------------

## 2.2 DeckForge (Generation Phase)

DeckForge:

-   Creates metadata instance (manual / AI / DB / API)
-   Enriches metadata (optional AI layer)
-   Generates slides from seed + MCP + metadata
-   Allows human override
-   Exports final PPTX

------------------------------------------------------------------------

## 2.3 MCP (Meta Content Protocol)

MCP defines presentation structure.

Example:

``` json
{
  "template_name": "financial_offer_v1",
  "slide_types": [
    {
      "type": "cover",
      "placeholders": ["company_name", "date"]
    },
    {
      "type": "pricing",
      "placeholders": ["offer_price", "valid_until"]
    }
  ],
  "validation": {
    "required_fields": [
      "company_name",
      "offer_price"
    ]
  }
}
```

Rules: - MCP is versioned - MCP cannot be modified automatically after
approval - Structure changes require human confirmation

------------------------------------------------------------------------

## 2.4 Seed PPTX

Seed PPTX is:

-   Cleaned template
-   Contains placeholders in format: `{{placeholder_key}}`
-   Constants remain intact
-   Versioned
-   Immutable after approval

------------------------------------------------------------------------

## 2.5 Metadata Instance

Metadata is a JSON structure:

``` json
{
  "company_name": "ABC Ltd",
  "offer_price": "€45,000",
  "valid_until": "2026-03-30"
}
```

Rules: - Metadata must conform to MCP validation - Missing required
fields must block generation - AI may modify metadata, never seed
structure

------------------------------------------------------------------------

## 2.6 Overrides

Human edits after generation are stored separately:

-   Slide-level override
-   Text-level override
-   Order override

Overrides must not modify seed or MCP.

Regeneration must reapply overrides safely.

------------------------------------------------------------------------

# 3. Technology Stack

Backend: - Go (clean architecture) - No global state

Frontend: - HTMX - Native JS - Minimal CSS - No SPA framework

Database: - PostgreSQL

PPTX handling: - Native XML parsing - No external PPTX SaaS

AI integration: - Adapter interface - Pluggable providers

------------------------------------------------------------------------

# 4. Project Structure

    /cmd/deckforge

    /internal
        /pptx
            parser.go
            builder.go
            placeholder.go

        /slidemind
            analyzer.go
            pattern.go
            mcp.go
            seed.go

        /deckforge
            metadata.go
            generator.go
            validator.go
            override.go

        /ai
            enrichment.go
            provider.go

        /repository
            interfaces.go
            postgres.go

        /service
            slidemind_service.go
            deckforge_service.go

    /web
        /templates
        /partials

    /migrations
    AGENT_CONTEXT.md

------------------------------------------------------------------------

# 5. Deterministic Build Rule

The system must behave like a compiler:

Seed + MCP + Metadata → Deterministic PPTX Output

Think of it as:

Presentation Compiler

Not a document editor.
