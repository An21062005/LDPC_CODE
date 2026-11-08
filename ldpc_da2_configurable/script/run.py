"""ldpc_da2_configurable launcher: python script/run.py <action> [options].

Actions
  check              validate config, filelists, generated RTL, H/LUT, Vivado
  list               architectures, tests, wave profiles
  data               generate the datasets that are not stored in code/data
  model --test T     bit-accurate Python model on the test data (no Vivado)
  sim --arch A --test T [--frames F] [--waves P] [--gui]
  wave [--run DIR]   open a saved waveform (WDB + WCFG) in the Vivado GUI
  project --arch A [--gui] / build --arch A / open --arch A
  package --arch A   re-check latest build vs. latest tests; copy board package if ready
  report             comparison table of the latest results

Every result goes to outfeed/. No command connects to or programs an FPGA.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outfeed"
sys.path.insert(0, str(ROOT / "script"))
WAVE_PROFILES = ("none", "overview", "axi", "core", "all")
TOPS = {"axi": "tb_axi", "core": "tb_core", "order": "tb_pynq_codeword_order"}
TB_FILES = {"axi": ["code/tests/tb_axi.sv", "code/tests/core_monitor.sv"],
            "core": ["code/tests/tb_core.sv"], "order": ["code/tests/tb_output_order.sv"]}


def code_n():
    from ldpc_common import load_h
    return load_h().shape[1]


def stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def local(value, exists=True):
    path = (ROOT / value).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError(f"path must stay inside the project: {value}")
    if exists and not path.exists():
        raise ValueError(f"missing path: {path}")
    return path


def read_filelist(name, stack=()):
    """Same syntax as ldpc_da2: sources, +incdir+dir, -f other.f, # comments."""
    path = local(name)
    if path in stack:
        raise ValueError("filelist cycle: " + " -> ".join(p.name for p in (*stack, path)))
    files, incs = [], []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        tokens = shlex.split(line, comments=True)
        if not tokens:
            continue
        if tokens[0] == "-f" and len(tokens) == 2:
            f, i = read_filelist(tokens[1], (*stack, path)); files += f; incs += i
        elif len(tokens) == 1 and tokens[0].startswith("+incdir+"):
            incs += [local(s) for s in tokens[0][8:].split("+") if s]
        elif len(tokens) == 1 and not tokens[0].startswith(("-", "+")):
            src = local(tokens[0])
            if src.suffix not in (".v", ".sv") or not src.is_file():
                raise ValueError(f"{path.name}:{number}: require a .v/.sv file")
            files.append(src)
        else:
            raise ValueError(f"{path.name}:{number}: unsupported entry: {line}")
    return list(dict.fromkeys(files)), list(dict.fromkeys(incs))


def load_config(path):
    import yaml
    cfg = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(cfg, dict) or cfg.get("version") != 1:
        raise ValueError("config must be a mapping with version: 1")
    for key in ("vivado", "architectures", "datasets", "tests", "defaults", "waveforms"):
        if not isinstance(cfg.get(key), dict):
            raise ValueError(f"config section '{key}' must be a mapping")
    if cfg["vivado"].get("part") != "xc7z020clg400-1":
        raise ValueError("this PYNQ-Z2 project targets xc7z020clg400-1")
    for name, arch in cfg["architectures"].items():
        read_filelist(arch["filelist"])
        if type(arch.get("txn_cycles_max")) is not int or arch["txn_cycles_max"] < 1:
            raise ValueError(f"architecture {name}: txn_cycles_max must be a positive integer")
    for name, ds in cfg["datasets"].items():
        if "generate" not in ds:
            local(ds["input"]); local(ds["expected"])
    for name, t in cfg["tests"].items():
        if t.get("kind") not in TOPS:
            raise ValueError(f"test {name}: kind must be axi, core or order")
        if t["kind"] != "order" and t.get("dataset") not in cfg["datasets"]:
            raise ValueError(f"test {name}: unknown dataset")
        for a in t.get("architectures", []):
            if a not in cfg["architectures"]:
                raise ValueError(f"test {name}: unknown architecture {a}")
    d = cfg["defaults"]
    if d.get("architecture") not in cfg["architectures"] or d.get("test") not in cfg["tests"]:
        raise ValueError("defaults: unknown architecture or test")
    return cfg


def digest(paths):
    h = hashlib.sha256()
    for p in sorted(set(paths)):
        h.update(p.relative_to(ROOT).as_posix().encode()); h.update(p.read_bytes())
    return h.hexdigest()


def included(files, incs):
    """Files reached through `include from the sources (recursively)."""
    found, todo = [], list(files)
    while todo:
        text = todo.pop().read_text(encoding="utf-8", errors="replace")
        for name in re.findall(r'^\s*`include\s+"([^"]+)"', text, re.M):
            for d in incs:
                p = (d / name).resolve()
                if p.is_file():
                    if p not in found and p not in files:
                        found.append(p); todo.append(p)
                    break
    return found


def arch_sources(cfg, arch):
    files, incs = read_filelist(cfg["architectures"][arch]["filelist"])
    return files, incs, digest(files + included(files, incs))


