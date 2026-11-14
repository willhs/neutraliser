---
id: docs-index-fragments
type: note
purpose: "Per-job index line fragments, stitched into docs/index.md by the land step"
tags: ["docs", "landing", "conflicts"]
---

# docs/index.d: per-job index fragments

**Do not edit `docs/index.md`.** Write `docs/index.d/<job-id>.md` instead; the land step appends
each line to the matching section of `docs/index.md`. Format and rules are in
[`../log.d/README.md`](../log.d/README.md); the index-specific parts are below.

```markdown
## Research

- [`research/0010-slug/research.md`](research/0010-slug/research.md): One-line summary.

!remove - [`old/doc.md`](old/doc.md): Line to delete
!replace - [`a.md`](a.md): old text => - [`a.md`](a.md): new text
```

The `## Section` line must name a section `docs/index.md` already has (a new name creates one at
the end of the file). A line already in the index is skipped, so a re-stitch is harmless.
