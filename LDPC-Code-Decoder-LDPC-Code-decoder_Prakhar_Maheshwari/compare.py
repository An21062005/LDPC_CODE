"""Compare clean LDPC codewords with the RTL decoder output bit by bit."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

import verilog_decoder


L = 32
K = 6
N = L * K * K


def parse_args() -> argparse.Namespace:
    project_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Compare expected and RTL LDPC codewords.")
    parser.add_argument(
        "--expected",
        type=Path,
        default=project_dir / "expected_codeword.txt",
        help="clean codewords made by generate_input.py",
    )
    parser.add_argument(
        "--actual",
        type=Path,
        default=project_dir / "output.txt",
        help="raw codewords produced by Decoder_tb.v",
    )
    parser.add_argument(
        "--show",
        type=int,
        default=20,
        help="maximum mismatch positions to print (default: 20)",
    )
    return parser.parse_args()


def nonempty_lines(path: Path) -> list[str]:
    if not path.is_file():
        raise SystemExit(f"File not found: {path}")
    return ["".join(line.split()).lower() for line in path.read_text().splitlines() if line.strip()]


def parse_expected(path: Path) -> list[np.ndarray]:
    frames = []
    for frame_number, text in enumerate(nonempty_lines(path), start=1):
        if len(text) != N or set(text) - {"0", "1"}:
            raise SystemExit(
                f"Invalid expected frame {frame_number}: need exactly {N} binary bits"
            )
        frames.append(np.fromiter((int(bit) for bit in text), dtype=np.uint8))
    if not frames:
        raise SystemExit(f"No expected frames in: {path}")
    return frames


def parse_actual(path: Path) -> list[tuple[np.ndarray, np.ndarray]]:
    frames = []
    for frame_number, text in enumerate(nonempty_lines(path), start=1):
        if len(text) != N:
            raise SystemExit(
                f"Invalid RTL frame {frame_number}: got {len(text)} bits, expected {N}"
            )
        raw_unknown = np.fromiter(
            (bit not in {"0", "1"} for bit in text), dtype=bool
        )
        raw_bits = np.fromiter(
            (int(bit) if bit in {"0", "1"} else 0 for bit in text),
            dtype=np.uint8,
        )
        codeword = verilog_decoder.raw_frame_to_codeword(raw_bits, L, K)
        unknown = verilog_decoder.raw_frame_to_codeword(raw_unknown.astype(int), L, K).astype(bool)
        frames.append((codeword, unknown))
    if not frames:
        raise SystemExit(f"No RTL frames in: {path}")
    return frames


def main() -> None:
    args = parse_args()
    expected_frames = parse_expected(args.expected.resolve())
    actual_frames = parse_actual(args.actual.resolve())

    compared_frames = min(len(expected_frames), len(actual_frames))
    bit_errors = 0
    unknown_bits = 0
    shown = 0
    per_frame = []

    for frame_index in range(compared_frames):
        expected = expected_frames[frame_index]
        actual, unknown = actual_frames[frame_index]
        mismatch = (actual != expected) | unknown
        mismatch_positions = np.flatnonzero(mismatch)
        frame_errors = int(mismatch_positions.size)
        frame_unknown = int(np.count_nonzero(unknown))
        bit_errors += frame_errors
        unknown_bits += frame_unknown
        per_frame.append(
            {
                "frame": frame_index + 1,
                "bit_errors": frame_errors,
                "unknown_bits": frame_unknown,
            }
        )

        for bit_index in mismatch_positions:
            if shown >= args.show:
                break
            actual_text = "X/Z" if unknown[bit_index] else str(int(actual[bit_index]))
            print(
                f"Mismatch frame={frame_index + 1}, codeword_bit={int(bit_index)}: "
                f"expected={int(expected[bit_index])}, actual={actual_text}"
            )
            shown += 1

    missing_frames = max(0, len(expected_frames) - len(actual_frames))
    extra_frames = max(0, len(actual_frames) - len(expected_frames))
    bit_errors += missing_frames * N + extra_frames * N
    total_reference_bits = len(expected_frames) * N
    ber = bit_errors / total_reference_bits if total_reference_bits else 1.0
    passed = bit_errors == 0 and len(expected_frames) == len(actual_frames)

    report = {
        "passed": passed,
        "expected_frames": len(expected_frames),
        "actual_frames": len(actual_frames),
        "compared_frames": compared_frames,
        "missing_frames": missing_frames,
        "extra_frames": extra_frames,
        "reference_bits": total_reference_bits,
        "bit_errors": bit_errors,
        "unknown_bits": unknown_bits,
        "bit_error_rate": ber,
        "frames": per_frame,
    }
    artifacts_dir = Path(__file__).resolve().parent / "artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    report_path = artifacts_dir / "compare_report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"Expected frames: {len(expected_frames)}")
    print(f"RTL frames: {len(actual_frames)}")
    print(f"Reference bits: {total_reference_bits}")
    print(f"Bit errors: {bit_errors}")
    print(f"Unknown X/Z bits: {unknown_bits}")
    print(f"BER: {ber:.12g}")
    print(f"Result: {'PASS' if passed else 'FAIL'}")
    print(f"Report: {report_path}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
