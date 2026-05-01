#!/usr/bin/env python3
"""Convert Markdown to styled HTML with Mermaid diagram support."""
import sys
import re
import markdown

if len(sys.argv) < 2:
    print("Usage: python3 md_to_pdf.py <input.md> [output.html]")
    sys.exit(1)

md_path = sys.argv[1]
html_path = sys.argv[2] if len(sys.argv) > 2 else md_path.replace('.md', '.html')

with open(md_path, 'r', encoding='utf-8') as f:
    md_content = f.read()

# Extract mermaid blocks before markdown processing
mermaid_blocks = {}
counter = [0]
def replace_mermaid(match):
    counter[0] += 1
    key = f"MERMAID_PLACEHOLDER_{counter[0]}"
    mermaid_blocks[key] = match.group(1).strip()
    return f"\n<div class='mermaid'>{mermaid_blocks[key]}</div>\n"

md_content = re.sub(r'```mermaid\n(.*?)```', replace_mermaid, md_content, flags=re.DOTALL)

html_body = markdown.markdown(md_content, extensions=[
    'tables', 'fenced_code', 'toc'
])

full_html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AI-Native PPTX Generation — DeckForge</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({{
    startOnLoad: true,
    theme: 'base',
    themeVariables: {{
      primaryColor: '#3b82f6',
      primaryTextColor: '#fff',
      primaryBorderColor: '#2563eb',
      lineColor: '#64748b',
      secondaryColor: '#f1f5f9',
      tertiaryColor: '#f8fafc',
      fontFamily: 'Segoe UI, sans-serif',
      fontSize: '14px'
    }}
  }});
</script>
<style>
  @media print {{
    @page {{ margin: 1.8cm; size: A4; }}
    body {{ font-size: 10pt; }}
    pre {{ page-break-inside: avoid; }}
    h2, h3 {{ page-break-after: avoid; }}
    table {{ page-break-inside: avoid; }}
    .mermaid {{ page-break-inside: avoid; }}
    .print-btn {{ display: none; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Arial, sans-serif;
    font-size: 11pt; line-height: 1.65; color: #1e293b;
    max-width: 960px; margin: 0 auto; padding: 40px 30px;
    background: #fff;
  }}
  h1 {{
    color: #0f172a; font-size: 26pt; font-weight: 700;
    border-bottom: 3px solid #3b82f6; padding-bottom: 12px; margin-top: 0;
  }}
  h2 {{
    color: #1e293b; font-size: 17pt; font-weight: 600;
    border-bottom: 2px solid #e2e8f0; padding-bottom: 8px; margin-top: 36px;
  }}
  h3 {{
    color: #334155; font-size: 13pt; font-weight: 600; margin-top: 24px;
  }}
  blockquote {{
    border-left: 4px solid #3b82f6; padding: 12px 20px;
    background: #f1f5f9; margin: 16px 0; font-style: italic; color: #475569;
    border-radius: 0 6px 6px 0;
  }}
  table {{
    border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 10pt;
  }}
  th {{
    background: #1e293b; color: white; padding: 10px 14px; text-align: left;
    font-weight: 600;
  }}
  td {{
    border: 1px solid #e2e8f0; padding: 8px 14px; color: #334155;
  }}
  tr:nth-child(even) {{ background: #f8fafc; }}
  tr:hover {{ background: #f1f5f9; }}
  code {{
    background: #f1f5f9; padding: 2px 6px; border-radius: 4px;
    font-family: 'Cascadia Code', 'Fira Code', Consolas, monospace; font-size: 9.5pt;
    color: #be185d;
  }}
  pre {{
    background: #0f172a; color: #e2e8f0; padding: 18px; border-radius: 8px;
    overflow-x: auto; font-size: 9pt; line-height: 1.5;
    border: 1px solid #1e293b;
  }}
  pre code {{ background: none; color: inherit; padding: 0; }}
  hr {{
    border: none; border-top: 2px solid #e2e8f0; margin: 32px 0;
  }}
  ul, ol {{ padding-left: 22px; }}
  li {{ margin-bottom: 6px; color: #334155; }}
  em {{ color: #64748b; }}
  strong {{ color: #0f172a; }}
  .mermaid {{
    text-align: center; margin: 24px 0; padding: 20px;
    background: #f8fafc; border-radius: 12px;
    border: 1px solid #e2e8f0;
  }}
  .print-btn {{
    position: fixed; top: 20px; right: 20px;
    background: #3b82f6; color: white; border: none;
    padding: 12px 24px; border-radius: 8px; font-size: 14px; font-weight: 600;
    cursor: pointer; box-shadow: 0 4px 12px rgba(59,130,246,0.3);
    z-index: 1000; transition: all 0.2s;
  }}
  .print-btn:hover {{ background: #2563eb; transform: translateY(-1px); }}
</style>
</head>
<body>
<button class="print-btn" onclick="window.print()">Print / Save as PDF</button>
{html_body}
</body>
</html>"""

with open(html_path, 'w', encoding='utf-8') as f:
    f.write(full_html)

print(f"HTML created: {html_path}")
