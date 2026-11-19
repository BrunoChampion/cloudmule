#!/usr/bin/env python3
"""cloudmule-webgl-check: does headless Chrome really draw WebGL on this pod's NVIDIA GPU, and keep doing so?

Installed by the gpu-graphics module as /usr/local/bin/cloudmule-webgl-check. `cloudmule gpu` runs it before the
upload (8 s of drawing) and again after the job (--quick: 2 s).

    cloudmule-webgl-check [--quick] [--seconds N] [--frames N] [--flags-file F]

It opens a self-contained WebGL2 page (no network, no libraries) in Chrome with the pod's GPU flags
(/etc/cloudmule/chrome-gpu-flags) and drives it over Chrome's DevTools pipe (--remote-debugging-pipe: JSON messages
on file descriptors 3 and 4, nothing to install). The page:
  1. registers `webglcontextlost` on its canvas BEFORE getContext('webgl2');
  2. reads the renderer (UNMASKED_RENDERER_WEBGL);
  3. allocates what broke a real three.js page: a 4096x4096 depth texture/FBO (a shadow map), RGBA16F and RGBA32F
     render targets (EXT_color_buffer_float) and a 2048x2048 RGBA16F cube map drawn face by face (PMREM-like);
  4. uploads a 2D canvas with drawn text as a texture, draws it on a quad and reads known pixels back;
  5. accumulates into the float targets for the given wall time, uploading canvas textures on the way;
  6. reads the renderer and the canvas-texture pixels again (a lost and restored context leaves them black);
  7. reports `CHECK renderer_before=… renderer_after=… lost=<n> texel_ok=<0|1> frames=<n> …`.
Chrome's console (from the first line, through the DevTools pipe) and its own stderr (--enable-logging=stderr, the
GPU process included) are printed and scanned.

Exit codes: 0 the GPU drew everything; 3 GPU_NOT_USED (the renderer is not NVIDIA, software rendering, or the check
could not run); 4 GPU_CONTEXT_LOST (a context loss, a wrong canvas-texture pixel, or a GPU process crash).
"""
import json
import os
import re
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

PATTERNS = ("GPU process exited", "GPU process crashed", "SwiftShader", "Context Lost", "context lost")
NOT_USED_PATTERNS = ("SwiftShader",)

PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>cloudmule webgl check</title></head><body>
<canvas id="c" width="512" height="512"></canvas>
<script>
(function () {
  "use strict";
  var c = document.getElementById("c");
  var S = window.__cm = { lost: 0, restored: 0, notes: [] };
  // registered before getContext: a loss while the page loads is counted too
  c.addEventListener("webglcontextlost", function (e) { S.lost++; e.preventDefault(); }, false);
  c.addEventListener("webglcontextrestored", function () { S.restored++; }, false);
  var gl = c.getContext("webgl2", { antialias: false, preserveDrawingBuffer: true, powerPreference: "high-performance" });

  function renderer() {
    if (!gl) return "no WebGL2";
    var e = gl.getExtension("WEBGL_debug_renderer_info");
    return String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  }
  function note(s) { S.notes.push(s); }
  function shader(type, src) {
    var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) note("shader: " + gl.getShaderInfoLog(s));
    return s;
  }
  function program(fs) {
    var p = gl.createProgram();
    gl.attachShader(p, shader(gl.VERTEX_SHADER, "#version 300 es\nin vec2 p; out vec2 uv;\n" +
      "void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }"));
    gl.attachShader(p, shader(gl.FRAGMENT_SHADER, "#version 300 es\nprecision highp float;\n" + fs));
    gl.bindAttribLocation(p, 0, "p"); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) note("link: " + gl.getProgramInfoLog(p));
    return p;
  }
  function target(internal, w, h) {
    var t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texStorage2D(gl.TEXTURE_2D, 1, internal, w, h);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    var f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) note("incomplete float target " + internal);
    return { t: t, f: f, w: w, h: h };
  }
  // a 2D canvas: blue background, a red square in the middle, text around it (the real page's flags and cards)
  function paint2d(size, label) {
    var k = document.createElement("canvas"); k.width = k.height = size;
    var x = k.getContext("2d");
    x.fillStyle = "rgb(30,90,200)"; x.fillRect(0, 0, size, size);
    x.fillStyle = "rgb(220,40,40)"; x.fillRect(size * 0.375, size * 0.375, size * 0.25, size * 0.25);
    x.fillStyle = "white"; x.font = "bold " + Math.round(size / 9) + "px sans-serif"; x.textAlign = "center";
    x.fillText(label, size / 2, size * 0.2); x.fillText("5,000 STADIA", size / 2, size * 0.9);
    return k;
  }
  function close(a, b) { return Math.abs(a[0] - b[0]) <= 24 && Math.abs(a[1] - b[1]) <= 24 && Math.abs(a[2] - b[2]) <= 24; }
  var quad, texProg, canvasTex;
  function drawCanvasTexture() {
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, 512, 512);
    gl.useProgram(texProg); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, canvasTex);
    gl.uniform1i(gl.getUniformLocation(texProg, "t"), 0);
    gl.bindVertexArray(quad); gl.drawArrays(gl.TRIANGLES, 0, 6);
    var px = new Uint8Array(4), mid, corner;
    gl.readPixels(256, 256, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); mid = Array.prototype.slice.call(px);
    gl.readPixels(6, 6, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); corner = Array.prototype.slice.call(px);
    var ok = close(mid, [220, 40, 40]) && close(corner, [30, 90, 200]);
    if (!ok) note("canvas texture pixels: middle " + mid.join(",") + " (want 220,40,40), corner " + corner.join(",") + " (want 30,90,200)");
    return ok ? 1 : 0;
  }
  function tick() { return new Promise(function (r) { setTimeout(r, 0); }); }

  window.__cmRun = async function (seconds, maxFrames) {
    var out = { renderer_before: renderer(), renderer_after: "", lost: 0, texel_ok: 0, frames: 0, alloc_ok: 1 };
    if (!gl) { out.renderer_after = "no WebGL2"; out.lost = S.lost; out.notes = S.notes; return out; }
    try {
      quad = gl.createVertexArray(); gl.bindVertexArray(quad);
      var b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      texProg = program("in vec2 uv; uniform sampler2D t; out vec4 o; void main() { o = texture(t, vec2(uv.x, 1.0 - uv.y)); }");

      // what a shadow-mapped, environment-lit three.js page allocates
      if (!gl.getExtension("EXT_color_buffer_float")) { note("no EXT_color_buffer_float"); out.alloc_ok = 0; }
      gl.getExtension("OES_texture_float_linear");
      var depth = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, depth);
      gl.texStorage2D(gl.TEXTURE_2D, 1, gl.DEPTH_COMPONENT24, 4096, 4096);
      var df = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, df);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, depth, 0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) { note("incomplete 4096 depth FBO"); out.alloc_ok = 0; }
      gl.viewport(0, 0, 4096, 4096); gl.clearDepth(1); gl.clear(gl.DEPTH_BUFFER_BIT);
      var acc = [target(gl.RGBA32F, 1920, 1080), target(gl.RGBA32F, 1920, 1080)], half = target(gl.RGBA16F, 2048, 2048);
      var cube = gl.createTexture(); gl.bindTexture(gl.TEXTURE_CUBE_MAP, cube);
      gl.texStorage2D(gl.TEXTURE_CUBE_MAP, 1, gl.RGBA16F, 2048, 2048);
      gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      var envProg = program("in vec2 uv; uniform float face; out vec4 o; void main() {" +
        " vec3 d = normalize(vec3(uv * 2.0 - 1.0, 1.0 + face)); float s = 0.0;" +
        " for (int i = 0; i < 48; i++) { s += sin(dot(d, vec3(float(i), face, 3.0)) * 7.0) * 0.02; }" +
        " o = vec4(abs(d) * 0.5 + s, 1.0); }");
      var cf = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, cf); gl.viewport(0, 0, 2048, 2048);
      gl.useProgram(envProg); gl.bindVertexArray(quad);
      for (var face = 0; face < 6; face++) {
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_CUBE_MAP_POSITIVE_X + face, cube, 0);
        gl.uniform1f(gl.getUniformLocation(envProg, "face"), face); gl.drawArrays(gl.TRIANGLES, 0, 6);
      }

      // the canvas texture (text, a red square), drawn and read back before the long loop
      canvasTex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, canvasTex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, paint2d(512, "SYENE"));
      var firstOk = drawCanvasTexture();

      // accumulation into float targets, sampling the cube map, with canvas uploads on the way
      var accProg = program("in vec2 uv; uniform sampler2D prev; uniform samplerCube env; uniform float n; out vec4 o;" +
        " void main() { vec3 d = normalize(vec3(uv * 2.0 - 1.0, 1.0)); vec3 c = texture(env, d).rgb; float s = 0.0;" +
        " for (int i = 0; i < 96; i++) { s += sin(dot(uv, vec2(float(i), n)) * 13.0); }" +
        " o = mix(texture(prev, uv), vec4(c + s * 0.001, 1.0), 1.0 / (n + 1.0)); }");
      var scratch = gl.createTexture(), sc = paint2d(256, "x"), px = new Float32Array(4), t0 = performance.now(), k = 0;
      while (performance.now() - t0 < seconds * 1000 && (!maxFrames || k < maxFrames)) {
        for (var j = 0; j < 4; j++, k++) {
          var src = acc[k % 2], dst = acc[(k + 1) % 2];
          gl.bindFramebuffer(gl.FRAMEBUFFER, dst.f); gl.viewport(0, 0, dst.w, dst.h); gl.useProgram(accProg);
          gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, src.t);
          gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_CUBE_MAP, cube);
          gl.uniform1i(gl.getUniformLocation(accProg, "prev"), 0); gl.uniform1i(gl.getUniformLocation(accProg, "env"), 1);
          gl.uniform1f(gl.getUniformLocation(accProg, "n"), k); gl.drawArrays(gl.TRIANGLES, 0, 6);
          gl.bindFramebuffer(gl.FRAMEBUFFER, half.f); gl.viewport(0, 0, half.w, half.h); gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, scratch);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, sc);
        gl.bindFramebuffer(gl.FRAMEBUFFER, acc[k % 2].f);
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.FLOAT, px);   // waits for the GPU: keeps the queue short
        out.frames = k;
        if (gl.isContextLost()) { note("context lost after " + k + " frames"); break; }
        await tick();   // lets the browser deliver events (webglcontextlost) between batches
      }
      out.texel_ok = firstOk && !gl.isContextLost() ? drawCanvasTexture() : 0;
      var err = gl.getError(); if (err && err !== gl.CONTEXT_LOST_WEBGL) note("GL error 0x" + err.toString(16));
    } catch (e) { note("exception: " + e); }
    out.renderer_after = renderer();
    out.lost = Math.max(S.lost, gl.isContextLost() ? 1 : 0);
    out.restored = S.restored; out.notes = S.notes;
    return out;
  };
})();
</script></body></html>
"""


class Pipe:
    """Chrome's --remote-debugging-pipe: JSON messages separated by NUL, written to its fd 3, read from its fd 4."""

    def __init__(self, to_chrome, from_chrome):
        self.w, self.r, self.buf, self.next_id, self.events = to_chrome, from_chrome, b"", 0, []

    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        os.write(self.w, json.dumps(msg).encode() + b"\0")
        return self.next_id

    def read(self, deadline):
        """The next message, or None at the deadline (or when Chrome is gone)."""
        while b"\0" not in self.buf:
            left = deadline - time.time()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.r], [], [], min(left, 1.0))
            if ready:
                chunk = os.read(self.r, 1 << 16)
                if not chunk:
                    return None
                self.buf += chunk
        raw, self.buf = self.buf.split(b"\0", 1)
        return json.loads(raw.decode("utf-8", "replace"))

    def call(self, method, params=None, session=None, timeout=30.0):
        mid, deadline = self.send(method, params, session), time.time() + timeout
        while True:
            m = self.read(deadline)
            if m is None:
                raise TimeoutError(f"{method}: no answer from Chrome within {timeout:g} s")
            if m.get("id") == mid:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error'].get('message')}")
                return m.get("result", {})
            self.events.append(m)

    def wait_event(self, method, timeout):
        deadline = time.time() + timeout
        for i, m in enumerate(self.events):
            if m.get("method") == method:
                del self.events[i]
                return m
        while True:
            m = self.read(deadline)
            if m is None:
                return None
            if m.get("method") == method:
                return m
            self.events.append(m)


