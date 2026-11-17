## [2026-11-18] update | analyze-plex measures the track a sweep would process

`PlexAnalyzer` now probes each title's stream URL (`Source`, token via `-headers`) and measures `Source#primary_track` by its own index and channel count, instead of `0:a:0` with Plex's `Media.audioChannels` (research 0006: 11 films / 46 episodes differ in track, 24 / 84 in channel count). A title the probe cannot read, or with no audio, is left out. Specs: default-flagged second track, channel count from the track not Plex.
