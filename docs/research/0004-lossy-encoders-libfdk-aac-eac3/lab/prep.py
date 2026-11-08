"""Build the source streams for the encoder comparison: four 30 s windows of Tears of Steel (CC-BY, Blender).

Host ffmpeg (has aac_at, used only to make an *independent* AAC source). Output: work/src/<kind>_<window>.<ext>
  ac3_51_448  real Dolby AC-3 5.1 448k (stream copy of the DVD-surround release)
  eac3_51_640 E-AC-3 5.1 640k, made from that AC-3 with FFmpeg's encoder (no Dolby encoder is available here)
  aac_20_128  AAC-LC stereo 128k from the stereo mix, Apple AudioToolbox encoder (not a candidate in the real pipeline)
  aac_51_384  AAC-LC 5.1 384k from the AC-3 decode, Apple AudioToolbox
Usage: python3 prep.py MEDIA_DIR WORK_DIR
"""
import subprocess, sys, pathlib
media, work = map(pathlib.Path, sys.argv[1:3])
src = work / 'src'; src.mkdir(parents=True, exist_ok=True)
WINDOWS = {'w60': 60, 'w200': 200, 'w380': 380, 'w520': 520}
DUR = 30

def ff(*a):
    subprocess.run(['ffmpeg', '-hide_banner', '-nostats', '-loglevel', 'error', '-y', *a], check=True)

for w, s in WINDOWS.items():
    ff('-ss', str(s), '-t', str(DUR), '-i', str(media / 'tos51.ac3'), '-c', 'copy', str(src / f'ac3_51_448_{w}.ac3'))
    ff('-ss', str(s), '-t', str(DUR), '-i', str(media / 'tos51.ac3'), '-af', 'aformat=channel_layouts=5.1(side)',
       '-c:a', 'eac3', '-b:a', '640k', str(src / f'eac3_51_640_{w}.mkv'))
    ff('-ss', str(s), '-t', str(DUR), '-i', str(media / 'tos_stereo.aif'), '-c:a', 'aac_at', '-b:a', '128k',
       str(src / f'aac_20_128_{w}.mkv'))
    ff('-ss', str(s), '-t', str(DUR), '-i', str(media / 'tos51.ac3'), '-af', 'aformat=channel_layouts=5.1',
       '-c:a', 'aac_at', '-b:a', '384k', str(src / f'aac_51_384_{w}.mkv'))
print(sorted(p.name for p in src.iterdir()))