def console_lines(events):
    """Console messages, logs and exceptions of the page, as text, in order."""
    out = []
    for m in events:
        p, meth = m.get("params") or {}, m.get("method")
        if meth == "Runtime.consoleAPICalled":
            out.append(f"console.{p.get('type')}: " + " ".join(str(a.get("value", a.get("description", "")))
                                                             for a in p.get("args") or []))
        elif meth == "Log.entryAdded":
            e = p.get("entry") or {}
            out.append(f"log.{e.get('level')}: {e.get('text')}")
        elif meth == "Runtime.exceptionThrown":
            d = p.get("exceptionDetails") or {}
            out.append("exception: " + str((d.get("exception") or {}).get("description") or d.get("text")))
        elif meth in ("Inspector.targetCrashed", "Target.targetCrashed"):
            out.append("the page's renderer process crashed")
    return out


def run_check(seconds, flags, frames=0):
    page_dir = tempfile.mkdtemp(prefix="cloudmule-webgl-")
    page = os.path.join(page_dir, "check.html")
    with open(page, "w", encoding="utf-8") as f:
        f.write(PAGE)
    stderr_path = os.path.join(page_dir, "chrome-stderr.log")
    to_r, to_w = os.pipe()       # we write, Chrome reads (its fd 3)
    from_r, from_w = os.pipe()   # Chrome writes (its fd 4), we read

    def child_fds():   # in the child: our pipe ends become its fds 3 and 4 (copied high first: no clobbering)
        a, b = os.dup(to_r), os.dup(from_w)
        os.dup2(a, 3)
        os.dup2(b, 4)

    args = (["google-chrome"] + flags + ["--enable-logging=stderr", "--v=0", "--remote-debugging-pipe",
            f"--user-data-dir={os.path.join(page_dir, 'profile')}", "--no-first-run", "--no-default-browser-check",
            "about:blank"])
    result, console, problem = None, [], ""
    try:
        with open(stderr_path, "wb") as err:
            proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=err, stderr=err, preexec_fn=child_fds,
                                    pass_fds=(3, 4))
    except OSError as e:   # no google-chrome: the gpu-graphics module did not install it
        for fd in (to_r, to_w, from_r, from_w):
            os.close(fd)
        shutil.rmtree(page_dir, ignore_errors=True)
        return None, [], "", f"could not start google-chrome ({e})"
    os.close(to_r)
    os.close(from_w)
    pipe = Pipe(to_w, from_r)
    try:
        target = pipe.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        session = pipe.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        for domain in ("Runtime.enable", "Log.enable", "Page.enable", "Inspector.enable"):
            try:
                pipe.call(domain, session=session)
            except RuntimeError:
                pass   # an older Chrome without that domain: the others still report
        pipe.call("Page.navigate", {"url": "file://" + page}, session=session)
        if pipe.wait_event("Page.loadEventFired", 60) is None:
            raise TimeoutError("the check page did not load within 60 s")
        r = pipe.call("Runtime.evaluate", {"expression": f"window.__cmRun({seconds:g}, {int(frames)})", "awaitPromise": True,
                                           "returnByValue": True}, session=session, timeout=seconds + 90)
        if "exceptionDetails" in r:
            raise RuntimeError("the check page threw: " + str(r["exceptionDetails"].get("text")))
        result = (r.get("result") or {}).get("value")
        try:
            pipe.call("Browser.close", timeout=10)
        except (TimeoutError, RuntimeError):
            pass
    except (TimeoutError, RuntimeError, OSError, ValueError, KeyError) as e:
        problem = str(e)
    finally:
        console = console_lines(pipe.events)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        os.close(to_w)
        os.close(from_r)
    with open(stderr_path, encoding="utf-8", errors="replace") as f:
        stderr = f.read()
    shutil.rmtree(page_dir, ignore_errors=True)
    return result, console, stderr, problem


