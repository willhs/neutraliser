## Sample

42 files measured (0 failed: )

| kind | group | codec | ch | n |
|---|---|---|---|---|
| episode | dolby51 | ac3 | 6 | 7 |
| episode | dolby51 | eac3 | 6 | 5 |
| episode | other51 | aac | 6 | 2 |
| episode | other51 | dts | 6 | 2 |
| episode | stereo | ac3 | 2 | 1 |
| episode | stereo | eac3 | 2 | 2 |
| episode | stereo | opus | 2 | 1 |
| movie | dolby51 | aac | 2 | 1 |
| movie | dolby51 | ac3 | 6 | 9 |
| movie | dolby51 | eac3 | 6 | 4 |
| movie | other51 | aac | 6 | 3 |
| movie | other51 | dts | 6 | 1 |
| movie | stereo | aac | 2 | 4 |

## 1. Estimate vs dialnorm (Dolby tracks, 5.1 and up)

Dolby surround tracks: 25; dialnorm read: 25; dialnorm -31 (unset, no ground truth): 23; stamped by neutraliser: 0
dialnorm values: {-31=>23, -30=>1, -24=>1}

| title | kind | dialnorm | estimate | est - dialnorm | programme | LRA |
|---|---|---|---|---|---|---|
| The SpongeBob Movie: Sponge Out of Water (2015) | movie | -24 | -21.1 | 2.9 | -18.8 | 16.0 |
| Alien (1979) | movie | -30 | -26.0 | 4.0 | -21.7 | 24.6 |

Files with usable dialnorm: 2. Within 2 LU: 0 (0.0%). Within 3 LU: 1. Bias (est - dialnorm): n=2, median 4.0, p10 2.9, p90 4.0, min 2.9, max 4.0
Pass mark (>= 90% within 2 LU): FAIL
- movies: n=2, median 4.0, p10 2.9, p90 4.0, min 2.9, max 4.0; within 2 LU: 0 of 2
- episodes: n=0; within 2 LU: 0 of 0

Screen of Dolby 5.1 files (first frames only, dialnorm readable): 312; dialnorm -31: 283; real value: 29 (9.3%). Movies 10 of 141, episodes 19 of 171. Values: {-31=>283, -28=>1, -27=>3, -26=>1, -25=>3, -24=>12, -23=>5, -22=>2, -21=>1, -19=>1}

## 1b. Subtitle-cue reference (all files with enough cues)

| title | kind | cues | coverage | shift s | separation dB (at 0) | est | cue full-mix | cue centre | est - cue full | est - cue centre | dialnorm - cue full |
|---|---|---|---|---|---|---|---|---|---|---|---|
| The Office (US) S5E2 Business Ethics | episode | 808 | 56% | -0.6 | 8.2 (2.7) | -21.3 | -21.2 | -21.2 | -0.0 | -0.0 | - |
| Indie Game: The Movie (2012) | movie | 1524 | 57% | -0.4 | 5.1 (3.6) | -20.0 | -19.5 | -19.8 | -0.5 | -0.2 | - |
| Futurama S9E7 Planet Espresso | episode | 360 | 54% | 0.0 | 9.0 (9.0) | -20.7 | -20.2 | -20.3 | -0.5 | -0.4 | - |
| Lost S1E3 Tabula Rasa | episode | 400 | 34% | 0.0 | 4.2 (4.2) | -21.0 | -25.6 | -25.7 | 4.6 | 4.6 | - |
| Shutter Island (2010) | movie | 1549 | 39% | -0.2 | 11.3 (9.9) | -24.1 | -24.1 | -24.6 | 0.1 | 0.5 | - |
| South Park S0E49 South Park: The End of Obesity | episode | 983 | 52% | 0.4 | 3.7 (1.4) | -21.1 | -20.6 | -21.0 | -0.5 | -0.1 | - |
| Succession S2E10 This Is Not for Tears | episode | 1155 | 49% | 0.0 | 13.0 (13.0) | -24.0 | -23.1 | -23.2 | -0.9 | -0.8 | - |
| The Office (US) S5E11 The Duel | episode | 728 | 51% | -0.6 | 11.0 (6.1) | -21.8 | -21.6 | -21.6 | -0.3 | -0.3 | - |
| Braveheart (1995) | movie | 1493 | 22% | 0.0 | 6.6 (6.6) | -21.5 | -20.7 | -21.1 | -0.8 | -0.4 | - |
| Ali G: Who Iz I? (2026) | movie | 1788 | 55% | -0.2 | 9.2 (8.7) | -24.2 | -23.4 | -23.7 | -0.8 | -0.5 | - |
| Balto (1995) | movie | 943 | 36% | 0.0 | 3.1 (3.1) | -25.2 | -24.4 | -25.6 | -0.8 | 0.4 | - |