def find_tool(cfg, override, name="vivado"):
    for value in (override, os.environ.get("VIVADO_BIN"), cfg["vivado"].get("bin"), shutil.which("vivado")):
        if value:
            p = Path(value)
            if p.is_file():
                p = p.parent
            exe = p / (name + (".bat" if os.name == "nt" else ""))
            if exe.is_file():
                return exe.resolve()
    raise ValueError("Vivado not found; use --vivado-bin or VIVADO_BIN")


def run_tool(exe, args, cwd, log):
    cmd = [str(exe), *map(str, args)]
    if os.name == "nt":
        cmd = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *cmd]
    env = os.environ.copy()
    (cwd / "tmp").mkdir(exist_ok=True)
    env["TMP"] = env["TEMP"] = str(cwd / "tmp")
    with open(log, "w", encoding="utf-8", errors="replace") as handle:
        return subprocess.run(cmd, cwd=cwd, env=env, stdout=handle, stderr=subprocess.STDOUT).returncode


def dataset_files(cfg, name):
    ds = cfg["datasets"][name]
    if "generate" not in ds:
        return local(ds["input"]), local(ds["expected"])
    folder = OUT / "data" / name
    inp, exp = folder / "input.txt", folder / "expected_codeword.txt"
    meta = folder / "metadata.json"
    want = dict(snr_db=float(ds["generate"]["snr"]), seed=int(ds["generate"]["seed"]))
    if not (inp.is_file() and exp.is_file() and meta.is_file()) or any(
            json.loads(meta.read_text())[k] != v for k, v in want.items()):
        import gen_data
        print(f"Generating dataset {name} -> {folder}", flush=True)
        if gen_data.main(["--snr", str(want["snr_db"]), "--seed", str(want["seed"]), "--out", str(folder)]):
            raise ValueError(f"dataset {name} generation failed")
    return inp, exp


def tq(value):
    value = str(value)
    for a, b in (("\\", "\\\\"), ('"', '\\"'), ("$", "\\$"), ("[", "\\["), ("]", "\\]")):
        value = value.replace(a, b)
    return '"' + value + '"'


def tlist(values):
    return "[list " + " ".join(tq(v.as_posix() if isinstance(v, Path) else v) for v in values) + "]"


def wave_groups(cfg, profile, arch, top, core_paths):
    if profile == "none":
        return []
    names = list(dict.fromkeys(["overview", *([p for p in cfg["waveforms"]] if profile == "all" else [profile])]))
    groups = []
    for prof in names:
        for g in cfg["waveforms"][prof]:
            if arch not in g.get("architectures", [arch]):
                continue
            paths = []
            for s in g["signals"]:
                for c in (core_paths if "{core}" in s else [""]):
                    paths.append(s.format(top=top, core=c))
            groups.append((g["name"], g["radix"], paths))
    return groups


SIM_TCL = r"""
source run_config.tcl
if {[llength $cfg_wave_groups] > 0} {
  create_wave_config
  set count 0
  set missing {}
  foreach item $cfg_wave_groups {
    lassign $item name radix paths
    if {$radix eq "binary"} {set radix bin}
    if {$radix eq "signed"} {set radix dec}
    set group [add_wave_group $name]
    foreach path $paths {
      set objects [get_objects -quiet $path]
      if {[llength $objects] == 0} {lappend missing $path; continue}
      add_wave -into $group -radix $radix $objects
      log_wave $objects
      incr count [llength $objects]
    }
  }
  save_wave_config waves.wcfg
  set fd [open wave_signals.txt w]
  puts $fd "LOGGED_OBJECTS=$count"
  foreach path $missing {puts $fd "NOT_IN_THIS_TOP=$path"}
  close $fd
}
if {[catch {run all} message]} {puts "XSIM_RUN_MESSAGE=$message"}
if {[llength $cfg_wave_groups] > 0} {save_wave_config waves.wcfg}
quit
"""


def model_check(cfg, dataset, frames, actual_path):
    import numpy as np
    from ldpc_common import decode, load_h, read_input
    inp, _ = dataset_files(cfg, dataset)
    count = frames - 2
    z = read_input(inp, code_n())[:count]
    predicted, _ = decode(load_h(), z)
    rows = [l.strip() for l in actual_path.read_text().splitlines() if l.strip()] if actual_path.is_file() else []
    if len(rows) != count:
        return dict(model_match=False, model_mismatch_bits=None, note=f"{len(rows)} output rows, expected {count}")
    actual = np.array([[int(c) for c in r] for r in rows], dtype=np.uint8)
    diff = int((actual != predicted).sum())
    return dict(model_match=diff == 0, model_mismatch_bits=diff)


