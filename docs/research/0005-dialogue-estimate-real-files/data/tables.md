## Sample

79 files measured (0 failed: )

| kind | group | codec | ch | n |
|---|---|---|---|---|
| episode | dolby51 | ac3 | 6 | 8 |
| episode | dolby51 | eac3 | 6 | 23 |
| episode | other51 | aac | 6 | 2 |
| episode | other51 | dts | 6 | 2 |
| episode | stereo | ac3 | 2 | 1 |
| episode | stereo | eac3 | 2 | 2 |
| episode | stereo | opus | 2 | 1 |
| movie | dolby51 | aac | 2 | 4 |
| movie | dolby51 | ac3 | 6 | 14 |
| movie | dolby51 | eac3 | 2 | 1 |
| movie | dolby51 | eac3 | 6 | 13 |
| movie | other51 | aac | 6 | 3 |
| movie | other51 | dts | 6 | 1 |
| movie | stereo | aac | 2 | 4 |

## 1. Estimate vs dialnorm (Dolby tracks, 5.1 and up)

Dolby surround tracks: 58; dialnorm read: 57; dialnorm -31 (unset, no ground truth): 27; stamped by neutraliser: 1
dialnorm values: {-31=>27, -30=>1, -28=>1, -27=>3, -26=>1, -25=>3, -24=>13, -23=>5, -22=>2, -21=>1, nil=>1}

| title | kind | dialnorm | estimate | est - dialnorm | programme | LRA |
|---|---|---|---|---|---|---|
| The Simpsons S13E3 Homer the Moe | episode | -22 | -21.6 | 0.4 | -21.0 | 10.2 |
| The Nightmare Before Christmas (1993) | movie | -28 | -27.6 | 0.4 | -26.4 | 14.9 |
| The Simpsons S25E1 Homerland | episode | -24 | -23.6 | 0.4 | -23.0 | 10.0 |
| The Orville S3E3 Mortality Paradox | episode | -24 | -23.4 | 0.6 | -20.2 | 18.7 |
| Welcome to Wrexham S4E5 Anything's Possible | episode | -24 | -23.4 | 0.6 | -22.4 | 6.2 |
| The Simpsons S29E8 Mr. Lisa's Opus | episode | -24 | -23.4 | 0.6 | -22.7 | 9.9 |
| The Simpsons S24E3 Adventures in Baby-Getting | episode | -22 | -21.3 | 0.7 | -21.0 | 9.4 |
| Futurama S11E7 Lord Nibbler in the Nothingverse | episode | -24 | -23.2 | 0.8 | -22.8 | 6.5 |
| The Cat Returns (2002) | movie | -24 | -23.2 | 0.8 | -21.1 | 15.3 |
| The Simpsons S13E8 Sweets and Sour Marge | episode | -23 | -22.2 | 0.8 | -21.7 | 9.3 |
| The Simpsons S14E17 Three Gays of the Condo | episode | -24 | -23.2 | 0.9 | -22.8 | 9.2 |
| The Office (US) S7E9 WUPHF.com | episode | -25 | -24.1 | 0.9 | -23.8 | 12.0 |
| The Office (US) S7E19 Garage Sale | episode | -24 | -23.0 | 1.0 | -22.8 | 12.8 |
| The Simpsons S11E10 Little Big Mom | episode | -23 | -21.8 | 1.2 | -21.1 | 10.6 |
| The Simpsons S14E21 The Bart of War | episode | -24 | -22.8 | 1.2 | -22.2 | 9.9 |
| Futurama S10E9 The Trouble with Truffles | episode | -24 | -22.8 | 1.2 | -22.4 | 7.5 |
| The Office (US) S7E20 Training Day | episode | -25 | -23.7 | 1.3 | -23.5 | 13.4 |
| Jason Bourne (2016) | movie | -23 | -21.7 | 1.3 | -18.3 | 17.1 |
| Futurama S6E1 Rebirth | episode | -24 | -22.5 | 1.5 | -21.2 | 10.8 |
| Doctor Who (2005) S12E8 The Haunting of Villa Diodati | episode | -23 | -24.5 | -1.5 | -22.7 | 15.2 |
| The Simpsons S13E1 Treehouse of Horror XII | episode | -23 | -21.2 | 1.8 | -20.5 | 10.5 |
| Kill Bill: Vol. 1 (2003) | movie | -21 | -19.0 | 2.0 | -16.7 | 22.9 |
| The Departed (2006) | movie | -25 | -22.3 | 2.7 | -21.7 | 21.5 |
| The SpongeBob Movie: Sponge Out of Water (2015) | movie | -24 | -21.1 | 2.9 | -18.8 | 16.0 |
| The Hateful Eight (2015) | movie | -27 | -24.0 | 3.0 | -22.9 | 17.4 |
| Alien (1979) | movie | -30 | -26.0 | 4.0 | -21.7 | 24.6 |
| Jurassic Park (1993) | movie | -24 | -19.4 | 4.6 | -16.2 | 22.9 |
| Watchmen (2009) | movie | -27 | -21.5 | 5.5 | -17.6 | 24.1 |
| Stranger Things S5E8 Chapter Eight: The Rightside Up | episode | -26 | -20.4 | 5.6 | -15.5 | 20.7 |
| Mission: Impossible II (2000) | movie | -27 | -18.8 | 8.2 | -15.2 | 24.7 |

