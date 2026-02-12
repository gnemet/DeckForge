# DeckForge -- Suggested Folder Structure

Base folder:

    DeckForgeFiles/

------------------------------------------------------------------------

## 📁 Full Linux Seed Structure

    DeckForgeFiles/
    │  │
    ├── themes/
    │   ├── FDD/
    │   │   ├── source/                # readonly original PPTX files
    │   │   │   ├── MINTA_FDD.pptx
    │   │   │   └── sample_offer.pptx
    │   │   │
    │   │   ├── unpacked/              # auto-generated (safe to delete)
    │   │   │   └── MINTA_FDD/
    │   │   │       ├── ppt/
    │   │   │       └── _rels/
    │   │   │
    │   │   ├── slidemind/
    │   │   │   ├── seed.pptx
    │   │   │   ├── seed_metadata.json
    │   │   │   ├── metadata_schema.json
    │   │   │   ├── mcp_knowledge.json
    │   │   │   └── placeholders_map.json
    │   │   │
    │   │   └── versioning/
    │   │       ├── v1/
    │   │       └── v2/
    │   │
    │   └── TDD/
    │       └── ...
    │
    ├── jobs/
    │   ├── 2026-02-12_MBH_offer/
    │   │   ├── input_metadata.json
    │   │   ├── enriched_metadata.json
    │   │   ├── generated_slides/
    │   │   └── final_output.pptx
    │   │
    │   └── example_job/
    │       ├── input_metadata.json
    │       └── final_output.pptx
    │
    ├── logs/
    │   └── app.log
    │
    └── tmp/
        └── pptx_unpack_cache/


deckforge/
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── slidemind/
│   ├── deckforge/
│   ├── metadata/
│   ├── theme/
│   └── job/
│
├── pkg/
│
├── config/
│
├── go.mod
├── go.sum
└── .env

------------------------------------------------------------------------

# 📄 Example .env File

    APP_ENV=development
    APP_NAME=DeckForge
    APP_PORT=8080

    BASE_PATH=/absolute/path/to/DeckForgeFiles

    THEMES_PATH=${BASE_PATH}/themes
    JOBS_PATH=${BASE_PATH}/jobs
    TMP_PATH=${BASE_PATH}/tmp
    LOG_PATH=${BASE_PATH}/logs

    DATABASE_URL=postgres://user:password@localhost:5432/deckforge?sslmode=disable

    AI_PROVIDER=openai
    AI_MODEL=gpt-5
    AI_API_KEY=your_api_key_here

    MAX_UPLOAD_SIZE_MB=25
    ENABLE_THEME_VERSIONING=true
    DEBUG=true

------------------------------------------------------------------------

# 🧠 Architecture Philosophy

-   `themes/` = trained SlideMind knowledge (model layer)
-   `jobs/` = runtime DeckForge generation (inference layer)
-   `engine/` = Go application logic
-   `tmp/` = disposable processing cache
-   `source/` = readonly training material
-   `slidemind/` = seed + MCP knowledge per theme

------------------------------------------------------------------------

# 🚀 Minimal Mock Files

You can bootstrap quickly with:

    touch themes/FDD/source/MINTA_FDD.pptx
    touch themes/FDD/slidemind/seed.pptx
    echo '{}' > themes/FDD/slidemind/mcp_knowledge.json
    echo '{}' > themes/FDD/slidemind/seed_metadata.json
    echo '{}' > jobs/example_job/input_metadata.json

------------------------------------------------------------------------

DeckForge Concept:

SlideMind (train theme)\
→ Create seed + MCP knowledge\
→ DeckForge (generate new presentation from metadata)\
→ Human review\
→ Final PPTX output
