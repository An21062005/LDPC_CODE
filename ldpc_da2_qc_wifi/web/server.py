"""Local web page for ldpc_da2_qc_wifi: pick an architecture, press Run, watch the
log live, read the numbers.

  python web/server.py [--port 8765] [--no-browser]

Serves http://127.0.0.1:PORT (this computer only). 'Run' starts
  python script/run.py flow --arch A --steps S --test T
and streams its output plus the simulator/Vivado logs of the run directory it
is working in. Numbers are read from outfeed/reports (written by run.py); this
server writes no files.
"""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse
import webbrowser

WEB = Path(__file__).resolve().parent
ROOT = WEB.parent
sys.path.insert(0, str(ROOT / "script"))
import run as launcher  # noqa: E402  (script/run.py)

CONFIG = ROOT / "script/config.yaml"
MAX_LINES = 20000
FRAME_RE = re.compile(r"FRAME_COMPARE output=(\d+) bit_errors=(\d+)")


def load_cfg():
    return launcher.load_config(CONFIG)


def arch_order(cfg):
    flow = (cfg.get("flow") or {}).get("architectures") or []
    return [a for a in flow if a in cfg["architectures"]] + [a for a in cfg["architectures"] if a not in flow]


# ---------------------------------------------------------------- run job

class Job:
    def __init__(self):
        self.lock = threading.Lock()
        self.tail_lock = threading.Lock()
        self.proc = None
        self._reset({})

    def _reset(self, params):
        self.params, self.lines, self.base = params, [], 0
        self.state, self.rc, self.started, self.ended = "idle", None, None, None
        self.current, self.run_dir, self.offsets = None, None, {}
        self.frames, self.summary, self.stopping = [], None, False

    def add(self, text, src):
        with self.lock:
            self.lines.append([src, text])
            if len(self.lines) > MAX_LINES:
                drop = len(self.lines) - MAX_LINES
                del self.lines[:drop]
                self.base += drop
            m = FRAME_RE.search(text)
            if m:
                self.frames.append([int(m[1]), int(m[2])])

    def start(self, arch, test, steps):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                raise ValueError("đang có một lần chạy khác")
            self._reset(dict(arch=arch, test=test, steps=steps))
            self.state, self.started = "running", time.time()
        cmd = [sys.executable, "-u", str(ROOT / "script/run.py"), "flow", "--arch", arch,
               "--steps", ",".join(steps), "--test", test]
        self.add("$ python script/run.py " + " ".join(cmd[3:]), "web")
        env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
        group = (dict(creationflags=subprocess.CREATE_NEW_PROCESS_GROUP) if os.name == "nt"
                 else dict(start_new_session=True))
        self.proc = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     encoding="utf-8", errors="replace", env=env, **group)
        threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()
        threading.Thread(target=self._watch, args=(self.proc,), daemon=True).start()

    def stop(self):
        p = self.proc
        if not p or p.poll() is not None:
            return False
        self.stopping = True
        self.add("Đang dừng (kill cả cây tiến trình, gồm Vivado/XSim)...", "web")
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
        else:
            os.killpg(p.pid, signal.SIGTERM)
        return True

    def _read(self, proc):
        for line in proc.stdout:
            line = line.rstrip("\r\n")
            m = re.match(r"FLOW_STEP arch=(\S+) step=(\S+)", line)
            if m:
                self._tail()
                with self.lock:
                    self.current = dict(arch=m[1], step=m[2], since=time.time())
                    self.run_dir, self.offsets, self.frames = None, {}, []
            self.add(line, "run")
            if line.startswith("RUN_DIRECTORY="):
                with self.lock:
                    self.run_dir, self.offsets = Path(line.split("=", 1)[1].strip()), {}
        rc = proc.wait()
        self._tail()
        with self.lock:
            texts = [t for s, t in self.lines if s == "run"]
            idx = next((i for i, t in enumerate(texts) if t.startswith("FLOW_SUMMARY ")), None)
            if idx is not None:
                try:
                    self.summary = json.loads("\n".join([texts[idx][len("FLOW_SUMMARY "):], *texts[idx + 1:]]))
                except ValueError:
                    self.summary = None
            self.rc, self.ended = rc, time.time()
            self.state = "stopped" if self.stopping else ("done" if rc == 0 else "failed")

    def _watch(self, proc):
        while proc.poll() is None:
            self._tail()
            time.sleep(0.7)

    def _tail(self):
        """Append the new complete lines of the tool logs in the run directory."""
        with self.tail_lock:
            d = self.run_dir
            if not d or not d.is_dir():
                return
            files = [p for p in sorted(d.glob("*.log")) if p.name != "launcher.log"]
            files += sorted(d.glob("p.runs/*/runme.log"))
            for p in files:
                try:
                    size = p.stat().st_size
                except OSError:
                    continue
                off = self.offsets.get(p, 0)
                if size <= off:
                    continue
                with open(p, "rb") as f:
                    f.seek(off)
                    data = f.read(size - off)
                cut = data.rfind(b"\n")
                if cut < 0:
                    continue
                self.offsets[p] = off + cut + 1
                src = p.parent.name if p.name == "runme.log" else p.name
                for raw in data[:cut].decode("utf-8", "replace").splitlines():
                    self.add(raw.rstrip("\r"), src)

    def snapshot(self, since):
        with self.lock:
            start = max(since - self.base, 0)
            lines = self.lines[start:start + 4000]
            run_dir = None
            if self.run_dir:
                try:
                    run_dir = self.run_dir.resolve().relative_to(ROOT).as_posix()
                except ValueError:
                    run_dir = str(self.run_dir)
            return dict(state=self.state, params=self.params, started=self.started, ended=self.ended, rc=self.rc,
                        now=time.time(), current=self.current, run_dir=run_dir, frames=list(self.frames),
                        summary=self.summary, lines=lines, next=self.base + start + len(lines))


