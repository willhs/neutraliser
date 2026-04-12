---
created: 2026-03-07
updated: 2026-03-07
---

# Local NVMe Staging and Single-Pass Fast Mode

## Goal

Reduce per-file processing time for large batches on NAS by (1) staging files to local NVMe for processing instead of reading/writing over SMB, and (2) offering a single-pass loudnorm mode that skips the measurement pass.

## Context

Neutraliser runs on a NAS (Intel i5-8600T, 16GB RAM, 238GB NVMe) processing video files from a 7.3TB SMB share (`//<nas>/media` mounted at `/mnt/nas/media`). The SMB link (~110 MB/s) was hypothesised as the dominant bottleneck — each file requires two full reads over the network (measurement + normalization) plus one full write back.

Two approaches were prototyped. Benchmarks showed `--fast` (single-pass loudnorm) is the clear winner at 30–37% faster. `--local-stage` showed no benefit on this setup — at ~110 MB/s SMB the CPU is the bottleneck, not I/O, and the staging copy overhead eats any savings. Full benchmark results are in ADR-0002. `--local-stage` is kept as it may help on slower network mounts.

Single-pass loudnorm halves the work by skipping the measurement pass entirely, at the cost of using dynamic gain adjustment instead of linear gain.

## Requirements

### Must Have
- `--local-stage` CLI flag that copies files to local temp before processing
- `--fast` CLI flag that uses single-pass loudnorm (no measurement pass)
- Both flags work independently and together
- Cache lookups still use the original file path (not the staged path)
- Cleanup of local staged files on success and failure

### Should Have
- Sensible default staging directory (`/tmp/neutraliser_staging`)
- Works with `--replace` mode (stage out replaces original)

### Could Have
- Configurable staging directory path

## Constraints

- Single-pass loudnorm uses dynamic compression, not linear gain — slightly less accurate
- Local NVMe has 200GB free — sufficient for staging but not unlimited
- Must not break existing two-pass accuracy when `--fast` is not used

## Success Criteria

- [ ] `--local-stage` copies file to local NVMe, processes locally, copies result back
- [ ] `--fast` processes files in a single FFmpeg pass
- [ ] Both flags combined work correctly
- [ ] All existing tests continue to pass
- [ ] Cache sidecars are read/written next to original files, not staged copies