def verdict(result, console, stderr, problem):
    """(exit code, reason): 0 ok, 3 GPU_NOT_USED, 4 GPU_CONTEXT_LOST."""
    if problem or not result:
        # a GPU process that crashed (and hung or killed the check) is a lost context, not a missing GPU
        for p in ("GPU process exited", "GPU process crashed"):
            if p in stderr:
                return 4, f"Chrome's log says '{p}' and the check could not finish ({problem or 'no result'})"
        return 3, f"the check could not run ({problem or 'no result from the page'})"
    before, after = str(result.get("renderer_before")), str(result.get("renderer_after"))
    text = "\n".join(console) + "\n" + stderr
    lost = int(result.get("lost") or 0)
    # a context lost at once leaves no renderer to read ("null"): that is a loss, not a missing GPU
    if "NVIDIA" not in before and not (lost and before in ("null", "", "None")):
        return 3, f"the WebGL renderer is not the NVIDIA GPU ({before})"
    for p in NOT_USED_PATTERNS:
        if p in text:
            return 3, f"Chrome's log mentions {p} (software rendering)"
    if lost > 0:
        return 4, f"the WebGL context was lost {lost} time(s)" + (" before the page could draw" if "NVIDIA" not in before else "")
    if not int(result.get("texel_ok") or 0):
        return 4, "a canvas texture came out wrong (what a lost and restored context does to a real page)"
    if "NVIDIA" not in after:
        return 3, f"the WebGL renderer changed during the check ({before} -> {after})"
    for p in PATTERNS:
        if p in text:
            return 4, f"Chrome's log says '{p}'"
    return 0, ""