Files with usable dialnorm: 30. Within 2 LU: 22 (73.3%). Within 3 LU: 25. Bias (est - dialnorm): n=30, median 1.2, p10 0.4, p90 4.6, min -1.5, max 8.2
Pass mark (>= 90% within 2 LU): FAIL
- movies: n=11, median 2.9, p10 0.8, p90 5.5, min 0.4, max 8.2; within 2 LU: 4 of 11
- episodes: n=19, median 0.9, p10 0.4, p90 1.5, min -1.5, max 5.6; within 2 LU: 18 of 19

Screen of Dolby 5.1 files (first frames only, dialnorm readable): 312; dialnorm -31: 283; real value: 29 (9.3%). Movies 10 of 141, episodes 19 of 171. Values: {-31=>283, -28=>1, -27=>3, -26=>1, -25=>3, -24=>12, -23=>5, -22=>2, -21=>1, -19=>1}

## 1b. Subtitle-cue reference (all files with enough cues)

| title | kind | cues | coverage | shift s | separation dB (at 0) | est | cue full-mix | cue centre | est - cue full | est - cue centre | dialnorm - cue full |
|---|---|---|---|---|---|---|---|---|---|---|---|
| The Simpsons S13E3 Homer the Moe | episode | 460 | 52% | 0.0 | 5.4 (5.4) | -21.6 | -21.4 | -21.5 | -0.2 | -0.1 | -0.6 |
| The Simpsons S14E21 The Bart of War | episode | 374 | 49% | 0.0 | 4.0 (4.0) | -22.8 | -22.9 | -23.0 | 0.1 | 0.2 | -1.1 |
| The Nightmare Before Christmas (1993) | movie | 648 | 26% | 0.2 | -0.1 (-0.1) | -27.6 | -27.6 | -28.2 | 0.0 | 0.6 | -0.4 |
| The Simpsons S11E10 Little Big Mom | episode | 398 | 47% | 0.0 | 5.4 (5.4) | -21.8 | -21.8 | -22.0 | -0.0 | 0.1 | -1.2 |
| Stranger Things S5E8 Chapter Eight: The Rightside Up | episode | 1415 | 32% | -0.2 | 8.5 (8.0) | -20.4 | -20.4 | -23.6 | -0.0 | 3.2 | -5.6 |
| The Office (US) S5E2 Business Ethics | episode | 808 | 56% | -0.6 | 8.2 (2.7) | -21.3 | -21.2 | -21.2 | -0.0 | -0.0 | - |
| The Cat Returns (2002) | movie | 867 | 32% | -0.2 | 10.6 (9.6) | -23.2 | -21.1 | -22.1 | -2.1 | -1.1 | -2.9 |
| Watchmen (2009) | movie | 1629 | 39% | -0.2 | 2.5 (1.2) | -21.5 | -25.8 | -26.5 | 4.2 | 5.0 | -1.2 |
| Indie Game: The Movie (2012) | movie | 1524 | 57% | -0.4 | 5.1 (3.6) | -20.0 | -19.5 | -19.8 | -0.5 | -0.2 | - |
| Futurama S9E7 Planet Espresso | episode | 360 | 54% | 0.0 | 9.0 (9.0) | -20.7 | -20.2 | -20.3 | -0.5 | -0.4 | - |
| Jurassic Park (1993) | movie | 1232 | 32% | 0.0 | 4.5 (4.5) | -19.4 | -21.5 | -22.3 | 2.0 | 2.9 | -2.5 |
| The Hateful Eight (2015) | movie | 2511 | 52% | 0.0 | 5.6 (5.6) | -24.0 | -23.6 | -23.9 | -0.4 | -0.2 | -3.4 |
| Jason Bourne (2016) | movie | 1040 | 19% | -0.2 | 4.8 (3.9) | -21.7 | -20.4 | -22.0 | -1.3 | 0.3 | -2.6 |
| Kill Bill: Vol. 1 (2003) | movie | 686 | 26% | -0.2 | 1.7 (1.7) | -19.0 | -21.6 | -22.9 | 2.6 | 3.9 | 0.6 |
| Mission: Impossible II (2000) | movie | 1149 | 22% | -0.2 | 5.8 (5.5) | -18.8 | -21.0 | -23.5 | 2.2 | 4.7 | -6.0 |
| South Park: Bigger, Longer & Uncut (1999) | movie | 1052 | 49% | 0.2 | 1.5 (1.3) | -21.3 | -21.4 | -21.9 | 0.1 | 0.6 | - |
| Lost S1E3 Tabula Rasa | episode | 400 | 34% | 0.0 | 4.2 (4.2) | -21.0 | -25.6 | -25.7 | 4.6 | 4.6 | - |
| The Rocker (2008) | movie | 1438 | 53% | 0.0 | 0.3 (0.3) | -26.2 | -26.3 | -27.0 | 0.1 | 0.8 | - |
| Shutter Island (2010) | movie | 1549 | 39% | -0.2 | 11.3 (9.9) | -24.1 | -24.1 | -24.6 | 0.1 | 0.5 | - |
| The Chronicles of Riddick (2004) | movie | 928 | 23% | -0.2 | 5.7 (4.6) | -23.2 | -22.8 | -23.7 | -0.4 | 0.6 | - |
| South Park S0E49 South Park: The End of Obesity | episode | 983 | 52% | 0.4 | 3.7 (1.4) | -21.1 | -20.6 | -21.0 | -0.5 | -0.1 | - |
| Gladiator (2000) | movie | 1242 | 27% | -0.2 | 6.5 (5.7) | -23.1 | -22.6 | -23.8 | -0.5 | 0.7 | - |
| The Lord of the Rings: The Two Towers (2002) | movie | 2036 | 33% | -0.2 | 3.8 (3.6) | -22.8 | -23.3 | -24.1 | 0.5 | 1.3 | - |
| Succession S2E10 This Is Not for Tears | episode | 1155 | 49% | 0.0 | 13.0 (13.0) | -24.0 | -23.1 | -23.2 | -0.9 | -0.8 | - |
| The Office (US) S5E11 The Duel | episode | 728 | 51% | -0.6 | 11.0 (6.1) | -21.8 | -21.6 | -21.6 | -0.3 | -0.3 | - |
| Braveheart (1995) | movie | 1493 | 22% | 0.0 | 6.6 (6.6) | -21.5 | -20.7 | -21.1 | -0.8 | -0.4 | - |
| Ali G: Who Iz I? (2026) | movie | 1788 | 55% | -0.2 | 9.2 (8.7) | -24.2 | -23.4 | -23.7 | -0.8 | -0.5 | - |
| Balto (1995) | movie | 943 | 36% | 0.0 | 3.1 (3.1) | -25.2 | -24.4 | -25.6 | -0.8 | 0.4 | - |
| The Simpsons S25E1 Homerland | episode | 352 | 48% | 0.0 | 10.4 (10.4) | -23.6 | -23.3 | -23.5 | -0.3 | -0.0 | -0.7 |
| The Simpsons S29E8 Mr. Lisa's Opus | episode | 374 | 52% | 0.0 | 5.8 (5.8) | -23.4 | -23.3 | -23.4 | -0.1 | 0.1 | -0.7 |
| The Simpsons S14E17 Three Gays of the Condo | episode | 471 | 55% | 0.0 | 7.0 (7.0) | -23.2 | -22.8 | -22.9 | -0.3 | -0.3 | -1.2 |
| The Office (US) S7E19 Garage Sale | episode | 437 | 55% | -0.2 | 11.9 (10.8) | -23.0 | -22.8 | -22.8 | -0.2 | -0.2 | -1.2 |
| The Simpsons S13E8 Sweets and Sour Marge | episode | 419 | 50% | 0.0 | 5.4 (5.4) | -22.2 | -22.1 | -22.2 | -0.0 | 0.0 | -0.9 |
| The Simpsons S24E3 Adventures in Baby-Getting | episode | 394 | 56% | 0.0 | 8.9 (8.9) | -21.3 | -21.3 | -21.4 | 0.0 | 0.1 | -0.7 |
| Futurama S11E7 Lord Nibbler in the Nothingverse | episode | 419 | 53% | 0.0 | 8.0 (8.0) | -23.2 | -22.8 | -23.0 | -0.4 | -0.3 | -1.2 |
| Futurama S10E9 The Trouble with Truffles | episode | 436 | 52% | 0.0 | 7.1 (7.1) | -22.8 | -22.7 | -22.8 | -0.0 | 0.0 | -1.3 |
| The Simpsons S13E1 Treehouse of Horror XII | episode | 407 | 50% | 0.0 | 2.8 (2.8) | -21.2 | -21.8 | -22.1 | 0.6 | 1.0 | -1.2 |
| The Office (US) S7E9 WUPHF.com | episode | 498 | 59% | -0.2 | 7.9 (7.1) | -24.1 | -24.1 | -24.1 | 0.1 | 0.1 | -0.9 |
| Futurama S6E1 Rebirth | episode | 300 | 49% | 0.0 | 5.4 (5.4) | -22.5 | -22.8 | -23.0 | 0.3 | 0.5 | -1.2 |
| The Orville S3E3 Mortality Paradox | episode | 736 | 36% | 0.0 | 4.4 (4.4) | -23.4 | -25.0 | -25.7 | 1.7 | 2.4 | 1.0 |
| The Office (US) S7E20 Training Day | episode | 692 | 57% | -0.2 | 9.1 (7.6) | -23.7 | -23.8 | -23.8 | 0.1 | 0.1 | -1.2 |
| Welcome to Wrexham S4E5 Anything's Possible | episode | 785 | 70% | -0.8 | 8.5 (3.4) | -23.4 | -22.1 | -23.1 | -1.2 | -0.3 | -1.9 |

