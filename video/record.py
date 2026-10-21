"""Record the Ripple demo walkthrough as a silent 1080p video.

Drives the real app in the installed Chrome with Playwright, following the
scenes in docs/DEMO_SCRIPT.md on a fixed clock so a voiceover can be laid on
top. Start the app first (python -m ripple.app), then:

    python video/record.py            # writes video/ripple_demo_silent.mp4

Needs: pip install playwright imageio-ffmpeg (uses your installed Chrome).
"""

import json
import shutil
import subprocess
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://localhost:8765"
OUT = Path(__file__).resolve().parent
W, H = 1920, 1080
ZOOM = 1.3  # the app is laid out for a laptop; enlarge the page so text reads on video

# A visible cursor and a ripple on every click, so viewers can follow along.
CURSOR_JS = """
(() => {
  if (window.__cursor) return; window.__cursor = 1;
  const c = document.createElement('div');
  c.style.cssText = 'position:fixed;left:0;top:0;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;' +
    'background:rgba(21,23,26,.18);border:2px solid #15171A;z-index:99999;pointer-events:none;transition:transform .08s';
  const attach = () => document.documentElement.appendChild(c);
  document.documentElement ? attach() : addEventListener('DOMContentLoaded', attach);
  addEventListener('mousemove', e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; }, true);
  addEventListener('mousedown', e => {
    c.style.transform = 'scale(.75)';
    const r = document.createElement('div');
    r.style.cssText = `position:fixed;left:${e.clientX}px;top:${e.clientY}px;width:16px;height:16px;margin:-8px 0 0 -8px;` +
      'border-radius:50%;border:2px solid #C2412A;z-index:99998;pointer-events:none;transition:all .6s ease-out;opacity:1';
    document.documentElement.appendChild(r);
    requestAnimationFrame(() => { r.style.transform = 'scale(5)'; r.style.opacity = '0'; });
    setTimeout(() => r.remove(), 700);
  }, true);
  addEventListener('mouseup', () => c.style.transform = 'scale(1)', true);
})();
"""


def ffmpeg_exe() -> str:
    found = shutil.which("ffmpeg")
    if found:
        return found
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


class Director:
    def __init__(self, page):
        self.page, self.t0, self.marks, self.x, self.y = page, time.time(), [], W / 2, H / 2

    def at(self, seconds: float, scene: str | None = None):
        """Wait until this point on the clock, so scenes land where the narration expects them."""
        delay = seconds - (time.time() - self.t0)
        if delay > 0:
            time.sleep(delay)
        if scene:
            self.marks.append({"scene": scene, "t": round(time.time() - self.t0, 1)})
            print(f"{time.time() - self.t0:6.1f}s  {scene}")

    def move(self, x, y, steps=28):
        self.page.mouse.move(x, y, steps=steps)
        self.x, self.y = x, y

    def to(self, selector, nth=0, dx=0.5, dy=0.5):
        box = self.page.locator(selector + " >> visible=true").nth(nth).bounding_box()
        self.move(box["x"] + box["width"] * dx, box["y"] + box["height"] * dy)
        return box

    def click(self, selector, nth=0, pause=0.35):
        self.to(selector, nth)
        time.sleep(pause)
        self.page.mouse.down()
        self.page.mouse.up()

    def scroll(self, dy, steps=24, pause=0.02):
        for _ in range(steps):
            self.page.mouse.wheel(0, dy / steps)
            time.sleep(pause)

    def top(self):
        self.page.evaluate("window.scrollTo({top: 0, behavior: 'smooth'})")


