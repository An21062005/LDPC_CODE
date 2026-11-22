"""Run every LDPC input frame and save every valid hardware output.

The programmed core has a two-frame warm-up, so 698 input frames produce
696 output lines. This script never overwrites an existing result file.
"""

from pathlib import Path

from pynq import MMIO

from run_ldpc_uart import (
    ADDRESS_RANGE,
    BASE_ADDRESS,
    DATA_COUNT,
    INPUT_PATH,
    STATUS,
    WORK_DIR,
    read_bits,
    run_frame,
)


OUTPUT_PATH = WORK_DIR / "output_fixed_full.txt"
EXPECTED_INPUT_FRAMES = 698
EXPECTED_OUTPUT_FRAMES = 696


def frames_from_file(path: Path):
    with path.open("r", encoding="ascii") as handle:
        for line_number, line in enumerate(handle, 1):
            tokens = line.split()
            if len(tokens) != DATA_COUNT:
                raise RuntimeError(
                    f"input line {line_number} has {len(tokens)} samples; "
                    f"expected {DATA_COUNT}"
                )
            yield [int(token, 2) for token in tokens]


def main():
    if not INPUT_PATH.is_file():
        raise FileNotFoundError(INPUT_PATH)
    if OUTPUT_PATH.exists():
        raise FileExistsError(f"refusing to overwrite {OUTPUT_PATH}")

    mmio = MMIO(BASE_ADDRESS, ADDRESS_RANGE)
    initial_status = mmio.read(STATUS)
    initial_completed = initial_status >> 16
    if initial_status & 0x1:
        raise RuntimeError("decoder is busy before full run")
    if initial_completed != 0:
        raise RuntimeError(
            f"decoder already completed {initial_completed} frame(s); "
            "reprogram the fixed bitstream before running the full dataset"
        )

    input_frames = 0
    output_frames = 0
    with OUTPUT_PATH.open("x", encoding="ascii", newline="\n") as output_handle:
        for input_frames, samples in enumerate(frames_from_file(INPUT_PATH), 1):
            status = run_frame(mmio, samples)
            output_valid = bool(status & 0x4)

            if input_frames < 3 and output_valid:
                raise RuntimeError(f"unexpected output-valid on frame {input_frames}")
            if input_frames >= 3 and not output_valid:
                raise RuntimeError(f"missing output-valid on frame {input_frames}")

            if output_valid:
                bits = read_bits(mmio)
                output_handle.write("".join(str(bit) for bit in bits) + "\n")
                output_frames += 1

            if input_frames % 25 == 0:
                print(
                    f"PROGRESS input={input_frames} output={output_frames} "
                    f"status=0x{status:08x}",
                    flush=True,
                )

    if input_frames != EXPECTED_INPUT_FRAMES:
        raise RuntimeError(
            f"processed {input_frames} input frames; expected {EXPECTED_INPUT_FRAMES}"
        )
    if output_frames != EXPECTED_OUTPUT_FRAMES:
        raise RuntimeError(
            f"captured {output_frames} outputs; expected {EXPECTED_OUTPUT_FRAMES}"
        )

    print(f"INPUT_FRAMES={input_frames}")
    print(f"OUTPUT_FRAMES={output_frames}")
    print(f"OUTPUT={OUTPUT_PATH}")
    print("FULL_LDPC_TEST_PASS")


if __name__ == "__main__":
    main()
