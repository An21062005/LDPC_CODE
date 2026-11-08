"""YAML-configured Vivado/XSim launcher; no hardware programming commands."""
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
sys.path.insert(0, str(ROOT / "script/.deps"))


def local_path(value, exists=True):
    path = (ROOT / value).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError(f"Path must stay inside ldpc_da2: {value}")
    if exists and not path.exists():
        raise ValueError(f"Missing path: {path}")
    return path


def read_filelist(name, stack=()):
    """-f and +incdir+ paths are relative to ldpc_da2, never the shell cwd."""
    path = local_path(name)
    if path in stack:
        raise ValueError("Filelist cycle: " + " -> ".join(p.name for p in (*stack, path)))
    files, includes = [], []
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        tokens = shlex.split(line, comments=True)
        if not tokens:
            continue
        if tokens[0] == "-f" and len(tokens) == 2:
            subfiles, subincludes = read_filelist(tokens[1], (*stack, path))
            files.extend(subfiles); includes.extend(subincludes)
        elif len(tokens) == 1 and tokens[0].startswith("+incdir+"):
            includes.extend(local_path(s) for s in tokens[0][8:].split("+") if s)
        elif len(tokens) == 1 and not tokens[0].startswith(("-", "+")):
            source = local_path(tokens[0])
            if source.suffix not in (".v", ".sv") or not source.is_file():
                raise ValueError(f"{path.name}:{number}: require .v/.sv source")
            files.append(source)
        else:
            raise ValueError(f"{path.name}:{number}: unsupported entry: {line}")
    return list(dict.fromkeys(files)), list(dict.fromkeys(includes))


def load_config(path):
    try:
        import yaml
    except ImportError as exc:
        raise ValueError("Install YAML: python -s -m pip install --target script/.deps -r script/requirements.txt") from exc
    try:
        with path.open(encoding="utf-8") as handle:
            cfg = yaml.safe_load(handle)
    except yaml.YAMLError as exc:
        raise ValueError(f"Invalid YAML: {exc}") from exc
    if not isinstance(cfg, dict) or cfg.get("version") != 1:
        raise ValueError("YAML must be a mapping with version: 1")
    for name in ("vivado", "defaults", "data", "tests", "waveforms"):
        if not isinstance(cfg.get(name), dict):
            raise ValueError(f"YAML section '{name}' must be a mapping")
    if cfg["vivado"].get("part") != "xc7z020clg400-1":
        raise ValueError("This PYNQ-Z2 package targets xc7z020clg400-1")
    for key, maximum in (("threads", 24), ("jobs", 8)):
        v = cfg["vivado"].get(key)
        if type(v) is not int or not 1 <= v <= maximum:
            raise ValueError(f"vivado.{key} must be 1..{maximum}")
    rtl, inc = read_filelist(cfg["vivado"]["rtl_filelist"])
    if not rtl:
        raise ValueError("Empty RTL filelist")
    for name, test in cfg["tests"].items():
        if not re.fullmatch(r"[\w-]+", name) or not isinstance(test, dict):
            raise ValueError(f"Invalid test: {name}")
        if test.get("mode") not in ("full", "order") or not re.fullmatch(r"\w+", test.get("top", "")):
            raise ValueError(f"Invalid mode/top for test {name}")
        if test["mode"] == "full" and (type(test.get("frames")) is not int or not 3 <= test["frames"] <= 698):
            raise ValueError(f"Test {name}: frames must be 3..698")
        files, _ = read_filelist(test["filelist"])
        if not set(rtl).issubset(files):
            raise ValueError(f"Test {name} must include the shared RTL filelist")
    if cfg["defaults"].get("test") not in cfg["tests"]:
        raise ValueError("defaults.test does not exist")
    if cfg["defaults"].get("waves") not in {*cfg["waveforms"], "none", "all"}:
        raise ValueError("Unknown defaults.waves")
    for profile, groups in cfg["waveforms"].items():
        if not isinstance(groups, list):
            raise ValueError(f"waveforms.{profile} must be a list")
        for group in groups:
            if group.get("radix") not in ("binary", "hex", "unsigned", "signed") or not isinstance(group.get("signals"), list):
                raise ValueError(f"Invalid waveform group in {profile}")
    for key in ("input", "expected", "raw"):
        local_path(cfg["data"][key])
    return cfg, rtl, inc