all with cues: est - cue full-mix: n=42, median -0.0, p10 -0.8, p90 2.0, min -2.1, max 4.6; within 2 LU: 36 of 42
all with cues: dialnorm - cue full-mix (how good is the cue reference, where dialnorm exists): n=26, median -1.2, p10 -2.9, p90 -0.4, min -6.0, max 1.0

sync separation >= 3 dB: est - cue full-mix: n=36, median -0.2, p10 -0.8, p90 1.7, min -2.1, max 4.6; within 2 LU: 32 of 36
sync separation >= 3 dB: dialnorm - cue full-mix (how good is the cue reference, where dialnorm exists): n=22, median -1.2, p10 -3.4, p90 -0.7, min -6.0, max 1.0

movies with cues: est - cue full-mix: n=18, median 0.0, p10 -0.8, p90 2.2, min -2.1, max 4.2; within 2 LU: 13 of 18; over-reads by more than 2 LU: 4; under-reads by more than 2 LU: 1

episodes with cues: est - cue full-mix: n=24, median -0.0, p10 -0.5, p90 0.6, min -1.2, max 4.6; within 2 LU: 23 of 24; over-reads by more than 2 LU: 1; under-reads by more than 2 LU: 0

Sync of the cues: |best shift| median 0.2 s, max 0.8 s; shift of 0.0 to 0.2 s in 37 of 42; separation (speech blocks minus other blocks, centre channel) median 5.8 dB; under 3 dB in 6: The Nightmare Before Christmas (1993); Watchmen (2009); Kill Bill: Vol. 1 (2003); South Park: Bigger, Longer & Uncut (1999); The Rocker (2008); The Simpsons S13E1 Treehouse of Horror XII
Cue coverage of runtime: n=42, median 49.1, p10 25.5, p90 56.0, min 19.1, max 70.1
Files with an English text subtitle track chosen: 48 of 79; with 30 or more speech cues: 42

