# SlideForge Storage Analysis

Storage Path: `/home/gnemet/DeckForgeFiles/BDO/FDD`
## Folders Overview

| Folder | Purpose | Contents |
|--------|---------|----------|
| `source`| Input PPTX files | Original presentations to be processed. |
| `unpack`| Exploded PPTX | XML and media assets extracted from source files. |
| `seed`  | Base Template | `seed.pptx` used for generating new offers. |
| `metadata` | Data Source | `test_metadata.json` and `metadata_template.json`. |
| `output` | Results | Generated PPTX files and skill documentation. |
| `task`   | Progress Logs | Documentation of completed tasks. |
| `skill`  | Domain Logic | MCP Skills and mapping rules. |
| `work`   | Temporary | Intermediate processing files. |

## Notable Assets

### Seed Template
- `seed/seed.pptx`: Derived from `Illés Holding Zrt ajánlat_mod250425.pptx`.

### Metadata Templates
- `metadata/metadata_template.json`: Contains fields like `service_line`, `lead_partner`, and `audit_period`.

### Exploded Structure (`unpack/MINTA_FDD&TDD`)
- `ppt/slides/`: Contains XML for individual slides.
- `ppt/media/`: Images and illustrations found in the presentation.
- `ppt/tags/`: Custom XML tags (identified as potentially useful for discovery).