def quote_tcl(value):
    value = str(value)
    for a, b in (("\\", "\\\\"), ('"', '\\"'), ("$", "\\$"), ("[", "\\["), ("]", "\\]"), ("\n", "\\n"), ("\r", "\\r")):
        value = value.replace(a, b)
    return '"' + value + '"'


def tcl_list(values):
    return "[list " + " ".join(quote_tcl(v.as_posix() if isinstance(v, Path) else v) for v in values) + "]"


def rtl_digest():
    h = hashlib.sha256()
    for p in sorted((ROOT/"code/rtl").rglob("*")):
        if p.is_file():
            h.update(p.relative_to(ROOT).as_posix().encode()); h.update(p.read_bytes())
    return h.hexdigest()


def find_tool(cfg, override):
    for value in (override, os.environ.get("VIVADO_BIN"), cfg["vivado"].get("bin"), shutil.which("vivado")):
        if value:
            p = Path(value)
            if p.is_dir():
                p /= "vivado.bat" if os.name == "nt" else "vivado"
            if p.is_file():
                return p.resolve()
    raise ValueError("Vivado not found; set --vivado-bin or VIVADO_BIN")


def command_for(tool, mode, script, logs, args):
    cmd = [str(tool), "-mode", mode, "-source", str(script), "-log", str(logs/"vivado.log"),
           "-journal", str(logs/"vivado.jou"), "-tclargs", *map(str, args)]
    if os.name == "nt" and tool.suffix.lower() in (".bat", ".cmd"):
        cmd = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *cmd]
    return cmd


def run_env(run):
    env = os.environ.copy(); env.setdefault("PROCESSOR_ARCHITECTURE", "AMD64")
    (run/"tmp").mkdir(exist_ok=True)
    env["TMP"] = env["TEMP"] = str(run/"tmp")
    return env


def select_run(value, test=None, kind="wave"):
    if value != "latest":
        p = local_path(value)
        return p.parent if p.is_file() and p.name == "status.json" else p
    matches = []
    for p in OUT.glob("*/status.json"):
        s = json.loads(p.read_text(encoding="utf-8"))
        if test and s.get("test") != test:
            continue
        if kind == "wave" and not s.get("wave_database"):
            continue
        if kind == "project" and not (p.parent/"p.xpr").exists():
            continue
        matches.append(p)
    if not matches:
        raise ValueError("No saved run matches; run a simulation first")
    return max(matches, key=lambda p: p.stat().st_mtime_ns).parent


