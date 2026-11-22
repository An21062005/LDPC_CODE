"""Run the already-programmed LDPC AXI core from the PYNQ Linux console.

This script does not load a bitstream. It only accesses the verified AXI-Lite
register window at 0x43C00000 and writes its result inside the isolated board
work directory.
"""

from itertools import islice
from pathlib import Path
from time import monotonic, sleep

from pynq import MMIO


BASE_ADDRESS = 0x43C00000
ADDRESS_RANGE = 0x10000

CONTROL = 0x00
STATUS = 0x04
INPUT_ADDR = 0x08
INPUT_DATA = 0x0C
OUTPUT_ADDR = 0x10
OUTPUT_LO = 0x14
OUTPUT_HI = 0x18

DATA_COUNT = 1152
OUTPUT_BLOCKS = 32
BITS_PER_BLOCK = 36

WORK_DIR = Path("/home/xilinx/pynq_z2_shared_work")
INPUT_PATH = WORK_DIR / "input.txt"
OUTPUT_PATH = WORK_DIR / "output_first_valid.txt"


def samples_from_file(path):
    with path.open("r", encoding="ascii") as handle:
        for line in handle:
            for token in line.split():
                yield int(token, 2)


def take_frame(samples):
    frame = list(islice(samples, DATA_COUNT))
    if len(frame) != DATA_COUNT:
        raise RuntimeError(f"input ended after {len(frame)} samples")
    return frame


def load_frame(mmio, samples):
    mmio.write(INPUT_ADDR, 0)
    for sample in samples:
        mmio.write(INPUT_DATA, sample & 0x1F)


def run_frame(mmio, samples, timeout=2.0):
    load_frame(mmio, samples)
    if mmio.read(STATUS) & 0x1:
        raise RuntimeError("decoder was busy before start")
    mmio.write(CONTROL, 1)

    deadline = monotonic() + timeout
    while monotonic() < deadline:
        status = mmio.read(STATUS)
        if status & 0x10:
            raise RuntimeError("hardware frame sequencer timeout")
        if status & 0x2:
            return status
        sleep(0.0001)
    raise RuntimeError("software timeout waiting for decoder")


def read_bits(mmio):
    bits = []
    for block in range(OUTPUT_BLOCKS):
        mmio.write(OUTPUT_ADDR, block)
        value = mmio.read(OUTPUT_LO)
        value |= (mmio.read(OUTPUT_HI) & 0xF) << 32
        bits.extend((value >> bit) & 1 for bit in range(BITS_PER_BLOCK))
    return bits


def main():
    if not INPUT_PATH.is_file():
        raise FileNotFoundError(INPUT_PATH)
    if OUTPUT_PATH.exists():
        raise FileExistsError(f"refusing to overwrite {OUTPUT_PATH}")

    mmio = MMIO(BASE_ADDRESS, ADDRESS_RANGE)
    samples = samples_from_file(INPUT_PATH)
    final_status = 0
    for frame_number in range(1, 4):
        final_status = run_frame(mmio, take_frame(samples))
        print(f"FRAME {frame_number} STATUS=0x{final_status:08x}", flush=True)

    if not (final_status & 0x4):
        raise RuntimeError("third frame was not marked output-valid")

    bits = read_bits(mmio)
    output_line = "".join(str(bit) for bit in bits) + "\n"
    OUTPUT_PATH.write_text(output_line, encoding="ascii")
    print(f"OUTPUT={OUTPUT_PATH}", flush=True)
    print(f"OUTPUT_BITS={len(bits)}", flush=True)
    print("LIVE_LDPC_TEST_PASS", flush=True)


if __name__ == "__main__":
    main()
