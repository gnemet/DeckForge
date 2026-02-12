# AGENT_ANTIGRAVITY_SPEC.md

## 1. Concept: The Antigravity Engine
The **Antigravity Agent** is the autonomous intelligence layer of DeckForge. Its purpose is to lift the "heavy" burden of content structuring from the user.

**Core Philosophy:**
> "The user provides the *Matter* (unstructured context). The Agent provides the *Form* (structured metadata)."

It sits between the **User Input** and the **DeckForge Compiler**.

---

## 2. Integration into Workflow

### The "Antigravity" Loop
1.  **Ingest:** User uploads raw context (financial reports, meeting notes, emails).
2.  **Anchor:** Agent loads the target **MCP Template** (e.g., `themes/FDD/slidemind/mcp_knowledge.json`).
3.  **Lift:** Agent maps raw context to the MCP's `input_metadata` schema.
4.  **Stabilize:** Agent validates output against `metadata_schema.json` constraints.
5.  **Land:** Agent outputs a `suggested_metadata.json` for Human Review.

---

## 3. Agent Responsibilities

| Responsibility | Description |
| :--- | :--- |
| **Context Parsing** | Extracting entities (Dates, Sums, Names) from unstructured text. |
| **Schema Compliance** | Ensuring generated JSON strictly matches the MCP requirements. |
| **Hallucination Check** | Verifying that "derived" values exist in the source text. |
| **Tone Adaptation** | Adjusting free-text fields (e.g., "Executive Summary") to match the Theme's voice. |

---

## 4. Prompt Engineering Strategy

The Agent does not "chat." It performs **Cognitive Tasks**.

### System Prompt Structure
The Agent is initialized with the **MCP Knowledge**:

```text
ROLE: You are the DeckForge "Antigravity" Engine.
CONTEXT: You are generating metadata for the theme "{{THEME_NAME}}".
CONSTRAINT: You must output ONLY valid JSON matching the provided schema.
KNOWLEDGE: Use the following MCP definitions for field requirements:
{{MCP_KNOWLEDGE_JSON}}
