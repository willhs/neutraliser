---
id: roadmap
type: note
purpose: "Where neutraliser is heading and the criteria that must pass before 0.1 is tagged."
---
# Roadmap

Direction: [vision](../philosophy/vision.md). Basis: [research 0002](../research/0002-streaming-loudness-and-dialogue/research.md).

## Route to the default in the vision

1. Fix the Dolby DRC and dialnorm bugs.
2. Add a read-only dialogue estimate.
3. Validate it on real files.
4. Switch the default only if the validation holds.

No default changes before step 4. `--keep-original-audio` stays an option, and the defaults for other people's libraries stay cautious on Atmos, DTS and TrueHD.

## 0.1 criteria

0.1 is tagged when these pass, not on a date. The tag is not dated in the changelog.

- The maintainer watches Lost S5, Breaking Bad S5 and two films without touching the remote.
- At least 90% of a random 100-file sample, including movies, lands on target. Measured on the output (`rate-sample`, `report --measure`), and revisited when real results exist.
- No format is left unlevelled without a stated reason.
- Recipes are versioned.
- CI is green, including tests on real files.
- The docs match the behaviour.
- One other person has installed it.