def open_saved(tool, run, kind, check=False):
    status = json.loads((run/"status.json").read_text(encoding="utf-8"))
    target = status.get("wave_database") if kind == "wave" else status.get("project", (run/"p.xpr").relative_to(ROOT).as_posix())
    if not target or not local_path(target).is_file():
        raise ValueError(f"No saved {kind}; simulate with --waves overview to record waveforms")
    wcfg = status.get("wave_config")
    logs = run/("view_"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")); logs.mkdir()
    cmd = command_for(tool, "batch" if check else "gui", ROOT/"script/open_saved.tcl", logs,
                      [kind, local_path(target), local_path(wcfg) if wcfg else "", "check" if check else "gui"])
    if check:
        return subprocess.run(cmd, cwd=OUT, env=run_env(run)).returncode
    # Only the helper console is hidden. The requested Vivado IDE is visible.
    with (logs/"launcher.log").open("w", encoding="utf-8") as handle:
        proc = subprocess.Popen(cmd, cwd=OUT, env=run_env(run), stdout=handle, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    print(f"VIVADO_GUI_PID={proc.pid}\nGUI_LOG={logs}")
    return 0


def make_run_config(run, cfg, test, files, includes, rtl, rtl_inc, waves, pe):
    fields = dict(cfg_root=ROOT.as_posix(), cfg_run=run.as_posix(), cfg_part=cfg["vivado"]["part"],
                  cfg_threads=cfg["vivado"]["threads"], cfg_jobs=cfg["vivado"]["jobs"], cfg_top=test.get("top", ""),
                  cfg_mode=test.get("mode", ""), cfg_frames=test.get("frames", 0), cfg_waves=waves,
                  cfg_rtl_sha256=rtl_digest())
    lines = [f"set {k} {quote_tcl(v)}" for k, v in fields.items()]
    for name, values in (("cfg_files", files), ("cfg_includes", includes), ("cfg_rtl_files", rtl), ("cfg_rtl_includes", rtl_inc)):
        lines.append(f"set {name} {tcl_list(values)}")
    lines.append("set cfg_wave_groups {}")
    profiles = [] if waves == "none" else list(dict.fromkeys(["overview", *(cfg["waveforms"] if waves == "all" else [waves])]))
    for profile in profiles:
        for group in cfg["waveforms"][profile]:
            paths = [s.format(top=test.get("top", ""), row=pe[0], col=pe[1]) for s in group["signals"]]
            paths = [s.replace("[", r"\[").replace("]", r"\]") for s in paths]
            label = group['name'].format(row=pe[0], col=pe[1])
            lines.append(f"lappend cfg_wave_groups [list {quote_tcl(label)} {quote_tcl(group['radix'])} {tcl_list(paths)}]")
    path = run/"run_config.tcl"; path.write_text("\n".join(lines)+"\n", encoding="utf-8")
    return path


def execute(args, cfg, rtl, rtl_inc):
    sim = args.action in ("sim", "simulate")
    name = args.test or cfg["defaults"]["test"]
    if args.mode:
        name = "order" if args.mode == "order" else "regression"
    if name not in cfg["tests"]:
        raise ValueError(f"Unknown test '{name}'; use 'list'")
    test = dict(cfg["tests"][name])
    if args.frames is not None:
        if test["mode"] != "full" or not 3 <= args.frames <= 698:
            raise ValueError("--frames is only for full-mode tests and must be 3..698")
        test["frames"] = args.frames
    waves = args.waves or cfg["defaults"]["waves"]
    if waves not in {*cfg["waveforms"], "none", "all"}:
        raise ValueError("Unknown wave profile; use 'list'")
    try:
        pe = tuple(int(v) for v in args.pe.split(","))
        if len(pe) != 2 or any(v not in range(6) for v in pe):
            raise ValueError()
    except ValueError as exc:
        raise ValueError("--pe must be row,col in 0..5; this only selects DISPLAY signals") from exc
    if args.gui and sim and waves == "none":
        raise ValueError("--gui needs recorded waves; select --waves overview")
    files, inc = read_filelist(test["filelist"]) if sim else (rtl, rtl_inc)
    desc = dict(action="simulate" if sim else args.action, test=name if sim else None,
                top=test["top"] if sim else "ldpc_system_wrapper", frames=test.get("frames") if sim else None,
                waves=waves if sim else None, pe=pe, files=[p.relative_to(ROOT).as_posix() for p in files],
                include_dirs=[p.relative_to(ROOT).as_posix() for p in inc])
    if args.dry_run:
        print(json.dumps(desc, indent=2)); return 0
    tool = find_tool(cfg, args.vivado_bin)
    run = OUT/(("s_"+name+"_" if sim else "h_")+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ"))
    run.mkdir(parents=True); logs=run/"logs"; logs.mkdir()
    config = make_run_config(run, cfg, test, files, inc, rtl, rtl_inc, waves, pe)
    (run/"resolved.json").write_text(json.dumps(desc, indent=2)+"\n", encoding="utf-8")
    if sim:
        (run/"stimulus").mkdir()
        for key, filename in (("input", "input.txt"), ("expected", "expected_codeword.txt"), ("raw", "raw.txt")):
            shutil.copy2(local_path(cfg["data"][key]), run/"stimulus"/filename)
        script, tclargs = ROOT/"script/simulate.tcl", [config]
    else:
        script, tclargs = ROOT/"script/create_project.tcl", ["build" if args.action == "build" else "project", run, config]
    fingerprint = rtl_digest()
    print("RUN_DIRECTORY="+str(run), flush=True)
    result = subprocess.run(command_for(tool, "batch", script, logs, tclargs), cwd=OUT, env=run_env(run))
    log = (logs/"vivado.log").read_text(encoding="utf-8", errors="replace") if (logs/"vivado.log").exists() else ""
    simlog = run/"p.sim/sim_1/behav/xsim/simulate.log"
    testlog = simlog.read_text(encoding="utf-8", errors="replace") if simlog.exists() else ""
    comparisons = [(int(f), int(e)) for f, e in re.findall(r"FRAME_COMPARE output=(\d+) bit_errors=(\d+)", testlog)]
    success = result.returncode == 0
    if sim:
        marker = r"^PASS_DA2 " if test["mode"] == "full" else r"^PASS: direct RTL AXI codeword output matched "
        success = success and bool(re.search(marker, testlog, re.M))
    timing = re.search(r"^TIMING_RESULT WNS=([-\d.]+) WHS=([-\d.]+)", log, re.M)
    ready = re.search(r"^BOARD_PACKAGE_READY=(.+)$", log, re.M)
    if args.action == "build":
        success = success and bool(timing) and bool(ready)
    wdb = next(run.glob("p.sim/sim_1/behav/xsim/*.wdb"), None) if sim and waves != "none" else None
    wcfg = run/"waves.wcfg"
    order_ok = sim and test["mode"] == "order" and success
    status = dict(action="simulate" if sim else args.action, test=name if sim else None,
                  mode=test["mode"] if sim else None, frames=test.get("frames") if sim else None,
                  run_directory=run.relative_to(ROOT).as_posix(), project=(run/"p.xpr").relative_to(ROOT).as_posix(),
                  rtl_sha256=fingerprint, result="PASS" if success else "FAIL", returncode=result.returncode,
                  generated_this_run=True, ready_for_board=bool(args.action == "build" and success),
                  compared_frames=len(comparisons) if comparisons else (696 if order_ok else None),
                  bit_errors=sum(e for _, e in comparisons) if comparisons else (0 if order_ok else None),
                  frame_errors=[dict(frame=f, bit_errors=e) for f, e in comparisons], wave_profile=waves if sim else None,
                  wave_database=wdb.relative_to(ROOT).as_posix() if wdb else None,
                  wave_config=wcfg.relative_to(ROOT).as_posix() if wcfg.exists() else None,
                  wns_ns=float(timing[1]) if timing else None, whs_ns=float(timing[2]) if timing else None,
                  board_package=ready[1].strip() if ready else None)
    (run/"status.json").write_text(json.dumps(status, indent=2)+"\n", encoding="utf-8")
    report = OUT/"reports"/("latest_simulate_"+test["mode"]+".json" if sim else "latest_"+args.action+".json")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(status, indent=2)+"\n", encoding="utf-8")
    if sim:
        (OUT/"reports"/("latest_test_"+name+".json")).write_text(json.dumps(status, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(status, indent=2), flush=True)
    if args.gui:
        open_saved(tool, run, "wave" if sim else "project")
    return 0 if success else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "check", "sim", "simulate", "build", "project", "wave", "open"))
    parser.add_argument("--config", type=Path, default=ROOT/"script/vivado.yaml")
    parser.add_argument("--test", help="test name from script/vivado.yaml")
    parser.add_argument("--frames", type=int)
    parser.add_argument("--waves", help="none, overview, axi, pe or all")
    parser.add_argument("--pe", default="0,0", help="row,col of PE to DISPLAY; does not change hardware")
    parser.add_argument("--gui", action="store_true", help="open saved waveform/project after the run")
    parser.add_argument("--run", default="latest", help="saved run directory, status.json, or latest")
    parser.add_argument("--check", action="store_true", help="validate saved WDB/WCFG in batch instead of GUI")
    parser.add_argument("--dry-run", action="store_true", help="resolve config/filelist without starting Vivado")
    parser.add_argument("--vivado-bin", type=Path)
    parser.add_argument("--mode", choices=("full", "order"), help="legacy option; prefer --test")
    args = parser.parse_args(argv)
    try:
        cfg, rtl, inc = load_config(args.config.resolve())
        if args.action == "list":
            for name, test in cfg["tests"].items():
                print(f"{name:12} frames={str(test.get('frames', '696 captured')):13} {test.get('description', '')}")
            print("Wave profiles: none, "+", ".join(cfg["waveforms"])+", all"); return 0
        if args.action == "check":
            print(f"CONFIG_PASS: {len(cfg['tests'])} tests, {len(rtl)} RTL compilation units; includes: {inc}"); return 0
        if args.action in ("wave", "open"):
            kind = "wave" if args.action == "wave" else "project"
            run = select_run(args.run, args.test, kind)
            if args.dry_run:
                print("SAVED_RUN="+str(run)); return 0
            return open_saved(find_tool(cfg, args.vivado_bin), run, kind, args.check)
        return execute(args, cfg, rtl, inc)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.error(str(exc))
