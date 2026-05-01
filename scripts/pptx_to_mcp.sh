#!/bin/bash
# ================================================================
# PPTX → MCP Chain Generator (with DB Processing Log)
# ================================================================
# Extracts text from BDO PPTX files and generates MCP chain
# Markdown files for RAG embedding.
# Uses meta.rag_processing_log for per-file dedup via MD5.
#
# Usage:
#   bash scripts/pptx_to_mcp.sh                        # all PPTX files
#   bash scripts/pptx_to_mcp.sh --file test/Acme.pptx  # single file
#   bash scripts/pptx_to_mcp.sh --force                # re-generate all
#   bash scripts/pptx_to_mcp.sh --status                # show log status
#
# Requires:
#   - Go 1.25+ (for context_extractor)
#   - .env loaded (for STORAGE_ORIGINAL path)
#   - bdo_db with meta.rag_processing_log table
# ================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CHAIN_DIR="${BASE_DIR}/ai/mcp/chain"
PY="/usr/bin/python3"

# Load environment
if [ -f "$BASE_DIR/.env" ]; then
    source "$BASE_DIR/.env"
fi

# Source directory for PPTX files (override with --source)
SOURCE_DIR="${STORAGE_ORIGINAL:-/home/gnemet/DeckForgeFiles/BDO}"

# DB Config — bdo_db (same as embed_pptx.sh)
DB_HOST="${PPTX_RAG_PG_HOST:-${RAG_PG_HOST:-localhost}}"
DB_PORT="${PPTX_RAG_PG_PORT:-${RAG_PG_PORT:-5433}}"
DB_NAME="${PPTX_RAG_PG_DB:-${RAG_PG_DB:-bdo_db}}"
DB_USER="${PPTX_RAG_PG_USER:-${RAG_PG_USER:-root}}"
DB_PASS="${PPTX_RAG_PG_PASSWORD:-${RAG_PG_PASSWORD:-soa123}}"
TENANT_ID="${TENANT_ID:-BDO}"

# Parse flags
SINGLE_FILE=""
FORCE=false
STATUS=false
prev=""
for arg in "$@"; do
    if [ "$prev" = "--file" ]; then
        SINGLE_FILE="$arg"
    fi
    if [ "$prev" = "--source" ]; then
        SOURCE_DIR="$arg"
    fi
    if [ "$arg" = "--force" ]; then
        FORCE=true
    fi
    if [ "$arg" = "--status" ]; then
        STATUS=true
    fi
    prev="$arg"
done

# Pre-build context extractor binary (faster than go run per file)
EXTRACTOR="/tmp/deckforge_context_extractor"
if [ ! -f "$EXTRACTOR" ] || [ "$FORCE" = "true" ]; then
    echo "🔨 Building context extractor..."
    (cd "$BASE_DIR" && GOWORK=off go build -o "$EXTRACTOR" ./scripts/context_extractor/main.go) || {
        echo "❌ Build failed"
        exit 1
    }
    echo "   ✅ Built: $EXTRACTOR"
    echo ""
fi

# ── Status mode ──────────────────────────────────────────────────
if [ "$STATUS" = "true" ]; then
    echo "📊 RAG Processing Log Status (bdo_db)"
    echo ""
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        SELECT tenant_id, source_file, extract_state, embed_state,
               slide_count, content_size, embed_dims,
               LEFT(md5_checksum, 8) AS md5,
               version, updated_at::date AS last_update
        FROM meta.rag_processing_log
        ORDER BY source_file;
    "
    echo ""
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --tuples-only -c "
        SELECT 'Total: ' || COUNT(*) || ' files (' ||
               SUM(CASE WHEN embed_state='embedded' THEN 1 ELSE 0 END) || ' embedded, ' ||
               SUM(CASE WHEN extract_state='error' OR embed_state='error' THEN 1 ELSE 0 END) || ' errors)'
        FROM meta.rag_processing_log;
    "
    exit 0
fi

# Ensure output directory
mkdir -p "$CHAIN_DIR"

echo "================================================================"
echo "  PPTX → MCP Chain Generator"
echo "================================================================"
echo "  Source:  $SOURCE_DIR"
echo "  Output:  $CHAIN_DIR"
echo "  Log DB:  $DB_HOST:$DB_PORT/$DB_NAME"
echo ""

# ── Slugify function ─────────────────────────────────────────────
slugify() {
    echo "$1" | \
        sed 's/\.pptx$//' | \
        sed 's/ (1)$//' | \
        sed 's/ /_/g' | \
        sed 's/[^a-zA-Z0-9._-]//g' | \
        tr '[:upper:]' '[:lower:]'
}

