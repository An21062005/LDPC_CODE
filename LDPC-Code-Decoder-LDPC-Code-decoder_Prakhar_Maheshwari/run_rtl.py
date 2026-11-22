"""Run the LDPC decoder testbench and create output.txt.

The corrected RTL in fix/ is selected by default. Vivado XSim is preferred;
if XSim is not found, the script falls back to the Icarus Verilog flow.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path

TOP_MODULE = "Decoder_tb"
SNAPSHOT = "ldpc_decoder_sim"
VALUES_PER_FRAME = 1152


def parse_args() -> argparse.Namespace:
    project_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run the LDPC RTL decoder simulation.")
    parser.add_argument(
        "--rtl",
        choices=("fixed", "original"),
        default="fixed",
        help="RTL source set (default: fixed; original is for diagnosis only)",
    )
    parser.add_argument(
        "--simulator",
        choices=("auto", "vivado", "iverilog"),
        default="auto",
        help="simulator selection (default: auto, preferring Vivado XSim)",
    )
    parser.add_argument(
        "--vivado-bin",
        type=Path,
        default=Path(os.environ["VIVADO_BIN"]) if "VIVADO_BIN" in os.environ else None,
        help="directory containing xvlog/xelab/xsim; may also set VIVADO_BIN",
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="open XSim GUI; click Run All before closing",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=project_dir / "input.txt",
        help="RTL input file (default: input.txt)",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=1,
        help="number of real payload frames to simulate (default: 1)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=project_dir / "output.txt",
        help="RTL output file (default: output.txt)",
    )
    parser.add_argument(
        "--ordered-output",
        type=Path,
        default=project_dir / "output_ordered.txt",
        help="decoded output in Simulink/codeword order (default: output_ordered.txt)",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=project_dir / "rtl_work",
        help="simulator working directory",
    )
    return parser.parse_args()


def tool_candidates(name: str, bin_dir: Path | None) -> list[Path]:
    suffixes = (".bat", ".exe", "") if os.name == "nt" else ("",)
    candidates: list[Path] = []
    if bin_dir is not None:
        candidates.extend(bin_dir / f"{name}{suffix}" for suffix in suffixes)

    from_path = shutil.which(name)
    if from_path:
        candidates.append(Path(from_path))

    if os.name == "nt":
        for root in (
            Path("C:/Xilinx/Vivado"),
            Path("C:/AMDDesignTools/Vivado"),
            Path("D:/Xilinx/Vivado"),
            Path("D:/AMDDesignTools/Vivado"),
            # Installation layout on this machine, for example:
            # D:/vivado/2026.1/Vivado/bin/xvlog.bat
            Path("D:/vivado"),
        ):
            if root.is_dir():
                for version_dir in sorted(root.iterdir(), reverse=True):
                    for bin_path in (
                        version_dir / "bin",
                        version_dir / "Vivado" / "bin",
                    ):
                        candidates.extend(
                            bin_path / f"{name}{suffix}" for suffix in suffixes
                        )
    return candidates


def find_tool(name: str, bin_dir: Path | None) -> Path:
    for candidate in tool_candidates(name, bin_dir):
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(name)


def command_for(tool: Path, arguments: list[str]) -> list[str]:
    command = [str(tool), *arguments]
    if os.name == "nt" and tool.suffix.lower() in {".bat", ".cmd"}:
        return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *command]
    return command


def run(tool: Path, arguments: list[str], cwd: Path) -> None:
    command = command_for(tool, arguments)
    print("\n>", subprocess.list2cmdline(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def validate_input(input_path: Path) -> list[str]:
    lines = [line.strip() for line in input_path.read_text().splitlines() if line.strip()]
    if not lines:
        raise SystemExit("input.txt must contain at least one payload frame")
    for frame_number, line in enumerate(lines, start=1):
        values = line.split()
        if len(values) != VALUES_PER_FRAME:
            raise SystemExit(
                f"input frame {frame_number} has {len(values)} values; "
                f"expected {VALUES_PER_FRAME}"
            )
        invalid = next(
            (value for value in values if len(value) != 5 or set(value) - {"0", "1"}),
            None,
        )
        if invalid is not None:
            raise SystemExit(
                f"input frame {frame_number} contains invalid 5-bit value: {invalid}"
            )
    return lines


def try_vivado_tools(bin_dir: Path | None):
    try:
        return (
            find_tool("xvlog", bin_dir),
            find_tool("xelab", bin_dir),
            find_tool("xsim", bin_dir),
        )
    except FileNotFoundError:
        return None


def run_vivado(
    tools: tuple[Path, Path, Path],
    project_dir: Path,
    work_dir: Path,
    frame_count: int,
    gui: bool,
) -> None:
    xvlog, xelab, xsim = tools
    testbench = project_dir / "Decoder_tb.v"

    run(xvlog, ["--sv", "-i", str(project_dir), str(testbench)], work_dir)
    run(
        xelab,
        ["work." + TOP_MODULE, "-s", SNAPSHOT, "-debug", "typical", "-relax"],
        work_dir,
    )

    # On Windows, XSim's batch wrapper needs literal quotes around values that
    # contain '='; otherwise it parses the right-hand side as another option.
    def plusarg(value: str) -> str:
        return f'"{value}"' if os.name == "nt" else value

    arguments = [
        SNAPSHOT,
        "-testplusarg",
        plusarg(f"FRAMES={frame_count}"),
        "-testplusarg",
        plusarg("INP_FILE=input.txt"),
        "-testplusarg",
        plusarg("OUT_FILE=output.txt"),
        "-testplusarg",
        plusarg("ORDERED_OUT_FILE=output_ordered.txt"),
    ]
    if gui:
        arguments.append("-gui")
        print("XSim GUI: click Run All, wait for $finish, then close XSim.")
    else:
        arguments.extend(["-R", "-onerror", "quit", "-onfinish", "quit"])
    run(xsim, arguments, work_dir)


def run_iverilog(project_dir: Path, work_dir: Path, frame_count: int) -> None:
    iverilog_name = shutil.which("iverilog")
    vvp_name = shutil.which("vvp")
    if not iverilog_name or not vvp_name:
        raise SystemExit("Icarus Verilog requires both iverilog and vvp in PATH")

    iverilog = Path(iverilog_name)
    vvp = Path(vvp_name)
    executable = work_dir / "decoder_sim.vvp"
    run(
        iverilog,
        [
            "-g2012",
            "-I",
            str(project_dir),
            "-o",
            str(executable),
            str(project_dir / "Decoder_tb.v"),
        ],
        work_dir,
    )
    run(
        vvp,
        [
            str(executable),
            f"+FRAMES={frame_count}",
            "+INP_FILE=input.txt",
            "+OUT_FILE=output.txt",
            "+ORDERED_OUT_FILE=output_ordered.txt",
        ],
        work_dir,
    )


def main() -> None:
    args = parse_args()
    project_dir = Path(__file__).resolve().parent
    rtl_dir = project_dir / "fix" if args.rtl == "fixed" else project_dir
    input_path = args.input.resolve()
    output_path = args.output.resolve()
    ordered_output_path = args.ordered_output.resolve()
    work_dir = args.work_dir.resolve()

    if not input_path.is_file():
        raise SystemExit(f"Missing {input_path}; run: python generate_input.py")
    input_frames = validate_input(input_path)
    if args.frames < 1:
        raise SystemExit("--frames must be at least 1")
    if args.frames > len(input_frames):
        raise SystemExit(
            f"requested {args.frames} payload frames but {input_path} contains "
            f"only {len(input_frames)}"
        )
    frame_count = args.frames

    work_dir.mkdir(parents=True, exist_ok=True)
    # Copy only real payload frames. Decoder_tb creates two internal zero
    # frames to flush the pipeline, so they are no longer part of the input.
    (work_dir / "input.txt").write_text(
        "\n".join(input_frames[:frame_count]) + "\n"
    )
    work_output = work_dir / "output.txt"
    work_ordered_output = work_dir / "output_ordered.txt"
    if work_output.exists():
        work_output.unlink()
    if work_ordered_output.exists():
        work_ordered_output.unlink()

    vivado_tools = try_vivado_tools(args.vivado_bin)
    simulator = args.simulator
    if simulator == "auto":
        simulator = "vivado" if vivado_tools else "iverilog"

    print(f"Simulator: {simulator}")
    print(f"RTL source: {args.rtl} ({rtl_dir})")
    print(f"Input frames: {frame_count} payload (2 flush frames generated internally)")

    try:
        if simulator == "vivado":
            if not vivado_tools:
                raise SystemExit(
                    "Vivado XSim was not found. Add Vivado bin to PATH, set VIVADO_BIN, "
                    "or pass --vivado-bin D:/vivado/2026.1/Vivado/bin"
                )
            run_vivado(vivado_tools, rtl_dir, work_dir, frame_count, args.gui)
        else:
            if args.gui:
                raise SystemExit("--gui is only supported with Vivado XSim")
            run_iverilog(rtl_dir, work_dir, frame_count)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"RTL simulation failed with exit code {error.returncode}") from error

    if not work_output.is_file():
        raise SystemExit(
            f"Simulation did not create {work_output}. "
            "If XSim GUI was used, click Run All before closing it."
        )
    if not work_ordered_output.is_file():
        raise SystemExit(f"Simulation did not create {work_ordered_output}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ordered_output_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(work_output, output_path)
    shutil.copy2(work_ordered_output, ordered_output_path)
    output_frames = [line for line in output_path.read_text().splitlines() if line.strip()]
    print(f"Created: {output_path}")
    print(f"Created (codeword order): {ordered_output_path}")
    print(f"Decoded payload frames: {len(output_frames)}")


if __name__ == "__main__":
    main()
