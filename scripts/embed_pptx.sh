#!/bin/bash
# ================================================================
# PPTX MCP Chain Embedding Script
# ================================================================
# Reads PPTX MCP chain files, calls Gemini embedding API,
# inserts vectors into meta.mcp_embeddings table (collection='pptx').
#
# Usage:
#   source .env
#   bash scripts/embed_pptx.sh                   # embed all pptx chains
#   bash scripts/embed_pptx.sh --force            # re-embed all
#   bash scripts/embed_pptx.sh --query "BDO offer pricing"
#
# Prerequisites:
#   - Run scripts/pptx_to_mcp.sh first to generate chain files
#   - pgvector installed and meta.mcp_embeddings table exists
#   - GEMINI_KEY set in environment
# ================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CHAIN_DIR="${BASE_DIR}/ai/mcp/chain"
COLLECTION="pptx"
CHECKSUM_FILE="${BASE_DIR}/.pptx_rag_checksum"
PY="/usr/bin/python3"

# Load environment
if [ -f "$BASE_DIR/.env" ]; then
    source "$BASE_DIR/.env"
fi

# DB Config — target SaaS-isolated bdo_db (separate from jiramntr's db01)
# Priority: PPTX_RAG_PG_* > RAG_PG_* > hardcoded defaults
DB_HOST="${PPTX_RAG_PG_HOST:-${RAG_PG_HOST:-localhost}}"
DB_PORT="${PPTX_RAG_PG_PORT:-${RAG_PG_PORT:-5433}}"
DB_NAME="${PPTX_RAG_PG_DB:-${RAG_PG_DB:-bdo_db}}"
DB_USER="${PPTX_RAG_PG_USER:-${RAG_PG_USER:-root}}"
DB_PASS="${PPTX_RAG_PG_PASSWORD:-${RAG_PG_PASSWORD:-soa123}}"
TENANT_ID="${TENANT_ID:-BDO}"
GEMINI_EMBED_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent"

# Validate
if [ -z "$GEMINI_KEY" ]; then
    echo "❌ GEMINI_KEY not set. Source your .env file first."
    exit 1
fi

# Helper: call Gemini embedding API and return vector string
get_embedding() {
    local TEXT="$1"
    local ESCAPED
    ESCAPED=$(echo "$TEXT" | $PY -c "import sys,json; print(json.dumps(sys.stdin.read()))")

    local RESPONSE
    RESPONSE=$(curl -s "${GEMINI_EMBED_URL}?key=${GEMINI_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"content\":{\"parts\":[{\"text\":${ESCAPED}}]}}")

    echo "$RESPONSE" | $PY -c "
import sys, json
data = json.load(sys.stdin)
if 'embedding' in data:
    vals = data['embedding']['values']
    print('[' + ','.join(str(v) for v in vals) + ']')
else:
    print('ERROR: ' + json.dumps(data), file=sys.stderr)
    sys.exit(1)
" 2>&1
}

# ─── Query Mode ──────────────────────────────────────────────────
if [ "$1" = "--query" ] && [ -n "$2" ]; then
    QUERY="$2"
    TOP_K="${3:-5}"

    echo "🔍 Query: \"$QUERY\""
    echo "   Top-K: $TOP_K"
    echo "   Collection: $COLLECTION"
    echo ""

    EMBEDDING=$(get_embedding "$QUERY")

    if echo "$EMBEDDING" | grep -q "ERROR"; then
        echo "❌ Embedding failed: $EMBEDDING"
        exit 1
    fi

    DIM=$(echo "$EMBEDDING" | tr ',' '\n' | wc -l)
    echo "   Dimensions: $DIM"
    echo ""

    echo "📊 Results:"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --tuples-only -c "
        SELECT
            collection,
            topic,
            LEFT(description, 60) AS description,
            ROUND((1 - (embedding <=> '${EMBEDDING}'::vector))::numeric, 3) AS score
        FROM meta.mcp_embeddings
        WHERE embedding IS NOT NULL
          AND collection = '${COLLECTION}'
        ORDER BY embedding <=> '${EMBEDDING}'::vector
        LIMIT ${TOP_K};
    "
    exit 0
fi

# ─── Embed Mode (default) ───────────────────────────────────────
echo "================================================================"
echo "  PPTX MCP Chain Embedding Pipeline (Gemini → pgvector)"
echo "================================================================"
echo "  Chain dir:   $CHAIN_DIR"
echo "  DB:          $DB_HOST:$DB_PORT/$DB_NAME"
echo "  Collection:  $COLLECTION"
echo "  API:         Gemini gemini-embedding-001"
echo ""

# Check chain directory has files
CHAIN_FILES=$(find "$CHAIN_DIR" -name "pptx.*.md" 2>/dev/null | wc -l)
if [ "$CHAIN_FILES" -eq 0 ]; then
    echo "❌ No pptx.*.md files found in $CHAIN_DIR"
    echo "   Run first: bash scripts/pptx_to_mcp.sh"
    exit 1
fi
echo "  Found $CHAIN_FILES chain files"
echo ""

# ─── MD5 Change Detection ───────────────────────────────────────
CURRENT_CHECKSUM=$(find "$CHAIN_DIR" -name "pptx.*.md" -print0 2>/dev/null | sort -z | xargs -0 md5sum 2>/dev/null | md5sum | cut -d' ' -f1)

FORCE_EMBED=false
for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE_EMBED=true
    fi
done

