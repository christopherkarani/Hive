Hive is the swift equivalent of Langraph a python framework

Always
1. Use swift 6.2 best practices

Do NOT:
1. Edit Plan Documents

---

## WaxMCP Memory Protocol (Mandatory)

Use the WaxMCP tools to persist and retrieve context across sessions. This prevents context loss during long-running tasks and enables continuity when resuming work.

### Tool Reference

| Tool | Purpose | Key Params |
|------|---------|------------|
| `wax_remember` | Store a memory | `content` (text), `metadata` (dict) |
| `wax_recall` | Retrieve memories by semantic query | `query` (text), `limit` (int) |
| `wax_search` | Raw search hits (text or hybrid) | `query` (text) |
| `wax_flush` | Persist pending writes to disk | — |
| `wax_stats` | Check memory system state | — |

### When to Write (`wax_remember`)

Call `wax_remember` at these mandatory checkpoints:

- **Plan start** — Store the plan outline before beginning implementation
- **Task completion** — Record what was done, files changed, and outcome
- **Key decisions** — Capture rationale for architectural or design choices
- **Discoveries** — Log unexpected findings, gotchas, or codebase patterns
- **Errors and fixes** — Record root cause + fix so future sessions don't re-investigate
- **To-do items** — Store deferred work and open questions before context compacts

### When to Read (`wax_recall` / `wax_search`)

Call `wax_recall` or `wax_search` at these mandatory checkpoints:

- **Session start** — Query for recent context on the current project before doing any work
- **Before planning** — Check for prior plans, decisions, and deferred items
- **Context feels stale** — When unsure about earlier decisions or state, query rather than guess
- **Resuming interrupted work** — Always recall before continuing a previously paused task

### Metadata Convention

Always include these metadata keys for searchability:

```json
{
  "project": "<project-name>",
  "type": "plan | decision | discovery | bugfix | todo | completion",
  "phase": "planning | implementing | reviewing | debugging"
}
```

### Flush Discipline

Call `wax_flush` to ensure writes are durable:

- After storing 3+ memories in sequence
- Before ending a session or switching projects
- Before any operation that may trigger context compaction
- After storing critical decisions or error resolutions