def main():
    raw_dir = OUT / "raw"
    shutil.rmtree(raw_dir, ignore_errors=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        ctx = browser.new_context(viewport={"width": W, "height": H}, record_video_dir=str(raw_dir),
                                  record_video_size={"width": W, "height": H})
        # Zoom the body only: the cursor lives on <html>, outside the zoom, so it tracks the real pointer.
        ctx.add_init_script(f"document.addEventListener('DOMContentLoaded', () => document.body.style.zoom = '{ZOOM}');")
        ctx.add_init_script(CURSOR_JS)
        page = ctx.new_page()
        video_start = time.time()
        # Warm the API so the first frames are not a loading state.
        page.goto(URL + "/#bill")
        page.wait_for_selector("svg.chart", timeout=30000)
        page.wait_for_timeout(1500)
        d = Director(page)
        d.t0 = time.time()

        # 0:00 The bill
        d.at(0, "01 The bill")
        page.goto(URL + "/#bill")
        page.wait_for_selector("svg.chart")
        d.move(W * .32, H * .30)
        d.at(6)
        d.to("svg.chart", dx=.88, dy=.45)          # the real bill bar
        d.at(12)
        d.scroll(620)
        d.to(".top5 .row", 0)
        d.at(20)
        d.top()

        # 0:25 Recount list
        d.at(25, "02 Recount list")
        d.click("nav button[data-view=recount]")
        page.wait_for_selector(".alerts .row")
        d.at(31)
        for _ in range(4):
            d.click("#prev", pause=.15)
            page.wait_for_timeout(450)
        d.at(37)
        for _ in range(4):
            d.click("#next", pause=.15)
            page.wait_for_timeout(450)
        d.at(43)
        d.click(".alerts .row", 0)
        page.wait_for_selector(".row.open svg.chart")
        d.at(46)
        d.scroll(420)
        d.to(".row.open .quote", 0) if page.locator(".row.open .quote").count() else d.to(".row.open svg.chart")
        d.at(60)

        # 1:05 One stock-out's ripple
        d.at(65, "03 Stock-out ripple")
        d.top()
        page.wait_for_timeout(500)
        d.click("nav button[data-view=episode]")
        page.wait_for_selector("#people .row")
        d.to("svg.chart", dx=.45, dy=.5)
        d.at(73)
        d.scroll(560)
        shopper = page.locator("#people .row").filter(has_text="accounts").first
        box = shopper.bounding_box()
        d.move(box["x"] + 120, box["y"] + box["height"] / 2)
        d.at(79)
        page.mouse.down(); page.mouse.up()
        page.wait_for_selector(".drawer.on .receipt")
        d.move(W - 300, H * .4)
        d.at(90)
        d.scroll(300)
        d.at(96)
        page.keyboard.press("Escape")

        # 1:40 Make good
        d.at(100, "04 Make good")
        d.top()
        d.click("nav button[data-view=makegood]")
        page.wait_for_selector(".offer")
        d.to(".ledger-line")
        d.at(107)
        d.to(".offer", 0)
        d.at(112)
        d.scroll(380)
        d.to(".offer", 3)
        d.at(118)

        # 2:00 Proof
        d.at(120, "05 Proof")
        d.top()
        d.click("nav button[data-view=proof]")
        page.wait_for_selector(".vs .pair")
        d.to(".vs .panel", 0)
        d.at(127)
        d.to(".vs .panel", 1)
        d.at(132)
        d.to(".vs .panel", 2)
        d.at(138)
        d.scroll(520)
        d.at(146)
        d.scroll(420)
        d.at(152)

        # 2:35 Exasol and close
        d.at(155, "06 Under the hood and close")
        d.click("details summary")
        page.wait_for_timeout(600)
        d.scroll(500)
        d.at(163)
        d.top()
        d.click("nav button[data-view=bill]")
        d.move(W * .35, H * .3)
        d.at(172, "end")
        page.wait_for_timeout(500)

        video_path = Path(page.video.path())
        ctx.close()
        browser.close()

    (OUT / "scene_marks.json").write_text(json.dumps(d.marks, indent=2))
    out = OUT / "ripple_demo_silent.mp4"
    # Trim the warm-up and encode for upload: H.264, 30 fps, high quality.
    warmup = max(0.0, d.t0 - video_start)
    subprocess.run([ffmpeg_exe(), "-y", "-ss", f"{warmup:.2f}", "-i", str(video_path), "-t", "173",
                    "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                    "-movflags", "+faststart", str(out)], check=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
