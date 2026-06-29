# Datagrid Integration Tasks

- [x] Create tabular menu for all database tables (MetaHub).
- [x] Implement catalog metadata for all DeckForge core tables.
- [x] Integrate Datagrid library for table presentation.
- [x] Match Jiramntr's catalog description pattern.
- [x] Rename sidebar menu link to "Tables".

## go.mod replace edge (moved from JiraDa platform urgent_tasks, A10 audit 2026-06-25)

> Moved here because DeckForge is a dead/parked project — it stays out of the platform's `projects.md`/`repos.yaml` Connections map, so the audit's "document the edge" half is moot. The actionable replace-path fix lives with the repo it belongs to.

- [ ] `go.mod:5` uses an absolute, off-machine `replace github.com/gnemet/datagrid => /home/gnemet/GitHub/datagrid` — breaks any build off that one machine. Repoint to a relative/in-tree path (or drop the `replace` and depend on a tagged datagrid version) so the module builds anywhere. Detail → claude-base `docs/audits/a10-scope-discipline-audit.md`.