"""Lay the voiceover on the silent demo video.

    python video/merge.py voice.m4a                 # one take, starts at 0:00
    python video/merge.py scene1.m4a ... scene6.m4a  # one clip per scene, placed at each scene's start

Writes video/ripple_demo.mp4. Scene start times come from video/scene_marks.json.
"""

import json
import subprocess
import sys
from pathlib import Path

from record import ffmpeg_exe

OUT = Path(__file__).resolve().parent


def main(clips: list[str]):
    video = OUT / "ripple_demo_silent.mp4"
    out = OUT / "ripple_demo.mp4"
    cmd = [ffmpeg_exe(), "-y", "-i", str(video)]
    for c in clips:
        cmd += ["-i", c]
    if len(clips) == 1:
        filt = "[1:a]loudnorm=I=-16:TP=-1.5,apad[a]"
    else:
        starts = [m["t"] for m in json.loads((OUT / "scene_marks.json").read_text()) if m["scene"] != "end"]
        parts = [f"[{i + 1}:a]adelay={int(starts[i] * 1000)}|{int(starts[i] * 1000)}[a{i}]" for i in range(len(clips))]
        filt = ";".join(parts) + ";" + "".join(f"[a{i}]" for i in range(len(clips))) + \
            f"amix=inputs={len(clips)}:normalize=0,loudnorm=I=-16:TP=-1.5,apad[a]"
    cmd += ["-filter_complex", filt, "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-shortest", "-movflags", "+faststart", str(out)]
    subprocess.run(cmd, check=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
