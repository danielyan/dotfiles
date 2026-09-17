# Global Instructions

## Development

When implementing a feature or fixing a bug in a software project, add tests for
the new functionality as part of the same work — whenever tests make sense for
what changed. Prefer testing pure, dependency-light logic; when a unit needs
isolation, add a small seam (dependency injection, extract a helper) rather than
skipping the test. Don't force tests onto code with no meaningful behavior to
assert (trivial glue, pure UI layout) — validate that some other way (e.g.
rendering a view to an image). Run the test suite and confirm it passes before
considering the work done. This applies going forward, not just when asked.

## Magpie

I have a personal knowledge base (Magpie — previously named "Hoarder") in my Obsidian vault at:
`/Users/ldan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes`

### Vault folders
- `inbox/` — raw captures (voice and share sheet)
- `restaurants/` — restaurants to try
- `recipes/` — recipes to cook
- `movies/` — movies to watch
- `shows/` — TV shows to watch
- `documentaries/` — documentaries and docuseries to watch
- `watch-later/` — YouTube and other video content
- `read/` — books to read
- `read-later/` — articles and blog posts saved for reading
- `projects/` — project ideas
- `travel/` — travel ideas
- `products/` — products to buy
- `house/` — home to-dos and projects
- `general/` — uncategorized items
- `failed/` — items that failed enrichment, awaiting retry
- `raw/` — archived binary source files (images, PDFs) preserved forever
- `synthesis/` — LLM-generated pages surfacing patterns across items
- `templates/` — frontmatter templates per category

### Querying

When I ask questions about my Magpie vault — like "what should I cook?", "recommend a movie", "what restaurants do I want to try?", "what's in my inbox?" — read the relevant vault folders, filter by YAML frontmatter fields, and answer from what's actually in the vault. Never make up items. Default to uncompleted items (status: to-watch, to-try, to-cook, etc.) unless I ask about past items.

Before answering, check `synthesis/` for existing query-result notes that match the question — prior analyses may provide context or a starting point to build on rather than re-deriving from scratch.

After answering a substantial query (a recommendation with reasoning, a comparison, a filtered analysis — not a simple count or list), ask: "Want me to save this?" If yes, write a note to `synthesis/` named `query-{kebab-topic}.md` with frontmatter `type: synthesis`, `scope: query-result`, and wikilinks to all referenced items.

### Working on projects

When I ask to "work on" a project (e.g., "work on Awesome App backlog", "let's fix that Awesome App bug"), check `projects/` for a matching project note. If it has a `path` field, navigate to that directory to read code, run commands, and implement changes. The project note's backlog has the bugs/features to work from.

When you implement a feature, fix a bug, or complete an item from a project note (`projects/project-*.md`), remove the corresponding item from that note's Bugs / Feature Requests / Backlog section as part of the same commit. Keep the rest of the note untouched. If only part of a multi-part item is done, remove just that part.

After completing a backlog item, re-present the remaining backlog items so the user can pick the next one without having to ask again.

If the current session's working directory is not the project's `path` (e.g., I'm in `~/projects/magpie` and ask to work on Fresco), suggest starting a fresh session there so sessions stay one-project-per-folder — Claude Code keys session history by working directory, so this keeps `claude -c` and `--resume` scoped to the project on both machines. Before doing any work, show the suggestion boxed in an ASCII border, then stop and wait for my reply:

```
╔══════════════════════════════════════════════════════════════╗
║  ⚠  WRONG FOLDER FOR THIS PROJECT                            ║
║                                                              ║
║  This session is in:  ~/projects/magpie                      ║
║  Fresco lives in:     ~/projects/fresco                      ║
║                                                              ║
║  Start a fresh session there (new tmux window if in tmux):   ║
║    cd ~/projects/fresco && claude                            ║
║                                                              ║
║  Reply "stay" to continue here instead.                      ║
╚══════════════════════════════════════════════════════════════╝
```

Don't proceed until I acknowledge. Ask once per project per session; if I say stay, carry on without asking again.

### Processing

Use `/hatch` to classify, enrich, and file items from `inbox/` into the correct folders.