## 3. Loudness above dialogue (programme - centre estimate), 5.1 and up

n=66, median 1.3, p10 0.2, p90 3.4, min -0.1, max 4.9

| LU above dialogue | files |
|---|---|
| under 0 (centre louder than mix) | 2 |
| 0 to 2 | 44 |
| 2 to 4 | 18 |
| 4 to 6 | 2 |
| 6 to 8 | 0 |
| 8 to 10 | 0 |
| 10 and over | 0 |

Over the 5 LU EBU R 128 s4 limit: 0 of 66. Programme LRA (all files): n=79, median 13.4, p10 7.4, p90 21.5, min 4.0, max 24.7

## 3b. What each target would ask of the files

### Dialogue -27 (fallback programme -24 when no estimate)

- files that would move by more than 1.0 LU: 72 of 79 (1 louder, 71 quieter)
- need the peak limiter at all (limit 6): 10; need gain beyond the 6 dB limiter (shortfall > 0.5 LU): 0; shortfall > 0: 0
- need > 6 dB of gain: 0; need > 6 dB of cut: 13
- with a dialogue estimate (66): shortfall > 0.5 LU: 0; limited: 8
- files already within 1.0 LU of -20 programme ("levelled to -20"): 32; of those, would change: 32
  - of those, with a dialogue estimate (24): would change 24; median move -5.7 LU
