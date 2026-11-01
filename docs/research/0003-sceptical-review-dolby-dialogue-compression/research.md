---
id: sceptical-review-dolby-dialogue-compression
type: note
purpose: "Whether the Dolby fix, the dialogue estimate, opt-in compression and recipes hold up on real-ffmpeg fixtures before a library sweep restarts, what was fixed, and whether the sweep is safe to restart."
scope:
  - "Commits f126fe0, 68298c7, 80a6b29, 20bdf5b and dbfb20e, run on generated clips with real ffmpeg"
  - "The sweep driver's flags and the two flags planned for it, --allow-codec-change and --allow-object-audio-loss"
non_goals:
  - "No real library or NAS access, no sweep restart, no tag or post, no judgement of how anything sounds"
tags: ["research", "review", "dolby", "drc", "dialnorm", "compression", "recipes", "sweep"]
related:
  - "docs/research/0002-streaming-loudness-and-dialogue/research.md"
  - "docs/research/compression-ladder-fixtures-2026-11.md"
  - "docs/ops/data_contracts.md"
---

# Sceptical review of the Dolby fix, dialogue estimate and opt-in compression

Reviewed 2026-11-01 and 02. Vision alignment: Have an online presence (goal: Release neutraliser publicly). Originals aren't kept on the library this runs over, so a bug here is permanent.

## Verdict

**Is the sweep safe to restart on technical grounds? Yes, once the host is running the fixed image, and not before.**

