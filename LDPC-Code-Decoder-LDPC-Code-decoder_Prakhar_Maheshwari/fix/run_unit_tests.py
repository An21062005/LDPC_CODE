"""Compile and run the fixed RTL unit tests with Vivado XSim."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


TESTS = (
    "tb_utilities",
    "tb_memory_ag",
    "tb_cnu",
    "tb_vnu",
    "tb_permutations",
)


def find_vivado_bin() -> Path:
    candidates = []
    if os.environ.get("VIVADO_BIN"):
        candidates.append(Path(os.environ["VIVADO_BIN"]))
    candidates.extend(
        (
            Path("D:/vivado/2026.1/Vivado/bin"),
            Path("C:/Xilinx/Vivado/2026.1/bin"),
            Path("D:/Xilinx/Vivado/2026.1/bin"),
        )
    )
    for candidate in candidates:
        if (candidate / "xvlog.bat").is_file():
            return candidate.resolve()
    path_tool = shutil.which("xvlog")
    if path_tool:
        return Path(path_tool).resolve().parent
    raise SystemExit("Vivado XSim not found; set VIVADO_BIN")


def invoke(tool: Path, arguments: list[str], cwd: Path) -> str:
    command = [str(tool), *arguments]
    if os.name == "nt" and tool.suffix.lower() in {".bat", ".cmd"}:
        command = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *command]
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    return result.stdout


def main() -> None:
    fix_dir = Path(__file__).resolve().parent
    vivado_bin = find_vivado_bin()
    failed = []

    for top in TESTS:
        print(f"\n===== {top} =====", flush=True)
        work = fix_dir / "work" / top
        work.mkdir(parents=True, exist_ok=True)
        try:
            invoke(
                vivado_bin / "xvlog.bat",
                ["--sv", "-i", str(fix_dir), str(fix_dir / "tests" / f"{top}.sv")],
                work,
            )
            invoke(
                vivado_bin / "xelab.bat",
                [f"work.{top}", "-s", top, "-relax"],
                work,
            )
            output = invoke(
                vivado_bin / "xsim.bat",
                [top, "-R", "-onerror", "quit", "-onfinish", "quit"],
                work,
            )
            if f"PASS {top}" not in output or "Fatal:" in output:
                raise RuntimeError(f"{top} did not report PASS")
        except (subprocess.CalledProcessError, RuntimeError):
            failed.append(top)

    print("\n===== SUMMARY =====")
    if failed:
        print("FAIL:", ", ".join(failed))
        raise SystemExit(1)
    print(f"PASS: all {len(TESTS)} unit tests")


if __name__ == "__main__":
    main()
