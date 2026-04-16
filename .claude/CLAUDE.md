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
- `buy/` — products to buy
- `house/` — home to-dos and projects
- `general/` — uncategorized items
- `failed/` — items that failed enrichment, awaiting retry
- `templates/` — frontmatter templates per category

### Querying

When I ask questions about my Magpie vault — like "what should I cook?", "recommend a movie", "what restaurants do I want to try?", "what's in my inbox?" — read the relevant vault folders, filter by YAML frontmatter fields, and answer from what's actually in the vault. Never make up items. Default to uncompleted items (status: to-watch, to-try, to-cook, etc.) unless I ask about past items.

### Processing

Use `/process-inbox` to classify, enrich, and file items from `inbox/` into the correct folders.