all with cues: est - cue full-mix: n=11, median -0.5, p10 -0.8, p90 0.1, min -0.9, max 4.6; within 2 LU: 10 of 11
all with cues: dialnorm - cue full-mix (how good is the cue reference, where dialnorm exists): n=0

sync separation >= 3 dB: est - cue full-mix: n=11, median -0.5, p10 -0.8, p90 0.1, min -0.9, max 4.6; within 2 LU: 10 of 11
sync separation >= 3 dB: dialnorm - cue full-mix (how good is the cue reference, where dialnorm exists): n=0

movies with cues: est - cue full-mix: n=5, median -0.8, p10 -0.8, p90 0.1, min -0.8, max 0.1; within 2 LU: 5 of 5; over-reads by more than 2 LU: 0; under-reads by more than 2 LU: 0

episodes with cues: est - cue full-mix: n=6, median -0.3, p10 -0.5, p90 4.6, min -0.9, max 4.6; within 2 LU: 5 of 6; over-reads by more than 2 LU: 1; under-reads by more than 2 LU: 0

Sync of the cues: |best shift| median 0.2 s, max 0.6 s; shift of 0.0 to 0.2 s in 7 of 11; separation (speech blocks minus other blocks, centre channel) median 8.2 dB; under 3 dB in 0: 
Cue coverage of runtime: n=11, median 50.6, p10 34.3, p90 56.0, min 21.8, max 57.2
Files with an English text subtitle track chosen: 15 of 42; with 30 or more speech cues: 11

## 3. Loudness above dialogue (programme - centre estimate), 5.1 and up

n=33, median 1.4, p10 0.1, p90 3.3, min -0.1, max 4.3

| LU above dialogue | files |
|---|---|
| under 0 (centre louder than mix) | 2 |
| 0 to 2 | 23 |
| 2 to 4 | 7 |
| 4 to 6 | 1 |
| 6 to 8 | 0 |
| 8 to 10 | 0 |
| 10 and over | 0 |

Over the 5 LU EBU R 128 s4 limit: 0 of 33. Programme LRA (all files): n=42, median 13.3, p10 7.2, p90 19.9, min 4.0, max 24.6

## 3b. What each target would ask of the files

### Dialogue -27 (fallback programme -24 when no estimate)

- files that would move by more than 1.0 LU: 37 of 42 (1 louder, 36 quieter)
- need the peak limiter at all (limit 6): 5; need gain beyond the 6 dB limiter (shortfall > 0.5 LU): 0; shortfall > 0: 0
- need > 6 dB of gain: 0; need > 6 dB of cut: 9
- with a dialogue estimate (33): shortfall > 0.5 LU: 0; limited: 4
- files already within 1.0 LU of -20 programme ("levelled to -20"): 22; of those, would change: 22
  - of those, with a dialogue estimate (17): would change 17; median move -6.0 LU
- carrying a neutraliser stamp: 0
- move distribution (LU): n=42, median -4.4, p10 -6.6, p90 -0.7, min -18.7, max 2.2


### Dialogue -24 (fallback programme -21 when no estimate)

- files that would move by more than 1.0 LU: 32 of 42 (9 louder, 23 quieter)
- need the peak limiter at all (limit 6): 16; need gain beyond the 6 dB limiter (shortfall > 0.5 LU): 0; shortfall > 0: 1
- need > 6 dB of gain: 0; need > 6 dB of cut: 1
- with a dialogue estimate (33): shortfall > 0.5 LU: 0; limited: 14
- files already within 1.0 LU of -20 programme ("levelled to -20"): 22; of those, would change: 16
  - of those, with a dialogue estimate (17): would change 16; median move -3.0 LU
- carrying a neutraliser stamp: 0
- move distribution (LU): n=42, median -1.4, p10 -3.6, p90 2.3, min -15.7, max 5.2


## Programme level now (all files)

n=42, median -20.1, p10 -24.4, p90 -19.9, min -26.2, max -5.3
Within 1 LU of -20: 22 of 42; within 2 LU: 28

## Estimates unavailable

Only Yesterday (1991): stereo, no centre channel
Futurama S2E1 A Flight to Remember: stereo, no centre channel
South Park S5E4 Scott Tenorman Must Die: stereo, no centre channel
The World's End (2013): stereo, no centre channel
QI S16E16 Post: stereo, no centre channel
Peter Pan (1953): stereo, no centre channel
QI S13E6 Marriage and Mating: stereo, no centre channel
Shaolin Temple (1982): stereo, no centre channel
The Bourne Identity (2002): stereo, no centre channel
