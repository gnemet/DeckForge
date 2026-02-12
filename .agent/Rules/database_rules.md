# Database Rules

## 1. Connection Search Path
Always ensure that the PostgreSQL connection string includes the `search_path=deckforge,public` option. This guarantees that all queries correctly resolve tables in the thematic `deckforge` schema without explicit schema prefixing.

## 2. Migration Standards
- Migrations should not hardcode `SET search_path`.
- Migrations should be idempotent (use `IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`).
- Always use thematic UUIDs (`tenant_id`, `theme_id`) for data isolation.