def cmd_sim(cfg, args):
    if args.rescan:                              # launcher lost: re-read an existing run
        run = local(args.rescan)
        desc = json.loads((run / "resolved.json").read_text(encoding="utf-8"))
        desc.setdefault("simulator", "questa" if (run / "vsim.log").is_file() else "xsim")
        test = dict(cfg["tests"][desc["test"]])
        status = finish_sim(cfg, run, desc, test, desc["frames"], 0, None)
        return 0 if status["result"] == "PASS" else 1
    arch = args.arch or cfg["defaults"]["architecture"]
    name = args.test or cfg["defaults"]["test"]
    if arch not in cfg["architectures"] or name not in cfg["tests"]:
        raise ValueError("unknown --arch or --test; use 'list'")
    test = dict(cfg["tests"][name])
    if arch not in test.get("architectures", cfg["architectures"]):
        raise ValueError(f"test {name} applies to {test['architectures']} only")
    frames = args.frames if args.frames is not None else test.get("frames")
    if test["kind"] != "order" and (type(frames) is not int or frames < 3):
        raise ValueError("--frames must be >= 3 (two leading transactions are discarded)")
    waves = args.waves or cfg["defaults"]["waves"]
    if waves not in WAVE_PROFILES:
        raise ValueError(f"--waves must be one of {WAVE_PROFILES}")
    if args.gui and waves == "none":
        raise ValueError("--gui needs recorded waves")
    files, incs, sha = arch_sources(cfg, arch)
    files = files + [local(f) for f in TB_FILES[test["kind"]]]
    top = TOPS[test["kind"]]
    desc = dict(action="sim", arch=arch, test=name, kind=test["kind"], top=top, frames=frames, waves=waves,
                files=[p.relative_to(ROOT).as_posix() for p in files],
                include_dirs=[p.relative_to(ROOT).as_posix() for p in incs], rtl_sha256=sha)
    if args.dry_run:
        print(json.dumps(desc, indent=2)); return 0
    vivado = find_tool(cfg, args.vivado_bin)
    run = OUT / "sim" / f"{arch}_{name}_{stamp()}"
    (run / "stimulus").mkdir(parents=True)
    plus = []
    if test["kind"] == "order":
        shutil.copy2(local("code/data/recorded_board_raw.txt"), run / "stimulus/raw.txt")
        shutil.copy2(local("code/data/expected_codeword.txt"), run / "stimulus/expected_codeword.txt")
        plus = ["RAW_FILE=stimulus/raw.txt", "EXPECTED_FILE=stimulus/expected_codeword.txt",
                "ORDERED_FILE=output_codeword.txt"]
    else:
        inp, exp = dataset_files(cfg, test["dataset"])
        shutil.copy2(inp, run / "stimulus/input.txt"); shutil.copy2(exp, run / "stimulus/expected_codeword.txt")
        plus = ["INPUT=stimulus/input.txt", "EXPECTED=stimulus/expected_codeword.txt",
                "ACTUAL=output_codeword.txt", f"FRAMES={frames}"]
        if test["kind"] == "axi":
            poll, timeout = axi_guards(cfg, arch, frames)
            plus += [f"POLL_LIMIT={poll}", f"TIMEOUT_US={timeout}"]
    rel = lambda p: os.path.relpath(p, run).replace("\\", "/")
    glbl = vivado.parent.parent / "data/verilog/src/glbl.v"
    (run / "compile.prj").write_text("".join(f'sv work "{rel(f)}"\n' for f in files) +
                                     f'verilog work "{glbl.as_posix()}"\n', encoding="ascii")
    core_paths = ["dut/core"] if test["kind"] == "axi" else ["core"]
    groups = wave_groups(cfg, waves, arch, top, core_paths)
    lines = ["set cfg_wave_groups {}"]
    for gname, radix, paths in groups:
        esc = [p.replace("[", r"\[").replace("]", r"\]") for p in paths]
        lines.append(f"lappend cfg_wave_groups [list {tq(gname)} {tq(radix)} {tlist(esc)}]")
    (run / "run_config.tcl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (run / "sim.tcl").write_text(SIM_TCL, encoding="utf-8")
    (run / "resolved.json").write_text(json.dumps(desc, indent=2) + "\n", encoding="utf-8")
    print("RUN_DIRECTORY=" + str(run), flush=True)
    xargs = ["-sv", "-prj", "compile.prj", "--log", "xvlog.log"]
    for d in incs:
        xargs += ["-i", rel(d)]
    if cfg["architectures"][arch].get("define"):
        xargs += ["-d", cfg["architectures"][arch]["define"]]
    steps = [("xvlog", xargs),
             ("xelab", [top, *(["core_monitor"] if test["kind"] == "axi" else []), "glbl", "-L", "xpm",
                        "-L", "unisims_ver", "--relax", "--timescale", "1ns/1ps", "-s", "snap",
                        "--debug", "wave" if groups else "off", "--log", "xelab.log", "--mt", "4"]),
             ("xsim", ["snap", "-tclbatch", "sim.tcl", "--log", "xsim.log",
                       *(["-wdb", "waves.wdb"] if groups else []), "--file", "plusargs.txt"])]
    # cmd.exe splits batch-file arguments at '=', so plusargs go through a file.
    (run / "plusargs.txt").write_text("".join(f"--testplusarg {p}\n" for p in plus), encoding="ascii")
    simulator = args.sim or cfg["architectures"][arch].get("simulator", "xsim")
    desc["simulator"] = simulator
    rc, tool = 0, None
    if simulator == "xsim":
        for tool, targs in steps:
            rc = run_tool(find_tool(cfg, args.vivado_bin, tool), targs, run, run / f"{tool}.out")
            if rc != 0:
                break
        log_file = run / "xsim.log"
    else:
        rc, tool = run_questa(cfg, run, files, incs, arch, test, top, groups, plus, vivado)
        log_file = run / "vsim.log"
    status = finish_sim(cfg, run, desc, test, frames, rc, tool)
    if args.gui and status["wave_database"]:
        open_gui(cfg, args, "wave", run)
    return 0 if status["result"] == "PASS" else 1


def finish_sim(cfg, run, desc, test, frames, rc, tool):
    """Read the simulator log of a run directory and write status.json."""
    arch, name, simulator = desc["arch"], desc["test"], desc.get("simulator", "xsim")
    log_file = run / ("vsim.log" if simulator == "questa" else "xsim.log")
    log = log_file.read_text(errors="replace") if log_file.is_file() else ""
    if simulator == "questa":                   # transcript lines start with '# '
        log = re.sub(r"^# ?", "", log, flags=re.M).replace("** Fatal", "Fatal").replace("** Error", "ERROR")
    marker = {"axi": r"^PASS_DA2 ", "core": r"^PASS_CORE ", "order": r"^PASS: direct RTL AXI codeword"}[test["kind"]]
    passed = rc == 0 and bool(re.search(marker, log, re.M)) and not re.search(r"^(Fatal|FATAL|ERROR)", log, re.M)
    compares = [(int(f), int(e)) for f, e in re.findall(r"FRAME_COMPARE output=(\d+) bit_errors=(\d+)", log)]
    cyc = [int(c) for c in re.findall(r"CORE_CYCLES transaction=\d+ decode=(\d+)", log)]
    cyc += [int(c) for c in re.findall(r"CORE_DECODE_CYCLES transaction=\d+ cycles=(\d+)", log)]
    txn = [int(c) for c in re.findall(r"CORE_CYCLES transaction=\d+ decode=\d+ transaction_total=(\d+)", log)]
    status = dict(desc, result="PASS" if passed else "FAIL", tool_returncode=rc, failed_step=None if rc == 0 else tool,
                  run_directory=run.relative_to(ROOT).as_posix(), generated_this_run=True,
                  compared_frames=len(compares) if compares else (696 if passed and test["kind"] == "order" else 0),
                  bit_errors=sum(e for _, e in compares) if compares else (0 if passed and test["kind"] == "order" else None),
                  frames_with_errors=[dict(frame=f, bit_errors=e) for f, e in compares if e],
                  decode_cycles_per_frame=sorted(set(cyc[2:])) if len(cyc) > 2 else sorted(set(cyc)),
                  transaction_cycles_per_frame=sorted(set(txn[2:])) if len(txn) > 2 else sorted(set(txn)),
                  wave_database=next((p.relative_to(ROOT).as_posix() for p in (run / "waves.wdb", run / "vsim.wlf")
                                      if p.is_file()), None),
                  wave_config=next((p.relative_to(ROOT).as_posix() for p in (run / "waves.wcfg", run / "wave.do")
                                    if p.is_file()), None))
    if test.get("model_check") and test["kind"] != "order":
        status.update(model_check(cfg, test["dataset"], frames, run / "output_codeword.txt"))
        status["result"] = "PASS" if passed and status["model_match"] else "FAIL"
    (run / "status.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    rep = OUT / "reports"; rep.mkdir(parents=True, exist_ok=True)
    (rep / f"latest_sim_{arch}_{name}.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: status[k] for k in ("arch", "test", "result", "compared_frames", "bit_errors",
                                             "decode_cycles_per_frame", "run_directory")}, indent=2))
    return status


