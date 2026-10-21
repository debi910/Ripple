"""Lay the voiceover on the silent demo video.

    python video/merge.py voice.m4a                  # one take, starts at 0:00
    python video/merge.py scene1.m4a ... scene6.m4a   # one clip per scene

With one clip per scene, each clip starts with its scene. If a clip runs past
the next scene's start, the scene holds on one frame long
enough for the narration to finish, so the voice never runs ahead of the
screen. Writes video/ripple_demo.mp4.
"""

import json
import subprocess
import sys
from pathlib import Path

from record import ffmpeg_exe

OUT = Path(__file__).resolve().parent
GAP = 0.6       # breathing room after each clip before the next scene starts
VOICE = "highpass=f=80,afftdn=nf=-25"   # trim rumble and steady background hiss


def duration(path: str) -> float:
    probe = subprocess.run([ffmpeg_exe(), "-i", path], capture_output=True, text=True).stderr
    h, m, s = probe.split("Duration: ")[1].split(",")[0].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def main(clips: list[str]):
    video = OUT / "ripple_demo_silent.mp4"
    out = OUT / "ripple_demo.mp4"
    cmd = [ffmpeg_exe(), "-y", "-i", str(video)] + sum((["-i", c] for c in clips), [])

    if len(clips) == 1:
        filt = f"[1:a]{VOICE},loudnorm=I=-16:TP=-1.5,apad[a]"
        cmd += ["-filter_complex", filt, "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-shortest"]
    else:
        marks = json.loads((OUT / "scene_marks.json").read_text())
        starts = [m["t"] for m in marks if m["scene"] != "end"]
        end = next(m["t"] for m in marks if m["scene"] == "end")
        bounds = starts + [end]
        parts, new_start, shift = [], [], 0.0
        for i, clip in enumerate(clips):
            a, b = bounds[i], bounds[i + 1]
            hold = max(0.0, duration(clip) + GAP - (b - a))
            new_start.append(a + shift)
            # Hold a calm frame two-thirds through the scene, not the transition at its end.
            m = a + (b - a) * 2 / 3
            parts.append(f"[0:v]trim={a}:{m},setpts=PTS-STARTPTS,fps=30,tpad=stop_mode=clone:stop_duration={hold:.2f}[p{i}];"
                         f"[0:v]trim={m}:{b},setpts=PTS-STARTPTS,fps=30[q{i}];[p{i}][q{i}]concat=n=2:v=1:a=0[v{i}]")
            shift += hold
            print(f"scene {i + 1}: starts {a + shift - hold:6.1f}s, clip {duration(clip):5.1f}s, hold {hold:4.1f}s")
        parts.append("".join(f"[v{i}]" for i in range(len(clips))) + f"concat=n={len(clips)}:v=1:a=0[v]")
        for i, s in enumerate(new_start):
            ms = int(s * 1000)
            parts.append(f"[{i + 1}:a]{VOICE},adelay={ms}|{ms}[a{i}]")
        parts.append("".join(f"[a{i}]" for i in range(len(clips))) +
                     f"amix=inputs={len(clips)}:normalize=0,loudnorm=I=-16:TP=-1.5[a]")
        cmd += ["-filter_complex", ";".join(parts), "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p"]
        print(f"final length {end + shift:.1f}s")

    cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", str(out)]
    subprocess.run(cmd, check=True, capture_output=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
