# Global Instructions

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

When you implement a feature, fix a bug, or complete an item from a project backlog (`projects/*-backlog.md`), remove the corresponding item from the backlog as part of the same commit. Keep the rest of the backlog untouched. If only part of a multi-part item is done, remove just that part.

After completing a backlog item, re-present the remaining backlog items so the user can pick the next one without having to ask again.

### Processing

Use `/hatch` to classify, enrich, and file items from `inbox/` into the correct folders.