def axi_guards(cfg, arch, frames):
    """Per-frame poll limit and global timeout from the measured transaction
    length (decoder clocks, core_monitor) plus AXI traffic, with a 2x margin.
    One AXI access of tb_axi takes ~4 clocks of 10 ns; 100 ns per sample and
    per read is a safe bound. These are hang guards, not pass criteria."""
    n = code_n()
    clk_ns = 1000.0 / cfg["code"]["clock_mhz"]
    txn_ns = cfg["architectures"][arch]["txn_cycles_max"] * clk_ns
    frame_ns = txn_ns + n * 100 + (n // 36 + 1) * 3 * 100
    poll = int(2 * txn_ns / 40) + 1000
    timeout = int(frames * 2 * frame_ns / 1000) + 1000          # microseconds
    return poll, timeout


def questa_bin(cfg, name):
    folder = Path(os.environ.get("QUESTA_BIN") or cfg.get("questa", {}).get("bin", ""))
    exe = folder / (name + (".exe" if os.name == "nt" else ""))
    if not exe.is_file():
        raise ValueError("QuestaSim not found; set questa.bin in config.yaml or QUESTA_BIN")
    return exe


def run_questa(cfg, run, files, incs, arch, test, top, groups, plus, vivado):
    """QuestaSim flow, used where XSim's BASIC tier refuses the design size."""
    rel = lambda p: os.path.relpath(p, run).replace("\\", "/")
    data = vivado.parent.parent / "data"
    lib = [data / "verilog/src/glbl.v"]
    if test["kind"] != "core":                   # wrapper uses MMCM, BUFG and XPM memory
        lib += [data / "verilog/src/unisims" / f for f in ("MMCME2_ADV.v", "MMCME2_BASE.v", "BUFG.v")]
        lib += [data / "ip/xpm/xpm_memory/hdl/xpm_memory.sv"]
    vlog = ["-sv", "-work", "work", "-timescale", "1ns/1ps", "-suppress", "2583,13314",
            *[f"+incdir+{rel(d)}" for d in incs], *([f"+define+{cfg['architectures'][arch]['define']}"] if cfg["architectures"][arch].get("define") else []),
            *[rel(f) for f in files], *[p.as_posix() for p in lib]]
    logs, view = [], []
    for name, radix, paths in groups:
        r = {"binary": "binary", "hex": "hexadecimal", "unsigned": "unsigned", "signed": "decimal"}[radix]
        for p in paths:
            logs.append(f"if {{[llength [find signals {{{p}}}]] > 0}} {{log {{{p}}}}} else {{echo NOT_IN_THIS_TOP={p}}}")
            view.append(f"catch {{add wave -group {name} -radix {r} {{{p}}}}}")
    (run / "sim.do").write_text("\n".join(["onerror {resume}", *logs, "run -all", "quit -f"]) + "\n", encoding="ascii")
    if groups:                                   # layout for 'vsim -view vsim.wlf -do wave.do'
        (run / "wave.do").write_text("\n".join(view) + "\nwave zoom full\n", encoding="ascii")
    rc = run_tool(questa_bin(cfg, "vlib"), ["work"], run, run / "vlib.out")
    if rc == 0:
        rc = run_tool(questa_bin(cfg, "vlog"), vlog, run, run / "vlog.out")
        if rc:
            return rc, "vlog"
    else:
        return rc, "vlib"
    tops = [top, *(["core_monitor"] if test["kind"] == "axi" else []), "glbl"]
    vsim = ["-c", "-t", "1ps", "-l", "vsim.log", *(["-wlf", "vsim.wlf", "-voptargs=+acc"] if groups else []),
            *[f"+{p}" for p in plus], *tops, "-do", "sim.do"]
    rc = run_tool(questa_bin(cfg, "vsim"), vsim, run, run / "vsim.out")
    return rc, None if rc == 0 else "vsim"


def open_gui(cfg, args, kind, run, check=False):
    status = json.loads((run / "status.json").read_text(encoding="utf-8"))
    if kind == "wave" and status.get("simulator") == "questa":
        wlf, do = run / "vsim.wlf", run / "wave.do"
        cmd = [str(questa_bin(cfg, "vsim")), "-view", "vsim.wlf", *(["-do", "wave.do"] if do.is_file() else [])]
        if check:
            return 0 if wlf.is_file() else 1
        subprocess.Popen(cmd, cwd=run)
        print(f"QUESTA_VIEW={wlf}")
        return 0
    target = status.get("wave_database") if kind == "wave" else status.get("project")
    if not target or not local(target).is_file():
        raise ValueError(f"no saved {kind} in {run}")
    logs = run / f"view_{stamp()}"; logs.mkdir()
    vivado = find_tool(cfg, args.vivado_bin)
    targs = ["-mode", "batch" if check else "gui", "-source", ROOT / "script/open_saved.tcl", "-log", logs / "vivado.log",
             "-journal", logs / "vivado.jou", "-tclargs", kind, local(target),
             local(status["wave_config"]) if kind == "wave" and status.get("wave_config") else "", "check" if check else "gui"]
    if check:
        return run_tool(vivado, targs, logs, logs / "launcher.log")
    cmd = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(vivado), *map(str, targs)] if os.name == "nt" else [str(vivado), *map(str, targs)]
    with open(logs / "launcher.log", "w") as handle:
        proc = subprocess.Popen(cmd, cwd=logs, stdout=handle, stderr=subprocess.STDOUT,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    print(f"VIVADO_GUI_PID={proc.pid}\nGUI_LOG={logs}")
    return 0


def select_run(kind, args):
    if args.run != "latest":
        p = local(args.run)
        return p.parent if p.name == "status.json" else p
    pattern = "sim/*/status.json" if kind == "wave" else "hw/*/status.json"
    found = []
    for p in OUT.glob(pattern):
        s = json.loads(p.read_text(encoding="utf-8"))
        if args.arch and s.get("arch") != args.arch or args.test and s.get("test") != args.test:
            continue
        if (kind == "wave" and s.get("wave_database")) or (kind == "project" and s.get("project")):
            found.append(p)
    if not found:
        raise ValueError("no saved run matches; run sim/project first")
    return max(found, key=lambda p: p.stat().st_mtime_ns).parent


def cmd_hw(cfg, args):
    arch = args.arch or cfg["defaults"]["architecture"]
    if arch not in cfg["architectures"]:
        raise ValueError("unknown --arch")
    files, incs, sha = arch_sources(cfg, arch)
    run = OUT / "hw" / f"{arch}_{args.action}_{stamp()}"
    desc = dict(action=args.action, arch=arch, files=[p.relative_to(ROOT).as_posix() for p in files],
                include_dirs=[p.relative_to(ROOT).as_posix() for p in incs], rtl_sha256=sha)
    if args.dry_run:
        print(json.dumps(desc, indent=2)); return 0
    vivado = find_tool(cfg, args.vivado_bin)
    run.mkdir(parents=True)
    conf = [f"set cfg_part {tq(cfg['vivado']['part'])}", f"set cfg_threads {cfg['vivado']['threads']}",
            f"set cfg_jobs {cfg['vivado']['jobs']}", f"set cfg_files {tlist(files)}", f"set cfg_includes {tlist(incs)}",
            f"set cfg_board_repo {tq(local('code/board_files_repo').as_posix())}",
            f"set cfg_core_instance {tq(cfg['architectures'][arch]['core_instance'])}"]
    (run / "build_config.tcl").write_text("\n".join(conf) + "\n", encoding="utf-8")
    print("RUN_DIRECTORY=" + str(run), flush=True)
    rc = run_tool(vivado, ["-mode", "batch", "-source", ROOT / "script/create_project.tcl", "-log", run / "vivado.log",
                           "-journal", run / "vivado.jou", "-tclargs", args.action, run, run / "build_config.tcl"],
                  run, run / "launcher.log")
    log = (run / "vivado.log").read_text(errors="replace") if (run / "vivado.log").is_file() else ""
    status = dict(desc, run_directory=run.relative_to(ROOT).as_posix(), tool_returncode=rc,
                  project=(run / "p.xpr").relative_to(ROOT).as_posix() if (run / "p.xpr").is_file() else None)
    if args.action == "build":
        status.update(parse_build(run, log, cfg["architectures"][arch]["core_instance"]))
        evaluate_package(status, run)
    (run / "status.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in status.items() if k not in ("files", "include_dirs")}, indent=2))
    if args.gui and status.get("project"):
        open_gui(cfg, args, "project", run)
    return 0 if rc == 0 else 1


def evaluate_package(status, run):
    """Board-ready = bitstream + timing met + regression and noisy PASS on the
    same RTL SHA-256. Copies the package only then. Re-run by 'package'."""
    tests = {}
    for t in ("regression", "noisy"):
        p = OUT / "reports" / f"latest_sim_{status['arch']}_{t}.json"
        s = json.loads(p.read_text()) if p.is_file() else {}
        tests[t] = s.get("result") == "PASS" and s.get("rtl_sha256") == status["rtl_sha256"]
    status["verified_tests_same_rtl"] = tests
    status["ready_for_board"] = bool(status.get("bitstream") and status.get("timing_met") and all(tests.values()))
    if status["ready_for_board"] and not status.get("board_package"):
        pkg = OUT / "artifacts" / run.name
        pkg.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local(status["bitstream"]), pkg / "ldpc.bit")
        shutil.copy2(local(status["hwh"]), pkg / "ldpc.hwh")
        shutil.copy2(ROOT / "script/run_board.py", pkg)
        status["board_package"] = pkg.relative_to(ROOT).as_posix()
    rep = OUT / "reports"
    rep.mkdir(parents=True, exist_ok=True)
    (rep / f"latest_build_{status['arch']}.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")


def cmd_package(cfg, args):
    arch = args.arch or cfg["defaults"]["architecture"]
    runs = sorted(OUT.glob(f"hw/{arch}_build_*/status.json"), key=lambda p: p.stat().st_mtime_ns)
    if not runs:
        raise ValueError(f"no build for {arch}")
    status = json.loads(runs[-1].read_text())
    if status["rtl_sha256"] != arch_sources(cfg, arch)[2]:
        raise ValueError("RTL changed since that build; rebuild first")
    evaluate_package(status, runs[-1].parent)
    runs[-1].write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: status.get(k) for k in ("arch", "timing_met", "bitstream", "verified_tests_same_rtl",
                                                 "ready_for_board", "board_package")}, indent=2))
    return 0 if status["ready_for_board"] else 1