if [ "$FORCE_EMBED" = "false" ] && [ -f "$CHECKSUM_FILE" ]; then
    STORED_CHECKSUM=$(cat "$CHECKSUM_FILE" 2>/dev/null)
    if [ "$CURRENT_CHECKSUM" = "$STORED_CHECKSUM" ]; then
        echo "✅ Chain files unchanged (MD5: ${CURRENT_CHECKSUM:0:8}...). Skipping."
        echo "   Use --force to override."
        exit 0
    fi
    echo "🔄 Chain files changed (${STORED_CHECKSUM:0:8}→${CURRENT_CHECKSUM:0:8}). Re-embedding..."
else
    echo "🆕 First embedding or --force flag used."
fi
echo ""

# ─── Process each PPTX chain MCP ────────────────────────────────
COUNT=0
ERRORS=0

for MCP_FILE in "$CHAIN_DIR"/pptx.*.md; do
    if [ ! -f "$MCP_FILE" ]; then
        continue
    fi

    FILENAME=$(basename "$MCP_FILE")
    TOPIC="${FILENAME%.md}"         # e.g. pptx.alfa_biztosito_ajanlat_v3

    # Derive original PPTX source file from topic
    # pptx.acme_offer → acme_offer → look up in processing log
    SOURCE_PPTX=$(echo "$TOPIC" | sed 's/^pptx\.//')

    echo "📝 Embedding: $FILENAME"
    EMBED_START=$(date +%s%N)

    # Update processing log: embed_state = 'embedding'
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
        UPDATE meta.rag_processing_log
        SET embed_state = 'embedding', updated_at = NOW()
        WHERE mcp_chain_file = '$FILENAME' AND tenant_id = '$TENANT_ID';
    " 2>/dev/null

    # Read file content
    CONTENT=$(cat "$MCP_FILE")
    CONTENT_SIZE=${#CONTENT}

    # Extract description from Topic line
    DESCRIPTION=$(grep -m1 "^\*\*Topic:\*\*" "$MCP_FILE" | sed 's/\*\*Topic:\*\* //' || echo "$TOPIC")

    # Call Gemini embedding API
    EMBEDDING=$(get_embedding "$CONTENT")

    if echo "$EMBEDDING" | grep -q "ERROR"; then
        echo "   ❌ Embedding failed: $EMBEDDING"
        ERRORS=$((ERRORS + 1))
        # Log error to processing log
        SAFE_ERR=$(echo "$EMBEDDING" | head -1 | sed "s/'/''/g" | cut -c1-500)
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
            UPDATE meta.rag_processing_log
            SET embed_state = 'error', error_detail = '$SAFE_ERR', updated_at = NOW()
            WHERE mcp_chain_file = '$FILENAME' AND tenant_id = '$TENANT_ID';
        " 2>/dev/null
        sleep 2
        continue
    fi

    DIM=$(echo "$EMBEDDING" | tr ',' '\n' | wc -l)

    # Insert into pgvector using Python for safe SQL escaping
    $PY -c "
import subprocess, sys, os

content = open('$MCP_FILE', encoding='utf-8').read()
desc = '''$DESCRIPTION'''

safe_content = content.replace(\"'\", \"''\")
safe_desc = desc.replace(\"'\", \"''\")

final_sql = f\"\"\"
INSERT INTO meta.mcp_embeddings (tenant_id, collection, source_file, topic, description, content, embedding, updated_at)
VALUES ('$TENANT_ID', '$COLLECTION', '$FILENAME', '$TOPIC', '{safe_desc}', '{safe_content}', '$EMBEDDING'::vector, NOW())
ON CONFLICT (source_file, tenant_id) DO UPDATE SET
    collection = EXCLUDED.collection,
    topic = EXCLUDED.topic,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    embedding = EXCLUDED.embedding,
    updated_at = NOW();
\"\"\"

result = subprocess.run([
    'psql', '-h', '$DB_HOST', '-p', '$DB_PORT', '-U', '$DB_USER', '-d', '$DB_NAME', '-q', '-c', final_sql
], env={**os.environ, 'PGPASSWORD': '$DB_PASS'}, capture_output=True, text=True)

if result.returncode != 0:
    print(f'SQL Error: {result.stderr}', file=sys.stderr)
    sys.exit(1)
"

    # Calculate embed duration
    EMBED_END=$(date +%s%N)
    EMBED_MS=$(( (EMBED_END - EMBED_START) / 1000000 ))

    # Update processing log: embed_state = 'embedded'
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
        UPDATE meta.rag_processing_log
        SET embed_state = 'embedded',
            embed_dims = $DIM,
            embed_ms = $EMBED_MS,
            error_detail = NULL,
            updated_at = NOW()
        WHERE mcp_chain_file = '$FILENAME' AND tenant_id = '$TENANT_ID';
    " 2>/dev/null

    echo "   ✅ ${TOPIC} (${CONTENT_SIZE} chars, ${DIM} dims, ${EMBED_MS}ms)"
    COUNT=$((COUNT + 1))

    # Rate limiting: small delay between API calls
    sleep 0.5
done

echo ""
echo "================================================================"
echo "  ✅ Embedded $COUNT PPTX chains into meta.mcp_embeddings"
if [ "$ERRORS" -gt 0 ]; then
    echo "  ⚠️  $ERRORS files had errors"
fi
echo ""

# Save checksum
echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "  Checksum saved: ${CURRENT_CHECKSUM:0:8}..."
echo ""
echo "  Test with:"
echo "    bash scripts/embed_pptx.sh --query \"BDO offer pricing\""
echo ""
echo "  Verify in DB:"
echo "    PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c \\"
echo "      \"SELECT collection, topic, length(content) FROM meta.mcp_embeddings WHERE collection='pptx';\""
echo "================================================================"