- carrying a neutraliser stamp: 1
- move distribution (LU): n=79, median -4.2, p10 -6.6, p90 -1.0, min -18.7, max 2.2


### Dialogue -24 (fallback programme -21 when no estimate)

- files that would move by more than 1.0 LU: 53 of 79 (11 louder, 42 quieter)
- need the peak limiter at all (limit 6): 31; need gain beyond the 6 dB limiter (shortfall > 0.5 LU): 0; shortfall > 0: 1
- need > 6 dB of gain: 0; need > 6 dB of cut: 1
- with a dialogue estimate (66): shortfall > 0.5 LU: 0; limited: 27
- files already within 1.0 LU of -20 programme ("levelled to -20"): 32; of those, would change: 20
  - of those, with a dialogue estimate (24): would change 20; median move -2.7 LU
- carrying a neutraliser stamp: 1
- move distribution (LU): n=79, median -1.2, p10 -3.6, p90 2.0, min -15.7, max 5.2


## Programme level now (all files)

n=79, median -20.5, p10 -23.5, p90 -18.8, min -26.4, max -5.3
Within 1 LU of -20: 32 of 79; within 2 LU: 46

## Estimates unavailable

Ronin (1998): stereo, no centre channel
Only Yesterday (1991): stereo, no centre channel
Futurama S2E1 A Flight to Remember: stereo, no centre channel
South Park S5E4 Scott Tenorman Must Die: stereo, no centre channel
The World's End (2013): stereo, no centre channel
QI S16E16 Post: stereo, no centre channel
Peter Pan (1953): stereo, no centre channel
Monty Python's the Meaning of Life (1983): stereo, no centre channel
Ocean's Twelve (2004): stereo, no centre channel
Ocean's Eleven (2001): stereo, no centre channel
QI S13E6 Marriage and Mating: stereo, no centre channel
Shaolin Temple (1982): stereo, no centre channel
The Bourne Identity (2002): stereo, no centre channel