- **The code holds, with this fix in.** With the driver's flags plus `--allow-codec-change` and `--allow-object-audio-loss`, nothing I ran now damages audio beyond what those flags ask for. DRC is off on every path, dialnorm survives every path, and `linear` is one gain to -138 dBFS. One bug on that path was found and fixed here: a failed dialnorm read used to reset dialnorm (finding 3).
- **The driver can miss the fix.** It runs `docker run ghcr.io/willhs/neutraliser:latest` and never pulls, so it uses whatever image the host last pulled. A pre-fix image re-bakes DRC (LRA 20 to 12 LU, dialnorm -24 to -31) and exits 0 (finding 1). [Do the restart checklist](#restart-checklist) first.
- **`--lra-target` is not cleared for the library.** Its worst bug is fixed, but only ears can say how it sounds, and the driver doesn't pass it.
- **All of this is on synthetic clips.** [Some questions need real files or ears](#what-this-review-cannot-know).

Ten findings are fixed, each shown failing first, two of them by adding a stamp field. None needed a change to constant-gain audio.

## Findings by severity

"Fixed" means a spec went red on the old code and is green now. Output is from the lab scripts in [`lab/`](lab/); full output is in [`lab/results/before/`](lab/results/before/) and [`lab/results/after/`](lab/results/after/). ffmpeg 7.1.1 unless it says otherwise.

| # | Severity | Finding | State |
|---|---|---|---|
| 1 | **Blocks restart** | The driver never pulls, and a pre-fix image re-bakes DRC | **Open: your step**, on a host and in a repo this job doesn't touch |
| 2 | **High** (opt-in) | Compression's search picks the wrong rung, and can widen the range | Fixed |
| 3 | **High** | A dialnorm read that fails for an unrelated reason resets dialnorm for good | Fixed |
| 4 | **High** (decision) | Work and verdicts from before the fix aren't revisited by a restart | **Open: your call** |
| 5 | Medium | Computed rate flatters dynamic files and is nonsense for compressed ones | Fixed |
| 6 | Medium | `rate-sample` credits a recipe with what earlier runs did | Fixed |
| 7 | Medium | A second pass stamps `linear` over compressed audio, or recipe 2 over baked-in DRC | Fixed |
| 8 | Medium | `--resume` ignores `--redo-recipe` and `--lra-target` | Fixed |
| 9 | Low | `import-manifest` claims the current recipe | Fixed |
| 10 | Low | Dialogue estimate reads the wrong channel on two layouts and understates its own error | Fixed |
| 11 | Low | CI has been red on `main` since 68298c7 (test fixture only) | Fixed |
| 12 | Low | Nothing records that a flatten dropped Atmos | Fixed |
| 13 | Low | 7.1 DD+, and 7.1 lossless in MP4, fail every sweep (safely) | Open |
| 14 | Low | 7.1 is measured without its side channels | Open |
| 15 | Low | Only the first frames' dialnorm is read | Open |
| 16 | Note | LRA has a cliff at its gate | Open |
| 17 | Note | The dialogue-anchored rate can barely pass a -20 LUFS library | Open |

### 1. The driver never pulls, and a pre-fix image re-bakes DRC

`neutralise-driver.sh` in `media-server` runs `IMAGE=ghcr.io/willhs/neutraliser:latest` with `docker run` and has no `docker pull`. `:latest` on a host means the last one pulled. This machine's own copy, built 2026-10-31, has no `dolby_stream.rb`, so it stands in for a host that hasn't pulled. The driver's flags over a clip with DRC words:

```
run                           exit  mode    recipe       out_LRA  out_I  dialnorm
image as last pulled          0     linear  unversioned  12.0     -22.5  -31
same base, this tree mounted  0     linear  2            20.1     -20.0  -24
```

The first row is exit 0 and stamped `linear`, with the damage the fix was written to stop. I can't read what the host has: that's off limits to this job. See [the checklist](#restart-checklist).

Pulling at the start of each run would swap the method mid-sweep whenever `main` moves, so I'd pin the digest and bump it by hand.

### 2. Compression's search picks the wrong rung, and can widen the range

`Compression` bisected the ladder on the claim "LRA falls monotonically down the ladder". It doesn't. My explanation, which fits the numbers but which I didn't isolate: compressing the loud parts pulls the level down, which lets quiet parts back over the LRA gate. LRA per rung, gentle to extreme:

```
clip                                  I      LRA   rungs                       monotonic
film-like 5.1 (LraFixture)            -22.1  14.6  9.1 8.7 8.4 8.3 8.1 7.9     true
two levels, 20 LU apart               -29.1  20.0  15.1 12.4 9.1 6.0 4.0 2.8   true
loud bursts over a very quiet bed     -27.0  4.8   4.7 4.7 4.8 21.1 17.2 12.8  false
three levels, quiet tail 30 dB down   -31.5  11.7  9.5 20.9 17.2 13.1 9.2 5.6  false
```

Through the real CLI, before and after:

```
clip                             limit  rung before  ebur128 before -> after   rung after  ebur128 before -> after
three levels, quiet tail         8+2    severe       13.3 -> 9.1               gentle      13.2 -> 9.1
loud bursts, bed under the gate  3+1    extreme      7.8 -> 12.7               none        7.6 -> 7.6
```

The first picked 6:1 where 2.5:1 reached the target. The second applied the harshest rung because the target was out of reach, and made the range wider, permanently.

**Fix:** walk up from the gentle end, since the gentlest rung that passes can only be found from there. When nothing reaches the target, take the rung that narrows most. When none narrows by `--tolerance`, don't compress, and level the file as usual. Cost goes from at most 3 reads to 1 to 6: a target `gentle` reaches is cheaper, an unreachable one dearer.

**No recipe bump.** No library file has been through `--lra-target`, and "recipe 2" is what proves a restart has the DRC fix, so a 3 would only blur that.

**Still poor, left for ears:** on the film-like clip a target of 6 lands on `severe` or `extreme` depending on the noise, 6:1 or 8:1, for about 1.2 LU more than `gentle` gets. Stronger rungs need big gains: `extreme` took +32 dB and, without a limiter, landed at -23.3 for a -20 target, which the log reports as a shortfall. Nothing clipped: the highest true peak in any run was -0.4 dBTP, from `extreme` with `--limit-db 4` after the AC-3 encode, so the -1.5 ceiling isn't held on that path.

### 3. A dialnorm read that fails for an unrelated reason resets dialnorm for good

The fix read the source's dialnorm, and on any failure logged it and carried on. So a failure that says nothing about the file became permanent. With only that one read made to fail:

```
BEFORE  exit 0; Could not read the source dialnorm (Dialnorm read failed (exit 1): No space left on device); the output gets the encoder's -31
        file REPLACED; dialnorm now -31; stamp "linear", stamped dialnorm nil
AFTER   exit 1; FFmpeg error processing file: Dialnorm read failed (exit 1): No space left on device
        file untouched; dialnorm now -24; stamp nil, stamped dialnorm nil
```

This is on the sweep's path, and it isn't theoretical: the read needs a temp folder inside the container, and this machine's Docker disk filled up during this review, which is how it surfaced. A sweep that hit a full disk or a slow moment would have reset each Dolby file it touched, with exit 0.

**Fix:** only a track whose frames really hold no dialnorm gets the encoder's default, because no retry changes that. Any other failure fails the file, leaves it alone, and the next sweep tries again. So a host with a full temp disk now shows a run of failures, where before it did quiet damage.

### 4. Work and verdicts from before the fix aren't revisited by a restart

By design, a run never re-levels because of a recipe. That leaves two groups, and they differ:

**Re-encoded before the fix (recipe 1, unversioned, or the retired script).** Damage is real and permanent. Made here with the real older code:

```
file              mode    recipe       stamp_dialnorm  stream_dialnorm  LRA   I
untouched.mkv     -       -            -               -24              20.0  -29.2
legacy_stamp.mkv  linear  unversioned  -               -31              12.0  -22.5
recipe1.mkv       linear  1            -               -31              12.0  -22.5
recipe2.mkv       linear  2            -24             -24              20.1  -20.0
```

`--redo-recipe` can't restore these: the DRC is in the samples and the source's dialnorm is gone. To count them, filter `report --format tsv` on `source_codec` of `ac3` or `eac3` and `recipe` blank or below 2. The retired script's files carry no stamp, so they read as untouched and can't be counted this way. These `linear` stamps are false, in the way this review was asked to look for. Nothing rewrites them: the recipe is what marks them.

**Left alone as within tolerance before the fix.** Their audio is untouched, but the verdict was read with DRC on, and it stands on restart:

```
Target -42.8: recipe 1 read the clip with DRC on and left it, sidecar {"recipe"=>1, "tolerance"=>2, ...}. The truth is -29.2, 13.6 LU away.
Restart, driver flags: bytes same: Already processed
Restart with --redo-recipe 1: bytes changed, Replaced, now I -42.7 LRA 20.1 dialnorm -24, stamp linear
```

The 13.6 LU is this fixture's extreme DRC; real tracks will differ. A redo fully repairs this group, because nothing was lost.

**Your call:** add `--redo-recipe 1,unversioned` to the restart. I'd do it once, since it's the only way those verdicts get corrected and it is safe for the damaged group: re-measured, they're at target or peak-capped, so they aren't re-encoded (lab 04: `same` bytes for both). The cost is a full measure of every older file, about 20 minutes a film by the driver's own comment.

### 5. Computed rate flatters dynamic files and is nonsense for compressed ones

`report` without `--measure` computes where a file landed from its stamp. Target -20, LRA limit 12:

```
case                  state       computed_I  computed_LRA  measured_I  measured_LRA  computed_verdict  measured_verdict
linear                linear      -20.0       20.0          -20.0       20.0          false             false
linear, peak-capped   linear      -20.3       8.3           -20.3       8.3           true              true
compressed            compressed  -5.7        20.0          -21.8       8.9           false             true
compressed + limiter  compressed  -14.1       8.3           -20.0       2.0           false             true
dynamic               dynamic     -20.0       12.0          -20.2       15.4          true              false
dynamic --fast        dynamic     -20.0       12.0          -26.0       15.4          true              false
```

Constant gain is exact. The two dynamic rows are the flattery: remote-free on paper, not in the file. The compressed rows add a level from before the compressor to a gain from after it.

**Fix:** only `linear` stamps and left records are computed; the rest read "not judged" until `--measure`. That moves files out of the denominator, which can flatter too: on a small library, computed said 100% (3 of 3) where measuring said 75%. So the summary now adds the floor: `at worst 75.0% of all 4 files`.

Left-alone files with no levels (Atmos, codec change) and imported ones are not judged either, so **computed rates on a part-swept library are a weak signal; use `--measure`.**

### 6. `rate-sample` credits a recipe with what earlier runs did

Picks an earlier run stamped are skipped, then measured anyway. Asked to try `--allow-dynamic` on a part-swept library, it reported four files, three of them `linear`, and the only sign was `skipped=3` in a log line. On a library part-swept by another recipe, the figure answers the wrong question.

**Fix:** those copies are left out of the rate and counted apart: `3 sampled file(s) were already normalised by an earlier run and are left out`. The library stayed byte-identical in every run.

**Gap, not fixed:** `rate-sample` refuses `--lra-target` (`'--lra-target' is not a directory`), so a compression recipe can't be sampled yet. It errors rather than ignoring it, so no wrong figure comes out.

### 7. A second pass stamps `linear` over compressed audio, or recipe 2 over baked-in DRC

The first-pass answer to "is there a stamped `linear` that isn't?" is no (see [what held](#what-held)). The second-pass answer was yes, because a stamp only described the last pass:

```
first_flags  first_mode  src_LRA  after_LRA  second_mode  final_LRA
compressed   compressed  26.0     7.2        linear       7.2

file      mode    recipe  stamp_dialnorm  stream_dialnorm  LRA
film.mkv  linear  1       -               -31              12.0   (recipe 1 run)
film.mkv  linear  2       -31             -31              12.1   (re-encoded by a redo)
```

The last row is worst. Recipe 2 claims no DRC was baked, and `SOURCE_DIALNORM=-31` was the old encoder's reset, not the film's -24. That wipes the one marker that could find the file later.

**Fix:** a new tag, `NEUTRALISER_PRIOR=1:linear,2:compressed/gentle`, lists every earlier pass. `report` counts them, and a later `--lra-target` won't compress audio that lists `compressed` (it could have stacked before). `mode` still means this pass, so counts and skip logic don't move.

Files the retired script made carry no stamp, so a re-encode can't name them.

### 8. `--resume` ignores `--redo-recipe` and `--lra-target`

```
--resume --redo-recipe 1: looked at the recipe-1 file? false (Resume mode: skipping 1 completed file(s))
--resume --lra-target 8 over an uncompressed LRA 12.0 file: looked at it? false (Resume mode: skipping 1 completed file(s))
```

The manifest's `normalized` was final no matter what the run asked. **Fix:** those runs go back through `SkipDecider`, one probe each, so a file this redo already did still isn't redone. The driver doesn't pass `--resume`, so the sweep wasn't exposed.

### 9. `import-manifest` claims the current recipe

```
sidecar recipe for a neutralise.sh file imported today: 2 (nil = unversioned)
```

That hides a file the retired script made from `--redo-recipe unversioned`. The 2026-10-28 import predates recipes, so its entries are correctly unversioned; only an import from now on would have been wrong. **Fix:** imports carry no recipe.

### 10. Dialogue estimate reads the wrong channel on two layouts and understates its error

Against 23 layouts, 21 were right, including every common one:

```
asked       estimate   verdict
6.0(front)  reads FLC  WRONG: no FC
6.1(front)  reads LFE  WRONG: no FC
```

**Fix:** both now get no figure, with the reason.

The printed error range was also too narrow. Accurate when the centre holds only speech (-0.1 LU), but it reads however much louder the other content there is:

```
mix                                                  true_speech  estimate  error  ldr_reported  ldr_true
speech only in centre, loud effects                  -39.0        -39.1     -0.1   19.6          19.5
centre also carries effects at -30                   -39.0        -31.9     7.1    12.6          19.7
centre carries effects at -18 (score up the middle)  -39.0        -20.3     18.7   3.4           22.1
```

The last row passes the 5 LU loudness-above-dialogue limit with a true figure of 22. These mixes are harsher than a film should be, but "-0.7 to +3.4 LU" read as a bound, and it isn't one. **Fix:** the printed method text and README now say so. The estimate's other claims held: read-only (bytes and mtimes identical), and stereo and mono get a reason, not a number.

### 11. CI has been red on `main` since 68298c7

`amix ... normalize=0` in a spec fixture doesn't exist on ffmpeg 4.2.2: four examples failed in [run 41284792020](https://github.com/willhs/neutraliser/actions/runs/41284792020). Test fixture only, but "Publish image" doesn't wait for CI, so red CI doesn't stop a publish. **Fix:** `amerge` plus `pan`. Reproduced and confirmed in Docker on static 4.2.2.

### 12. Nothing records that a flatten dropped Atmos

After `--allow-object-audio-loss`, the probe's profile is gone and the stamp said only `eac3`, so nothing could later find which files lost their objects. Not an audio bug, but time-critical: originals aren't kept. **Fix:** `NEUTRALISER_SOURCE_PROFILE` (`Dolby Digital Plus + Dolby Atmos`, `DTS`). A profile found only by the name-hinted mid-file probe isn't threaded through and would record the plain name.

### 13. 7.1 DD+, and 7.1 lossless in MP4, fail every sweep (safely)

ffmpeg's E-AC-3 encoder stops at 5.1. The output check catches it, the source is left alone, and the run carries on:

```
FLAC 7.1 .mp4 (to E-AC-3)  exit 1  output flac/7.1/24 (untouched)  Output does not match the source
```

So "nothing skipped" isn't quite met: these fail on every sweep, after a full measure each time. A TrueHD 7.1 in MKV goes to FLAC and is fine. I couldn't build real 7.1 E-AC-3 (ffmpeg can't write it), so the path is shown through FLAC in MP4. A fix would send 7.1 to FLAC where the container allows; left open because the real source can't be tested.

### 14. 7.1 is measured without its side channels

`loudnorm` ignores channels 7 and 8: the same noise on all eight read -27.0 by `loudnorm` and -25.3 by `ebur128` (on 5.1 they agree at -27.0), and a PCM 7.1 clip landed at -18.2 for a -20 target. That's about 1.8 LU with equal energy in every channel, and less on a real mix with its weight up front, inside the driver's `--tolerance 2`. It predates today's commits, but `--allow-codec-change` newly brings TrueHD 7.1 into reach.

### 15. Only the first frames' dialnorm is read

A file that changes dialnorm partway (-24, then -31) comes out -24 throughout, so its second half drops 7 LU on a decoder that honours dialnorm. Films shouldn't do this; joined captures might. Left open: scanning a whole stream costs a read over the network, for a case not shown to exist. A real library could count it.

### 16. LRA has a cliff at its gate

Both meters are right on the known answers (EBU Tech 3342 cases 1 to 4, expected 10, 5, 20, 15: both read exactly that). But around the gate, small changes move LRA a lot:

- The same steps with only the noise changed: `gentle` read 9.6, 23.7, 9.4 and 23.6 LU across seeds, while the source read 11.7 every time (lab 05c). So a `--lra-target` decision on such material can flip on nothing, and it's why the wrong-rung case is a deterministic spec, not a real-clip one.
- `loudnorm` and `ebur128` differ on the same file by 1.6 to 4 LU on step clips, and by 11.5 LU (21.1 against 9.6) on one sitting on the gate.
- `FinalLevels` says constant gain leaves the range alone. Not always: a very quiet file (-51 LUFS) went from 8.6 to 22.1 LU under +31 dB, because its bed rose over the absolute gate. A computed rate would flatter it. Rare, and left open.

Step clips are the worst case for this. Whether films sit on the cliff can't be known from here.

### 17. The dialogue-anchored rate can barely pass a -20 LUFS library

Dialogue within 2 LU of -27 needs -29 to -25; programme at most 5 LU above it, at -20, needs dialogue at -25 or higher. So at exactly -20 only a reading of exactly -25 passes. It reads low by arithmetic, so it doesn't flatter, but it can't be compared with the main rate until the library is levelled on dialogue.

## What held

Each was run, not read:

| Claim | Result | Lab |
|---|---|---|
| DRC off on every path | AC-3 and E-AC-3, seven modes: output LRA 20.1 / 19.9 from source 20.0 where the mode keeps range; DRC words gone; every decoding command line carries `-drc_scale 0` | 01 |
| Kept original untouched | Stream identical to the source, DRC and dialnorm included | 01 |
| Primary on `a:1` | Right track levelled and stamped; `a:0`'s dialnorm unchanged | 01 |
| Dialnorm carried | -27 in, -27 out on stereo and 5.1, AC-3 and E-AC-3, through default, `--limit-db` (really limiting), `--lra-target`, both, `--fast`, `--keep-original-audio`; read from the bitstream and from what a dialnorm-honouring decoder does; second generation holds | 02 |
| Dialnorm reader | Right on all 10 channel arrangements and 5 containers, including AC-3 in AVI | 02 |
| `linear` is one gain | Whole-file null test on lossless output: residual -138 dBFS, same length | 03 |
| Mode matches the chain | Read off the real command line: `linear` = volume, `limited` = + alimiter, `compressed` = acompressor + volume | 03 |
| Compression doesn't stack | Rerun, stricter rerun, flagless rerun: bytes the same | 05 |
| No clipping | True peak -0.4 dBTP at worst in any run (over the -1.5 ceiling on the compression-plus-limiter path, finding 2). `pan` alone clips integer sources at 0 dBFS, but in the real chain (`pan`, then `acompressor`) the peak matches a float reference | 05, 06 |
| `--centre-boost` | 23 layouts: only `5.1` and `5.1(side)` move, only the front centre moves, every other layout logs the skip and stamps 0 | 06 |
| Planned flags | DTS and TrueHD to FLAC in MKV, to E-AC-3 in MP4; Atmos-flagged E-AC-3 flattened: right codec and layout, LRA kept, dialnorm kept, stamp right, rerun skips | 08 |
| Atmos left alone when no re-encode is needed | Flags on, within tolerance: bytes the same, still reports Atmos | 08 |
| Left-alone record gives way | DTS `codec_change` record, then the flag: stamped, record gone | 08 |
| A/V sync | First audio packet unchanged for DTS, TrueHD and FLAC, on-time and +500 ms. AC-3 and E-AC-3 move 5 ms: the encoder's priming, which its timestamps account for | 08 |
| Report and `rate-sample` read-only | Bytes and mtimes identical | 07 |
| Same on the production build | DRC and flags labs rerun inside the published image's base (Debian, ffmpeg 7.1.5) | [image results](lab/results/image/) |

## Restart checklist

1. Land this and push `main`. Manager lands locally only, and pushing is what publishes the image. Check CI is green on that push.
2. On the host: `sudo docker pull ghcr.io/willhs/neutraliser:latest`.
3. Prove what it holds, before any run:
   `sudo docker run --rm --entrypoint sh ghcr.io/willhs/neutraliser:latest -c "grep 'CURRENT =' /app/lib/neutraliser/recipe.rb; grep -c ':prior' /app/lib/neutraliser/stamp.rb"`. Expect `CURRENT = 2` and a count of at least 1.
4. Pin that digest in `neutralise-driver.sh`, so the method can't change mid-sweep.
5. Add `--allow-codec-change --allow-object-audio-loss` to the driver, and decide on `--redo-recipe 1,unversioned` (finding 4).
6. After the first Dolby file, read its tags: `NEUTRALISER_RECIPE=2` and a `NEUTRALISER_SOURCE_DIALNORM`.

## What this review cannot know

**Needs real files:**

- **Real object audio and HD codecs.** ffmpeg can't write TrueHD Atmos, DTS:X, DTS-HD MA or E-AC-3 JOC, and its TrueHD encoder can't do 7.1. "Atmos" here is plain 5.1 E-AC-3 with the flag a decoder reads set. The decode paths are the same; the content isn't.
- **Real DRC.** Fixtures carry two levels, and real profiles vary per block. The switch is the same, `-drc_scale 0`, but E-AC-3 with dependent substreams wasn't tried.
- **How the fix's level change plays out.** How far DRC-off readings sit from the old ones (13.6 LU is this fixture's extreme) sets how much of finding 4's second group matters.
- **How often real tracks hit findings 13, 15 and 16**, and how close the dialogue estimate gets. A track's own dialnorm is the free check on the estimate; research 0002 says this too.
- **What image the host has now, and how long six reads take there.** Neither is reachable from this job.
- **Disk.** DTS to FLAC was 2.87 times the file on noise, a worst case with tiny video. Real growth decides how the 40/20 GiB floors behave.

**Needs a player or ears:**

- **How `--lra-target` and `--centre-boost` sound.** All of this is arithmetic. A rung that passes on LRA can still pump.
- **What honours what.** A -24 file and a -31 file levelled to the same raw loudness sit 7 LU apart on a decoder that honours dialnorm, and no rate here can see it. Research 0002 lists what's known per client; I tested no hardware.
- **Whether FLAC plays** on the clients in use, or transcodes.

## How this was run

Every lab runs the real CLI as a subprocess, with the driver's flags, over generated clips, and judges the output with something other than the tool's own measure: `ebur128`, the raw bitstream, ffmpeg's dialnorm-honouring decode. Older code was the real thing, from `git archive`, so its stamps and damage are real.

Reproduce: `bundle exec ruby docs/research/0003-sceptical-review-dolby-dialogue-compression/lab/01_drc.rb` and so on. `LAB_IMAGE=<image>` runs the CLI inside an image with this tree's `lib` mounted. `09_restart.rb` needs a pre-fix image.

On 2026-11-07 the fixes were rebased onto the `Source` / `Guards` / `CodecChoice` refactor that landed on `main` meanwhile, and the labs moved to the `Source` API. Labs 01, 02 and 06 were rerun on the rebased tree: 02 and 06 match `results/after/` line for line, and 01 matches too except that `process` + `report --measure` now run 6 ffmpeg commands, not 7, still none of them decoding without `-drc_scale 0`.

The specs: `spec/sceptical_review_spec.rb`, plus additions to `compression_spec`, `remote_free_rate_spec`, `manifest_import_spec`, `dialogue_spec`, `recipe_and_rate_spec`, and E-AC-3 DRC in `dolby_metadata_spec`. Before the fixes, 27 of them were red; [the red run](lab/results/red-specs-before-fix.txt) is kept. The CI failure (finding 11) was red in CI itself. Test results for this tree are in the job's report.

Noticed, not changed: the `check-prod` skill and `docs/ops/runbook.md` still say production doesn't run this CLI. The driver has since 2026-10-28, which nearly misdirected this review. The decision trail is [`decisions.tsv`](decisions.tsv).
