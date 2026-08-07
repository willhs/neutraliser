## [2026-04-12] lint | Docs audit
15 errors, 4 warnings, 4 suggestions across 27 files checked.

## [2026-04-12] fix | Apply docs-lint fixes
Rebuilt index.md (agent notice, linked entries, all 14 orphaned files added, 4 broken links removed). Created front-matter-schema.json. task-0001 status in_progress → complete. task-0002 Phase 2 codec note updated to reference ADR-0001 supersession. task-0005 context corrected to reflect benchmark outcomes.

## [2026-08-07] update | PlexAnalyzer folded into main pipeline; token-in-shell and sentinel-float bugs fixed
plex_analyzer.rb now routes through FFmpegWrapper/Measurement/Profiles/Logger instead of its own regex-parsed /tmp-file analysis, private TARGET_LEVELS/ACCEPTABLE_VARIANCE table, and bare puts/exit. Plex token no longer touches a shell string or argv (passed via HTTP header + ffmpeg -headers); -18.0/-20.0 sentinel-float failure detection replaced with nil/raise. Updated docs/design/plex-analysis-guide.md to match (--profile/--tolerance replace the old target-level table; removed never-implemented --concurrent-jobs/--cache-results).

## [2026-08-06] update | Repo hygiene for public visibility
Untracked .env (leaked Plex token — rotated), .idea/, and .claude/skills/check-prod (NAS SSH details). Scrubbed NAS IP from task-0005 context. Removed stray rspec state file from task-0002. Added LICENSE (MIT), filled gemspec/README identity, fixed stale ParallelProcessor row in architecture.md (parallel dispatch lives in Processor).
