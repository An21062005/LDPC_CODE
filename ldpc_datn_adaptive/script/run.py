"""ldpc_datn_adaptive launcher: python script/run.py <action> [options].

  check                         configs, generated package, Vivado
  data                          generate the datasets of config.yaml (outfeed/data)
  map                           mapper sweep: every code x allowed P_act x C_act
  sim --plan NAME               run a plan of config.yaml on ONE adaptive core
  synth                         out-of-context synth + place + route of adaptive_core
  select --code C [--max-latency-us X] [--min-info-mbps Y]
                                choose P_act/C_act; uses RTL-measured cycles
  report                        outfeed/reports/adaptive.md

Results go to outfeed/. Nothing here connects to or programs an FPGA.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outfeed"
sys.path.insert(0, str(ROOT / "script"))
import adaptive_lib as lib  # noqa: E402
import mapper  # noqa: E402

RTL = ["code/rtl/generated/adaptive_hw_pkg.sv", "code/rtl/da2_units/Utilities/LUT.v", "code/rtl/units/vnu_g.sv",
       "code/rtl/units/cnu_g.sv", "code/rtl/units/node_units.sv", "code/rtl/adaptive/adaptive_core.sv"]


def stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def cfg():
    import yaml
    return yaml.safe_load((ROOT / "script/config.yaml").read_text(encoding="utf-8"))


def rtl_sha():
    h = hashlib.sha256()
    for f in RTL:
        h.update(f.encode()); h.update((ROOT / f).read_bytes())
    return h.hexdigest()


def tool(c, name):
    folder = Path(os.environ.get("VIVADO_BIN") or c["vivado"]["bin"])
    exe = folder / (name + (".bat" if os.name == "nt" else ""))
    if not exe.is_file():
        raise SystemExit(f"{exe} not found")
    return exe


def run_tool(exe, args, cwd, log):
    cmd = [str(exe), *map(str, args)]
    if os.name == "nt":
        cmd = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *cmd]
    env = os.environ.copy()
    (cwd / "tmp").mkdir(exist_ok=True)
    env["TMP"] = env["TEMP"] = str(cwd / "tmp")
    with open(log, "w", encoding="utf-8", errors="replace") as fh:
        return subprocess.run(cmd, cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT).returncode


def dataset(c, name):
    ds = c["datasets"][name]
    folder = OUT / "data" / name
    meta = folder / "metadata.json"
    if not meta.is_file() or json.loads(meta.read_text())["snr_db"] != ds["snr"]:
        print(f"Generating dataset {name}", flush=True)
        lib.generate_data(ds["code"], ds["snr"], ds["seed"], folder)
    return folder


def cmd_sim(c, a):
    plan = c["plans"][a.plan]
    t = mapper.hardware(mapper.load_hw())
    run = OUT / "sim" / f"{a.plan}_{stamp()}"
    run.mkdir(parents=True)
    lines, segs = [], []
    for i, s in enumerate(plan["segments"], 1):
        m = mapper.make_map(t, s["code"], s["p"], s["c"])
        if not m["ok"]:
            raise SystemExit(f"segment {i}: mapper rejected {s}: {m['issues']}")
        mapper.write_map(m, run / f"seg{i}")
        folder = dataset(c, s["dataset"])
        for f in ("input.txt", "expected_codeword.txt"):
            shutil.copy2(folder / f, run / f"seg{i}" / f)
        lines.append(f"seg{i}/config.txt seg{i}/input.txt seg{i}/expected_codeword.txt {s['frames']} {m['n']}")
        segs.append(dict(s, n=m["n"], predicted_cycles=m["decode_cycles_estimate"]))
    (run / "plan.txt").write_text("\n".join(lines) + "\n", encoding="ascii")
    files = [ROOT / f for f in RTL] + [ROOT / "code/tests/tb_adaptive.sv"]
    rel = lambda p: os.path.relpath(p, run).replace("\\", "/")
    (run / "compile.prj").write_text("".join(f'sv work "{rel(f)}"\n' for f in files), encoding="ascii")
    # hang guard: 2 x (decode + load/read streaming + start/swap) per frame at 30 MHz
    timeout_us = int(sum(s["frames"] * 2 * (s["predicted_cycles"] + s["n"] + 10) for s in segs) / 30) + 1000
    (run / "plusargs.txt").write_text(f"--testplusarg PLAN=plan.txt\n--testplusarg TIMEOUT_US={timeout_us}\n",
                                      encoding="ascii")
    (run / "sim.tcl").write_text("run all\nquit\n", encoding="ascii")
    sha = rtl_sha()
    print("RUN_DIRECTORY=" + str(run), flush=True)
    rc = 0
    for name, args in (("xvlog", ["-sv", "-prj", "compile.prj", "--log", "xvlog.log"]),
                       ("xelab", ["tb_adaptive", "--relax", "--timescale", "1ns/1ps", "-s", "snap", "--mt", "4",
                                  "--log", "xelab.log"]),
                       ("xsim", ["snap", "-tclbatch", "sim.tcl", "--log", "xsim.log", "--file", "plusargs.txt"])):
        rc = run_tool(tool(c, name), args, run, run / f"{name}.out")
        if rc:
            break
    log = (run / "xsim.log").read_text(errors="replace") if (run / "xsim.log").is_file() else ""
    passed = rc == 0 and "PASS_ADAPTIVE" in log and "CFG_GUARD_OK" in log and not re.search(r"^Fatal", log, re.M)
    results = []
    for i, s in enumerate(segs, 1):
        cyc = sorted({int(v) for v in re.findall(rf"CORE_DECODE_CYCLES segment={i} transaction=\d+ cycles=(\d+)", log)})
        errs = [int(v) for v in re.findall(rf"FRAME_COMPARE segment={i} output=\d+ bit_errors=(\d+)", log)]
        out = run / f"output_segment{i}.txt"
        model_mismatch = None
        if out.is_file() and errs:
            folder = run / f"seg{i}"
            z = lib.read_input(folder / "input.txt", s["n"])[: s["frames"] - 2]
            pred, _ = lib.decode(lib.build_h(lib.load_code(s["code"])), z)
            act = lib.read_bits(out, s["n"])
            model_mismatch = int((act != pred[: len(act)]).sum()) if len(act) == len(pred) else None
        # tb counts from the start pulse (+1); the decode itself is cycles-1
        results.append(dict(s, compared_frames=len(errs), bit_errors=sum(errs), model_mismatch_bits=model_mismatch,
                            measured_cycles=[x - 1 for x in cyc], cycle_model_exact=[x - 1 for x in cyc] == [s["predicted_cycles"]]))
    ok = passed and all(r["model_mismatch_bits"] == 0 and r["bit_errors"] == 0 for r in results)
    status = dict(plan=a.plan, result="PASS" if ok else "FAIL", rtl_sha256=sha, run_directory=run.relative_to(ROOT).as_posix(),
                  cfg_guard="CFG_GUARD_OK" in log, segments=results, tool_returncode=rc)
    (run / "status.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    (OUT / "reports").mkdir(parents=True, exist_ok=True)
    (OUT / "reports" / f"latest_sim_{a.plan}.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    for r in results:
        print(f"{r['code']:14} P={r['p']:2} C={r['c']:2} frames={r['compared_frames']:3} bit_errors={r['bit_errors']} "
              f"model_mismatch={r['model_mismatch_bits']} cycles={r['measured_cycles']} predicted={r['predicted_cycles']}")
    print("RESULT=" + status["result"])
    return 0 if ok else 1


SYNTH_TCL = r"""
source files.tcl
foreach f $files {read_verilog -sv [list $f]}
synth_design -top adaptive_core -part $part -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 33.333 [get_ports clk]
report_utilization -file util_synth.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file util_synth_hier.rpt
write_checkpoint -force post_synth.dcp
foreach step {opt_design place_design route_design} {
  if {[catch {$step} msg]} {
    puts "IMPL_FAILED $step: $msg"
    puts "IMPL_ERRORINFO $::errorInfo"
    return
  }
}
write_checkpoint -force post_route.dcp
report_utilization -file util_impl.rpt
report_timing_summary -file timing_impl.rpt
puts "TIMING_RESULT WNS=[get_property SLACK [get_timing_paths -delay_type max]] WHS=[get_property SLACK [get_timing_paths -delay_type min]]"
"""


def cmd_synth(c, a):
    run = OUT / "synth" / f"adaptive_core_{stamp()}"
    run.mkdir(parents=True)
    (run / "synth.tcl").write_text(SYNTH_TCL, encoding="ascii")
    files = " ".join('"' + (ROOT / f).as_posix() + '"' for f in RTL)
    (run / "files.tcl").write_text(f"set files [list {files}]\nset part {c['vivado']['part']}\n", encoding="ascii")
    print("RUN_DIRECTORY=" + str(run), flush=True)
    rc = run_tool(tool(c, "vivado"), ["-mode", "batch", "-source", "synth.tcl", "-log", "vivado.log", "-nojournal",
                                       ], run, run / "launcher.log")
    log = (run / "vivado.log").read_text(errors="replace") if (run / "vivado.log").is_file() else ""
    st = dict(rtl_sha256=rtl_sha(), run_directory=run.relative_to(ROOT).as_posix(), tool_returncode=rc,
              note="out-of-context core only (no AXI wrapper, no PS); clock constraint 30 MHz")
    for stage in ("synth", "impl"):
        f = run / f"util_{stage}.rpt"
        if f.is_file():
            txt = f.read_text(errors="replace")
            st[f"util_{stage}"] = {k: re.search(rf"^\|\s*{re.escape(lbl)}\*?\s*\|\s*([\d.]+)\s*\|.*?\|\s*([<\d.]+)\s*\|\s*$", txt, re.M).groups()
                                   for k, lbl in (("lut", "Slice LUTs"), ("ff", "Slice Registers"), ("lutram", "LUT as Memory"),
                                                  ("bram", "Block RAM Tile")) if re.search(rf"^\|\s*{re.escape(lbl)}", txt, re.M)}
    m = re.search(r"^TIMING_RESULT WNS=([-\d.]+) WHS=([-\d.]+)", log, re.M)
    st["wns_ns"], st["whs_ns"] = (float(m[1]), float(m[2])) if m else (None, None)
    st["timing_met"] = bool(m) and float(m[1]) >= 0 and float(m[2]) >= 0
    st["impl_failed"] = (re.search(r"^IMPL_FAILED (.*)$", log, re.M) or [None, None])[1]
    st["errors"] = sorted(set(re.findall(r"^ERROR: (.*)$", log, re.M)))[:10]
    (run / "status.json").write_text(json.dumps(st, indent=2) + "\n", encoding="utf-8")
    (OUT / "reports").mkdir(parents=True, exist_ok=True)
    (OUT / "reports" / "latest_synth.json").write_text(json.dumps(st, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in st.items() if k != "errors"}, indent=2))
    return 0 if st["timing_met"] else 1


def measured_cycles():
    """(code, P, C) -> RTL decode cycles from the latest PASSING plan runs."""
    cal = {}
    for p in (OUT / "reports").glob("latest_sim_*.json"):
        s = json.loads(p.read_text())
        if s["result"] != "PASS" or s["rtl_sha256"] != rtl_sha():
            continue
        for r in s["segments"]:
            if len(r["measured_cycles"]) == 1:
                cal[(r["code"], r["p"], r["c"])] = r["measured_cycles"][0]
    return cal


def cmd_select(c, a):
    t = mapper.hardware(mapper.load_hw())
    cal = {(p, cc): v for (code, p, cc), v in measured_cycles().items() if code == a.code}
    res = mapper.select(t, a.code, a.max_latency_us, a.min_info_mbps, cal)
    print(json.dumps(res, indent=2) if res else "NO_CONFIGURATION_MEETS_REQUIREMENT")
    return 0 if res else 1


def cmd_report(c, a):
    t = mapper.hardware(mapper.load_hw())
    sha = rtl_sha()
    rows = ["## Tổ hợp mã/P_act/C_act đã chạy RTL (cùng một phần cứng)", "",
            "| Plan | Mã | P_act | C_act | Frame | Bit lỗi | Lệch mô hình | Chu kỳ RTL | Chu kỳ mapper | RTL |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    for p in sorted((OUT / "reports").glob("latest_sim_*.json")):
        s = json.loads(p.read_text())
        for r in s["segments"]:
            rows.append(f"| {s['plan']} | {r['code']} | {r['p']} | {r['c']} | {r['compared_frames']} | {r['bit_errors']} | "
                        f"{r['model_mismatch_bits']} | {r['measured_cycles']} | {r['predicted_cycles']} | "
                        f"{'hiện tại' if s['rtl_sha256'] == sha else 'cũ'} |")
    sy = OUT / "reports/latest_synth.json"
    if sy.is_file():
        s = json.loads(sy.read_text())
        rows += ["", "## Tổng hợp OOC lõi (xc7z020, 30 MHz)", "", "```", json.dumps(s, indent=2), "```"]
    text = "\n".join(rows) + "\n"
    (OUT / "reports/adaptive.md").write_text(text, encoding="utf-8")
    print(text)
    return 0


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("check", "data", "map", "sim", "synth", "select", "report"))
    ap.add_argument("--plan")
    ap.add_argument("--code")
    ap.add_argument("--max-latency-us", type=float)
    ap.add_argument("--min-info-mbps", type=float)
    a = ap.parse_args(argv)
    c = cfg()
    if a.action == "check":
        rc = mapper.main(["hw", "--check"])
        print("VIVADO=" + str(tool(c, "vivado")))
        print("RTL_SHA256=" + rtl_sha())
        return rc
    if a.action == "data":
        for n in c["datasets"]:
            print(n, dataset(c, n))
        return 0
    if a.action == "map":
        return mapper.main(["sweep"])
    return {"sim": cmd_sim, "synth": cmd_synth, "select": cmd_select, "report": cmd_report}[a.action](c, a)


if __name__ == "__main__":
    raise SystemExit(main())