def util_table(text):
    """Parse 'Slice LUTs | used | ... | available | util%' style rows."""
    out = {}
    for label, key in (("Slice LUTs", "lut"), ("Slice Registers", "ff"), ("Block RAM Tile", "bram_tile"),
                       ("DSPs", "dsp"), ("LUT as Memory", "lutram")):
        m = re.search(r"^\|\s*" + re.escape(label) + r"\*?\s*\|\s*([\d.]+)\s*\|.*?\|\s*([\d.]+)\s*\|\s*([<\d.]+)\s*\|\s*$", text, re.M)
        if m:
            out[key] = dict(used=float(m[1]), available=float(m[2]), percent=m[3])
    return out


def parse_build(run, log, core):
    rep = run / "reports"
    st = {}
    for stage in ("synth", "impl"):
        f = rep / f"utilization_{stage}.rpt"
        if f.is_file():
            st[f"utilization_{stage}"] = util_table(f.read_text(errors="replace"))
        h = rep / f"utilization_{stage}_hier.rpt"
        if h.is_file():
            for line in h.read_text(errors="replace").splitlines():
                cells = [c.strip() for c in line.split("|")]
                if len(cells) > 6 and cells[1].lstrip() == core:
                    st[f"core_{stage}"] = dict(instance=core, total_luts=cells[3], logic_luts=cells[4],
                                               lutrams=cells[5], ffs=cells[7] if len(cells) > 7 else None,
                                               raw=line.strip())
                    break
    m = re.search(r"^TIMING_RESULT WNS=([-\d.]+) WHS=([-\d.]+)", log, re.M)
    st["wns_ns"], st["whs_ns"] = (float(m[1]), float(m[2])) if m else (None, None)
    st["timing_met"] = bool(m) and float(m[1]) >= 0 and float(m[2]) >= 0
    st["clock_slack"] = [dict(clock=c, period_ns=float(p), wns_ns=float(w) if w != "none" else None,
                              intra_wns_ns=float(i) if i != "none" else None,
                              fmax_intra_mhz_est=round(1000 / (float(p) - float(i)), 1) if i != "none" else None)
                         for c, p, w, i in re.findall(r"^CLOCK_SLACK (\S+) period=([\d.]+) wns=(\S+) intra_wns=(\S+)", log, re.M)]
    pw = re.search(r"^POWER_ESTIMATE total_w=([\d.]+) dynamic_w=([\d.]+) static_w=([\d.]+)", log, re.M)
    st["power_estimate_w"] = dict(total=float(pw[1]), dynamic=float(pw[2]), static=float(pw[3]),
                                  note="report_power vectorless estimate, not a board measurement") if pw else None
    b = re.search(r"^BITSTREAM=(.+)$", log, re.M)
    hw = re.search(r"^HWH=(.+)$", log, re.M)
    st["bitstream"] = Path(b[1].strip()).resolve().relative_to(ROOT).as_posix() if b else None
    st["hwh"] = Path(hw[1].strip()).resolve().relative_to(ROOT).as_posix() if hw else None
    st["errors"] = sorted(set(re.findall(r"^ERROR: (\[[^\]]+\].*)$", log, re.M)))[:20]
    st["stage_failed"] = (re.search(r"^BUILD_STAGE_FAILED=(\S+)", log, re.M) or [None, None])[1]
    return st