# ── Skip duplicates: files ending with " (1).pptx" ──────────────
is_duplicate() {
    local filename="$1"
    if echo "$filename" | grep -qE ' \(1\)\.pptx$'; then
        return 0
    fi
    if echo "$filename" | grep -qE ' \(1\) másolata\.pptx$'; then
        return 0
    fi
    return 1
}

# ── DB: check if file needs processing ───────────────────────────
needs_processing() {
    local SOURCE_FILE="$1"
    local MD5="$2"
    if [ "$FORCE" = "true" ]; then
        return 0  # force = always process
    fi
    local RESULT
    RESULT=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --tuples-only -c "SELECT meta.needs_processing('$SOURCE_FILE', '$MD5', '$TENANT_ID');" 2>/dev/null | tr -d ' ')
    [ "$RESULT" = "t" ]
}

# ── DB: register extraction start ────────────────────────────────
log_extract_start() {
    local SOURCE_FILE="$1"
    local SOURCE_PATH="$2"
    local MD5="$3"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --tuples-only -q -c "
        -- Archive previous state to history (if exists)
        INSERT INTO meta.rag_processing_history (tenant_id, log_id, source_file, md5_checksum, extract_state, embed_state, version)
        SELECT tenant_id, id, source_file, md5_checksum, extract_state, embed_state, version
        FROM meta.rag_processing_log WHERE source_file = '$SOURCE_FILE' AND tenant_id = '$TENANT_ID';

        -- Upsert: insert or reset existing record
        INSERT INTO meta.rag_processing_log (tenant_id, source_file, source_path, md5_checksum, extract_state, embed_state)
        VALUES ('$TENANT_ID', '$SOURCE_FILE', '$SOURCE_PATH', '$MD5', 'extracting', 'pending')
        ON CONFLICT (source_file, tenant_id) DO UPDATE SET
            source_path = EXCLUDED.source_path,
            md5_checksum = EXCLUDED.md5_checksum,
            extract_state = 'extracting',
            embed_state = 'pending',
            error_detail = NULL,
            slide_count = NULL,
            content_size = NULL,
            mcp_chain_file = NULL,
            embed_dims = NULL,
            extract_ms = NULL,
            embed_ms = NULL,
            version = meta.rag_processing_log.version + 1,
            updated_at = NOW();
    " 2>/dev/null
}

# ── DB: register extraction result ───────────────────────────────
log_extract_done() {
    local SOURCE_FILE="$1"
    local MCP_CHAIN="$2"
    local SLIDE_COUNT="$3"
    local CONTENT_SIZE="$4"
    local EXTRACT_MS="$5"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
        UPDATE meta.rag_processing_log
        SET extract_state = 'extracted',
            mcp_chain_file = '$MCP_CHAIN',
            slide_count = $SLIDE_COUNT,
            content_size = $CONTENT_SIZE,
            extract_ms = $EXTRACT_MS,
            updated_at = NOW()
        WHERE source_file = '$SOURCE_FILE' AND tenant_id = '$TENANT_ID';
    " 2>/dev/null
}

# ── DB: register extraction error ────────────────────────────────
log_extract_error() {
    local SOURCE_FILE="$1"
    local ERROR="$2"
    local SAFE_ERROR
    SAFE_ERROR=$(echo "$ERROR" | head -1 | sed "s/'/''/g" | cut -c1-500)
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
        UPDATE meta.rag_processing_log
        SET extract_state = 'error',
            error_detail = '$SAFE_ERROR',
            updated_at = NOW()
        WHERE source_file = '$SOURCE_FILE' AND tenant_id = '$TENANT_ID';
    " 2>/dev/null
}