def main():
    args = sys.argv[1:]
    def value(name, default):
        if name not in args:
            return default
        i = args.index(name) + 1
        if i >= len(args):
            sys.exit(f"usage: cloudmule-webgl-check [--quick] [--seconds N] [--flags-file F] ({name} needs a value)")
        return args[i]
    seconds = float(value("--seconds", 2.0 if "--quick" in args else 8.0))
    frames = int(value("--frames", 0))   # stop after this many frames (a fixed amount of work, for benchmarks)
    flags_file = value("--flags-file", "/etc/cloudmule/chrome-gpu-flags")
    with open(flags_file, encoding="utf-8") as f:
        flags = shlex.split(f.read())
    print(f"cloudmule-webgl-check: {seconds:g} s of drawing with {' '.join(flags)}", flush=True)
    t_start = time.time()
    result, console, stderr, problem = run_check(seconds, flags, frames)
    for line in console[:40]:
        print("  page " + line)
    hits = [l for l in stderr.splitlines() if any(p in l for p in PATTERNS)
            or re.search(r":(ERROR|FATAL):.*(gpu|GPU|gl_|vulkan|Vulkan|angle|ANGLE)", l)]
    for line in hits[:30]:
        print("  chrome " + line[:300])
    if result:
        print(f"WebGL renderer: {result.get('renderer_before')}")
        for n in result.get("notes") or []:
            print("  note: " + str(n))
        print(f"CHECK renderer_before={result.get('renderer_before')} renderer_after={result.get('renderer_after')} "
              f"lost={result.get('lost')} texel_ok={result.get('texel_ok')} frames={result.get('frames')} "
              f"alloc_ok={result.get('alloc_ok')} restored={result.get('restored')} "
              f"wall={time.time() - t_start:.1f}")
    code, why = verdict(result, console, stderr, problem)
    if code == 0:
        print("WEBGL_CHECK_OK")
    else:
        kind = "GPU_NOT_USED" if code == 3 else "GPU_CONTEXT_LOST"
        print(f"WEBGL_CHECK_FAIL: {kind}: {why}")
        if stderr and not hits:
            print("  chrome stderr (last lines):")
            for line in stderr.splitlines()[-15:]:
                print("    " + line[:300])
    sys.exit(code)


if __name__ == "__main__":
    main()
