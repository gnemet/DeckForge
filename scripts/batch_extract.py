#!/usr/bin/env python3
"""Batch extract all BDO PPTX files to MCP chain Markdown."""
import json, os, subprocess, sys, hashlib, time

EXTRACTOR = "/tmp/deckforge_context_extractor"
CHAIN_DIR = "/home/gnemet/GitHub/DeckForge/ai/mcp/chain"
SOURCE_DIR = "/home/gnemet/DeckForgeFiles/BDO"

os.makedirs(CHAIN_DIR, exist_ok=True)

def slugify(name):
    name = name.replace('.pptx', '').replace(' ', '_')
    return ''.join(c for c in name if c.isalnum() or c in '._-').lower()

def is_duplicate(name):
    return '(1)' in name or 'másolata' in name

# Find all PPTX files
pptx_files = []
for root, dirs, files in os.walk(SOURCE_DIR):
    for f in sorted(files):
        if f.endswith('.pptx'):
            pptx_files.append(os.path.join(root, f))

pptx_files.sort()
print(f"Found {len(pptx_files)} PPTX files in {SOURCE_DIR}")

count = 0
skipped = 0
errors = 0

for pptx_path in pptx_files:
    filename = os.path.basename(pptx_path)
    
    if is_duplicate(filename):
        skipped += 1
        print(f"  ⏭️  SKIP: {filename}")
        continue
    
    slug = slugify(filename)
    mcp_file = os.path.join(CHAIN_DIR, f"pptx.{slug}.md")
    
    # Extract
    t0 = time.time()
    try:
        result = subprocess.run([EXTRACTOR, pptx_path], capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"  ❌ FAIL: {filename} — {result.stderr[:100]}")
            errors += 1
            continue
        
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"  ❌ FAIL: {filename} — {e}")
        errors += 1
        continue
    
    # Convert to MCP chain markdown
    lines = [
        '### MODEL CONTEXT PROMPT (Technical Rules)',
        f'# pptx.{slug}',
        f'**Topic:** BDO Presentation: {filename}',
        '',
        '## Document Content',
        ''
    ]
    
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
    
    if slide_count == 0:
        print(f"  ⚠️  EMPTY: {filename} (no text slides)")
        continue
    
    with open(mcp_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    
    size = os.path.getsize(mcp_file)
    dt = int((time.time() - t0) * 1000)
    count += 1
    print(f"  ✅ [{count}] pptx.{slug}.md ({size} bytes, {slide_count} slides, {dt}ms)")

print(f"\n{'='*60}")
print(f"  ✅ Extracted {count} files ({skipped} skipped, {errors} errors)")
print(f"  Output: {CHAIN_DIR}/pptx.*.md")
print(f"{'='*60}")