JOB = Job()


# ---------------------------------------------------------------- results

def run_times(run_directory):
    """(finished local time, duration in seconds) from the run directory stamp
    (UTC start, set by run.py) and the last write of the tool log. status.json
    is not used: 'package' and 'sim --rescan' rewrite it later."""
    run = ROOT / (run_directory or "")
    log = next((run / f for f in ("vivado.log", "xsim.log", "vsim.log", "status.json") if (run / f).is_file()), None)
    if not run_directory or log is None:
        return None, None
    end = log.stat().st_mtime
    finished = datetime.fromtimestamp(end).strftime("%d/%m/%Y %H:%M")
    m = re.search(r"_(\d{8}T\d{6}Z)$", run_directory or "")
    if not m:
        return finished, None
    start = datetime.strptime(m[1], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()
    return finished, round(end - start) if end >= start else None


def results():
    cfg = load_cfg()
    code = cfg["code"]
    clk = float(code["clock_mhz"])
    rep = launcher.OUT / "reports"
    out = {}
    for arch in arch_order(cfg):
        sha = launcher.arch_sources(cfg, arch)[2]
        sims = []
        for p in sorted(rep.glob(f"latest_sim_{arch}_*.json")):
            s = json.loads(p.read_text(encoding="utf-8"))
            if s.get("arch") != arch:
                continue
            finished, dur = run_times(s.get("run_directory"))
            cyc, txn = s.get("decode_cycles_per_frame") or [], s.get("transaction_cycles_per_frame") or []
            sims.append(dict(test=s.get("test"), kind=s.get("kind"), result=s.get("result"),
                             compared_frames=s.get("compared_frames"), bit_errors=s.get("bit_errors"),
                             frames_with_errors=len(s.get("frames_with_errors") or []),
                             model_match=s.get("model_match"), cycles=max(cyc) if cyc else None,
                             txn_cycles=max(txn) if txn else None, simulator=s.get("simulator", "xsim"),
                             run_directory=s.get("run_directory"), finished=finished, duration_s=dur,
                             current=None if s.get("kind") == "units" else s.get("rtl_sha256") == sha))
        perf = None
        cand = [s for s in sims if s["cycles"] and s["current"]]
        cand = [s for s in cand if s["kind"] == "axi"] or cand            # same choice as 'run.py report'
        if cand:
            best = max(cand, key=lambda s: s["cycles"])
            us = best["cycles"] / clk
            perf = dict(cycles=best["cycles"], txn_cycles=best["txn_cycles"], latency_us=us,
                        throughput_mbps=code["n"] / us, info_mbps=code["k"] / us, from_test=best["test"])
        build = None
        bp = rep / f"latest_build_{arch}.json"
        if bp.is_file():
            b = json.loads(bp.read_text(encoding="utf-8"))
            src = "impl" if b.get("utilization_impl") else ("synth" if b.get("utilization_synth") else None)
            u = b.get(f"utilization_{src}") or {}
            core = b.get(f"core_{src}") or {}
            dec = [c for c in b.get("clock_slack") or [] if c["clock"].startswith("decoder_clk")]
            finished, dur = run_times(b.get("run_directory"))
            build = dict(action=b.get("action"), source=src,
                         util={k: u[k] for k in ("lut", "ff", "bram_tile", "dsp") if k in u},
                         core_luts=int(core["total_luts"]) if str(core.get("total_luts", "")).isdigit() else None,
                         core_ffs=int(core["ffs"]) if str(core.get("ffs", "")).isdigit() else None,
                         wns_ns=b.get("wns_ns"), whs_ns=b.get("whs_ns"), timing_met=b.get("timing_met"),
                         stage_failed=b.get("stage_failed"), errors=(b.get("errors") or [])[:3],
                         fmax_decoder_mhz=dec[0].get("fmax_intra_mhz_est") if dec else None,
                         power_w=(b.get("power_estimate_w") or {}).get("total"),
                         bitstream=bool(b.get("bitstream")), ready_for_board=b.get("ready_for_board"),
                         run_directory=b.get("run_directory"), finished=finished, duration_s=dur,
                         current=b.get("rtl_sha256") == sha)
        out[arch] = dict(sims=sims, perf=perf, build=build)
    return dict(archs=out, order=arch_order(cfg))


def config_view():
    cfg = load_cfg()
    flow = cfg.get("flow") or {}
    return dict(code=cfg["code"], part=cfg["vivado"]["part"], order=arch_order(cfg),
                architectures={a: dict(description=x.get("description", "")) for a, x in cfg["architectures"].items()},
                tests={t: dict(description=x.get("description", ""), kind=x.get("kind"), frames=x.get("frames"))
                       for t, x in cfg["tests"].items()},
                steps=list(launcher.FLOW_STEPS), default_arch=cfg["defaults"]["architecture"],
                default_test=flow.get("test") or cfg["defaults"]["test"])


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _local_host(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        return host in ("127.0.0.1", "localhost")

    def do_GET(self):
        if not self._local_host():
            return self._send(403, {"error": "host"})
        url = urlparse(self.path)
        try:
            if url.path in ("/", "/index.html"):
                return self._send(200, (WEB / "index.html").read_bytes(), "text/html; charset=utf-8")
            if url.path == "/api/config":
                return self._send(200, config_view())
            if url.path == "/api/results":
                return self._send(200, results())
            if url.path == "/api/job":
                since = int((parse_qs(url.query).get("since") or ["0"])[0])
                return self._send(200, JOB.snapshot(since))
            return self._send(404, {"error": "not found"})
        except (ValueError, OSError, KeyError) as exc:
            return self._send(500, {"error": str(exc)})

    def do_POST(self):
        # The custom header blocks cross-site form posts (no CORS preflight is answered).
        if not self._local_host() or self.headers.get("X-LDPC") != "1":
            return self._send(403, {"error": "forbidden"})
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 10000)
            body = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/api/run":
                cfg = load_cfg()
                arch, test, steps = body.get("arch"), body.get("test"), body.get("steps")
                if arch not in cfg["architectures"] or test not in cfg["tests"]:
                    raise ValueError("kiến trúc hoặc test không hợp lệ")
                if not isinstance(steps, list) or not steps or any(s not in launcher.FLOW_STEPS for s in steps):
                    raise ValueError("chọn ít nhất một bước: sim, synth, impl")
                JOB.start(arch, test, [s for s in launcher.FLOW_STEPS if s in steps])
                return self._send(200, {"ok": True})
            if self.path == "/api/stop":
                return self._send(200, {"ok": JOB.stop()})
            return self._send(404, {"error": "not found"})
        except (ValueError, OSError, KeyError) as exc:
            return self._send(400, {"error": str(exc)})


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--no-browser", action="store_true")
    a = p.parse_args(argv)
    load_cfg()                                          # fail early on a broken config
    server = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    url = f"http://127.0.0.1:{a.port}/"
    print(f"LDPC web: {url}  (Ctrl+C để tắt)", flush=True)
    if not a.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        JOB.stop()
        server.server_close()


if __name__ == "__main__":
    main()