def cmd_model(cfg, args):
    import numpy as np
    from ldpc_common import decode, load_h, read_bits, read_input
    name = args.test or cfg["defaults"]["test"]
    test = cfg["tests"][name]
    if test["kind"] == "order":
        raise ValueError("order test has no decoder input")
    frames = args.frames or test["frames"]
    inp, exp = dataset_files(cfg, test["dataset"])
    z = read_input(inp, code_n())[:frames - 2]
    ref = read_bits(exp, code_n())[:frames - 2]
    dec, frozen_at = decode(load_h(), z)
    out = OUT / "model" / f"{name}_{stamp()}"; out.mkdir(parents=True)
    (out / "model_codeword.txt").write_text("".join("".join(map(str, r)) + "\n" for r in dec), encoding="ascii")
    errs = (dec != ref).sum(axis=1)
    raw = ((z < 0).astype(np.uint8) != ref).sum(axis=1)
    s = dict(test=name, dataset=test["dataset"], frames=int(len(dec)), channel_bit_errors=int(raw.sum()),
             decoded_bit_errors=int(errs.sum()), frames_with_errors=int((errs > 0).sum()),
             frozen_at_iteration=sorted(set(int(v) for v in frozen_at)), output=out.relative_to(ROOT).as_posix())
    (out / "status.json").write_text(json.dumps(s, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(s, indent=2))
    return 0


def cmd_report(cfg, args):
    """Tables from the latest results; a row is 'cũ' when its RTL SHA-256 is not
    the current one. Throughput/latency are core-only, at the 30 MHz decoder
    clock, from measured decode cycles (AXI/Python time excluded)."""
    code = cfg["code"]
    clk = float(code["clock_mhz"])
    current = {a: arch_sources(cfg, a)[2] for a in cfg["architectures"]}
    cur = lambda s: "hiện tại" if s.get("rtl_sha256") == current.get(s.get("arch")) else "cũ"
    rows = ["## Mô phỏng", "",
            "| Kiến trúc | Test | Mô phỏng | Kết quả | Frame so sánh | Bit lỗi | Khớp mô hình | Chu kỳ giải mã/frame | RTL |",
            "|---|---|---|---|---|---|---|---|---|"]
    sims = [json.loads(p.read_text()) for p in sorted((OUT / "reports").glob("latest_sim_*.json"))]
    for s in sims:
        if s.get("kind") == "units":
            continue
        rows.append(f"| {s['arch']} | {s['test']} | {s.get('simulator', 'xsim')} | {s['result']} | {s['compared_frames']} | "
                    f"{s['bit_errors']} | {s.get('model_match', '-')} | {s.get('decode_cycles_per_frame')} | {cur(s)} |")
    rows += ["", "## Hiệu năng lõi (đo chu kỳ trong mô phỏng, clock lõi %g MHz, không gồm AXI/Python)" % clk, "",
             "| Kiến trúc | Chu kỳ/frame | Latency lõi (µs) | Throughput lõi (Mb/s, codeword) | Throughput thông tin (Mb/s) | Chu kỳ 1 transaction trong wrapper |",
             "|---|---|---|---|---|---|"]
    for arch in cfg["architectures"]:
        cand = [s for s in sims if s["arch"] == arch and s.get("decode_cycles_per_frame") and cur(s) == "hiện tại"]
        if not cand:
            rows.append(f"| {arch} | - | - | - | - | - |"); continue
        cand = [s for s in cand if s.get("kind") == "axi"] or cand   # core_monitor count preferred
        c = max(max(s["decode_cycles_per_frame"]) for s in cand)
        txn = max((max(s["transaction_cycles_per_frame"]) for s in cand if s.get("transaction_cycles_per_frame")), default=None)
        us = c / clk
        rows.append(f"| {arch} | {c} | {us:.1f} | {code['n'] / us:.3f} | {code['k'] / us:.3f} | {txn if txn else '-'} |")
    rows += ["", "## Build PYNQ-Z2 (toàn hệ thống; 'lõi' = instance decoder)", "",
             "| Kiến trúc | Nguồn số | LUT | FF | BRAM | LUT/FF/BRAM36+18 lõi | WNS/WHS (ns) | Timing | Fmax nội clock lõi ước tính (MHz) | P ước tính (W) | Bitstream | Sẵn sàng nạp | RTL |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for arch in cfg["architectures"]:
        p = OUT / "reports" / f"latest_build_{arch}.json"
        if not p.is_file():
            rows.append(f"| {arch} | chưa build | | | | | | | | | | | |"); continue
        s = json.loads(p.read_text())
        src = "impl" if s.get("utilization_impl") else ("synth" if s.get("utilization_synth") else "-")
        u = s.get(f"utilization_{src}") or {}
        g = lambda k: f"{u[k]['used']:g} ({u[k]['percent']}%)" if k in u else "-"
        core = s.get(f"core_{src}") or {}
        craw = [c.strip() for c in core.get("raw", "").split("|")]
        cstr = f"{craw[3]}/{craw[7]}/{craw[8]}+{craw[9]}" if len(craw) > 9 else "-"
        dec = [c for c in s.get("clock_slack", []) if c["clock"].startswith("decoder_clk")]
        fmax = dec[0].get("fmax_intra_mhz_est") if dec else None
        pw = (s.get("power_estimate_w") or {}).get("total", "-")
        state = s.get("stage_failed") or ("timing đạt" if s.get("timing_met") else ("timing không đạt" if s.get("wns_ns") is not None else "-"))
        rows.append(f"| {arch} | {src} | {g('lut')} | {g('ff')} | {g('bram_tile')} | {cstr} | {s.get('wns_ns')}/{s.get('whs_ns')} | "
                    f"{state} | {fmax if fmax else '-'} | {pw} | {'có' if s.get('bitstream') else 'không'} | "
                    f"{s.get('ready_for_board')} | {cur(s)} |")
    text = "\n".join(rows) + "\n"
    (OUT / "reports").mkdir(parents=True, exist_ok=True)
    (OUT / "reports" / "comparison.md").write_text(text, encoding="utf-8")
    print(text)
    return 0


def cmd_check(cfg, args):
    import gen_rtl
    from ldpc_common import load_h, rtl_lut
    h = load_h()
    print(f"H {h.shape} column weights {sorted(set(h.sum(0).tolist()))} row weights {sorted(set(h.sum(1).tolist()))}")
    print(f"LUT.v entries 0..11: {rtl_lut()[:12].tolist()}")
    for arch in cfg["architectures"]:
        files, incs, sha = arch_sources(cfg, arch)
        print(f"ARCH {arch}: {len(files)} sources, rtl_sha256={sha[:16]}")
    rc = gen_rtl.main(["--check"])
    try:
        print("VIVADO=" + str(find_tool(cfg, args.vivado_bin)))
    except ValueError as exc:
        print("VIVADO_NOT_FOUND: " + str(exc)); rc = 1
    print("CONFIG_PASS" if rc == 0 else "CONFIG_FAIL")
    return rc


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=("check", "list", "data", "model", "sim", "wave", "project", "build", "open",
                                      "package", "report"))
    p.add_argument("--config", type=Path, default=ROOT / "script/config.yaml")
    p.add_argument("--arch")
    p.add_argument("--test")
    p.add_argument("--frames", type=int)
    p.add_argument("--waves", help="none, overview, axi, core or all")
    p.add_argument("--gui", action="store_true")
    p.add_argument("--run", default="latest", help="saved run directory or status.json")
    p.add_argument("--check", action="store_true", help="wave/open: verify in batch, no GUI")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--vivado-bin", type=Path)
    p.add_argument("--sim", choices=("xsim", "questa"), help="override the architecture's simulator")
    p.add_argument("--rescan", help="sim: rebuild status.json from an existing run directory (no simulation)")
    a = p.parse_args(argv)
    try:
        cfg = load_config(a.config.resolve())
        if a.action == "check":
            return cmd_check(cfg, a)
        if a.action == "list":
            for n, x in cfg["architectures"].items():
                print(f"arch {n:16} {x['description']}")
            for n, t in cfg["tests"].items():
                print(f"test {n:12} frames={t.get('frames', '-')!s:5} {t['description']}")
            print("waves: " + ", ".join(WAVE_PROFILES)); return 0
        if a.action == "data":
            for n, ds in cfg["datasets"].items():
                print(n, *[str(x) for x in dataset_files(cfg, n)])
            return 0
        if a.action == "model":
            return cmd_model(cfg, a)
        if a.action == "sim":
            return cmd_sim(cfg, a)
        if a.action in ("wave", "open"):
            kind = "wave" if a.action == "wave" else "project"
            run = select_run(kind, a)
            print("SAVED_RUN=" + str(run))
            return 0 if a.dry_run else open_gui(cfg, a, kind, run, a.check)
        if a.action in ("project", "build"):
            return cmd_hw(cfg, a)
        if a.action == "package":
            return cmd_package(cfg, a)
        return cmd_report(cfg, a)
    except (ValueError, OSError, KeyError) as exc:
        p.error(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