# ── Extract and generate MCP for a single file ──────────────────
process_file() {
    local PPTX_PATH="$1"
    local FILENAME
    FILENAME=$(basename "$PPTX_PATH")

    # Skip duplicates
    if is_duplicate "$FILENAME"; then
        echo "   ⏭️  Skipping duplicate: $FILENAME"
        return
    fi

    local SLUG
    SLUG=$(slugify "$FILENAME")
    local MCP_FILE="${CHAIN_DIR}/pptx.${SLUG}.md"
    local MCP_BASENAME="pptx.${SLUG}.md"

    # Per-file MD5 checksum
    local FILE_MD5
    FILE_MD5=$(md5sum "$PPTX_PATH" 2>/dev/null | cut -d' ' -f1)

    # Check if file needs processing (DB-based dedup)
    if ! needs_processing "$FILENAME" "$FILE_MD5"; then
        echo "   ⏭️  Unchanged: $FILENAME (MD5: ${FILE_MD5:0:8}...)"
        return
    fi

    echo "📝 Processing: $FILENAME (MD5: ${FILE_MD5:0:8}...)"
    local START_MS
    START_MS=$(date +%s%N)

    # Register extraction start in DB
    local SAFE_PATH
    SAFE_PATH=$(echo "$PPTX_PATH" | sed "s/'/''/g")
    log_extract_start "$FILENAME" "$SAFE_PATH" "$FILE_MD5"

    # Extract slide content → temp JSON file (avoids shell variable overflow on large PPTX)
    local JSON_TMPFILE="/tmp/pptx_extract_$$.json"
    $EXTRACTOR "$PPTX_PATH" > "$JSON_TMPFILE" 2>/tmp/pptx_extract_err || {
        echo "   ❌ Extraction failed for $FILENAME"
        cat /tmp/pptx_extract_err 2>/dev/null
        log_extract_error "$FILENAME" "$(cat /tmp/pptx_extract_err 2>/dev/null)"
        rm -f "$JSON_TMPFILE"
        return
    }

    # Convert JSON to MCP chain Markdown (Python reads temp file directly)
    $PY -c "
import json, sys, os

with open('$JSON_TMPFILE', encoding='utf-8') as f:
    data = json.load(f)

filename = sys.argv[1]
slug = sys.argv[2]

lines = []
lines.append('### MODEL CONTEXT PROMPT (Technical Rules)')
lines.append(f'# pptx.{slug}')
lines.append(f'**Topic:** BDO Presentation: {filename}')
lines.append('')
lines.append('## Document Content')
lines.append('')

slide_count = 0
for slide_num in sorted(data.keys(), key=lambda x: int(x)):
    slide = data[slide_num]
    text = slide.get('Text', '').strip()
    if not text:
        continue
    slide_count += 1
    lines.append(f'### Slide {slide_num}')
    lines.append(text)
    lines.append('')

    comments = slide.get('Comments', [])
    if comments:
        lines.append('**Comments:**')
        for c in comments:
            author = c.get('author', 'Unknown')
            ctext = c.get('text', '')
            lines.append(f'- {author}: {ctext}')
        lines.append('')

print('\n'.join(lines))
print(f'SLIDE_COUNT={slide_count}', file=sys.stderr)
" "$FILENAME" "$SLUG" > "$MCP_FILE" 2>/tmp/pptx_slide_count

    rm -f "$JSON_TMPFILE"

    SLIDE_COUNT=$(grep 'SLIDE_COUNT=' /tmp/pptx_slide_count 2>/dev/null | cut -d= -f2 || echo 0)

    local SIZE
    SIZE=$(wc -c < "$MCP_FILE")

    # Calculate duration
    local END_MS
    END_MS=$(date +%s%N)
    local DURATION_MS=$(( (END_MS - START_MS) / 1000000 ))

    # Register success in DB
    log_extract_done "$FILENAME" "$MCP_BASENAME" "${SLIDE_COUNT:-0}" "$SIZE" "$DURATION_MS"

    echo "   ✅ → ${MCP_BASENAME} (${SIZE} bytes, ${SLIDE_COUNT:-0} slides, ${DURATION_MS}ms)"
}

# ── Single file mode ─────────────────────────────────────────────
if [ -n "$SINGLE_FILE" ]; then
    if [ ! -f "$SINGLE_FILE" ]; then
        SINGLE_FILE="$BASE_DIR/$SINGLE_FILE"
    fi
    if [ ! -f "$SINGLE_FILE" ]; then
        echo "❌ File not found: $SINGLE_FILE"
        exit 1
    fi
    process_file "$SINGLE_FILE"
    echo ""
    echo "✅ Single file processed."
    exit 0
fi

# ── Batch mode: process all PPTX files ──────────────────────────
if [ ! -d "$SOURCE_DIR" ]; then
    echo "❌ Source directory not found: $SOURCE_DIR"
    exit 1
fi

echo "🔍 Scanning for PPTX files..."
TOTAL=$(find "$SOURCE_DIR" -maxdepth 3 -name "*.pptx" -type f | wc -l)
echo "   Found $TOTAL PPTX files"
echo ""

find "$SOURCE_DIR" -maxdepth 3 -name "*.pptx" -type f | sort | while read -r PPTX_FILE; do
    process_file "$PPTX_FILE"
done

echo ""
echo "================================================================"
echo "  ✅ PPTX → MCP Chain generation complete"
echo "  Output: $CHAIN_DIR/pptx.*.md"
echo ""
echo "  View log:  bash scripts/pptx_to_mcp.sh --status"
echo "  Next step: bash scripts/embed_pptx.sh --force"
echo "================================================================"
