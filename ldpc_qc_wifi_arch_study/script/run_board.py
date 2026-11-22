"""Read COD1 codewords (802.11n, N=648) from an already configured PYNQ-Z2 over AXI4-Lite.

Copy of ldpc_da2/script/run_board.py; only N (648) and the chunk count (18)
change. Register map and transaction sequence are the same.

This script does not load an overlay or program hardware. A fresh configuration
is required because the preserved core has a two-transaction pipeline delay.
"""
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
from time import monotonic, perf_counter, sleep

N = 648
CHUNKS = N // 36
BASE_ADDRESS = 0x43C00000
COD1 = 0x434F4431


def read_inputs(path):
    frames = []
    for number, line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        if not line.strip():
            continue
        tokens = line.split()
        if len(tokens) != N or any(len(t) != 5 or set(t)-{"0", "1"} for t in tokens):
            raise ValueError(f"input line {number}: require 648 five-bit samples")
        frames.append([int(t, 2) for t in tokens])
    if not 3 <= len(frames) <= 65535:
        raise ValueError("require payload + two trailing flush frames; at most 65535 transactions")
    return frames


def read_codeword(mmio):
    # RTL already supplies reference order. Bit zero of the first AXI chunk
    # is the first character of the output line. No transpose/permutation.
    bits = []
    for chunk in range(CHUNKS):
        mmio.write(0x10, chunk)
        word = mmio.read(0x14) | ((mmio.read(0x18) & 15) << 32)
        bits.extend(str((word >> bit) & 1) for bit in range(36))
    return "".join(bits)


def run_frames(mmio, frames):
    if mmio.read(0x20) != COD1:
        raise RuntimeError("COD1 output format required; the old raw bitstream is incompatible")
    initial = mmio.read(0x04)
    if initial & 1 or initial >> 16:
        raise RuntimeError("require a fresh FPGA configuration with completed_frames=0")
    outputs, rows = [], []
    begin = perf_counter()
    for transaction, samples in enumerate(frames, 1):
        t0 = perf_counter()
        mmio.write(0x08, 0)
        for sample in samples:
            mmio.write(0x0c, sample)
        t1 = perf_counter()
        if mmio.read(0x04) & 1:
            raise RuntimeError("decoder busy before start")
        mmio.write(0x00, 1)
        deadline = monotonic() + 2.0
        while True:
            status = mmio.read(0x04)
            if status & 16:
                raise TimeoutError(f"hardware timeout on transaction {transaction}")
            if status & 2:
                break
            if monotonic() >= deadline:
                raise TimeoutError(f"software timeout on transaction {transaction}")
            sleep(0.0001)
        t2 = perf_counter()
        if status & 1 or status >> 16 != transaction or bool(status & 4) != (transaction >= 3):
            raise RuntimeError(f"invalid status 0x{status:08x} on transaction {transaction}")
        if status & 4:
            outputs.append(read_codeword(mmio))
        t3 = perf_counter()
        rows.append(dict(transaction=transaction, output_frame=max(0, transaction-2),
                         load_ms=(t1-t0)*1000, host_wait_ms=(t2-t1)*1000,
                         read_ms=(t3-t2)*1000, transaction_ms=(t3-t0)*1000))
    return outputs, rows, perf_counter()-begin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("code/data/input.txt"))
    parser.add_argument("--expected", type=Path, default=Path("code/data/expected_codeword.txt"))
    args = parser.parse_args()
    frames = read_inputs(args.input)
    expected = [s.strip() for s in args.expected.read_text(encoding="ascii").splitlines() if s.strip()]
    if len(expected) != len(frames)-2 or any(len(w) != N or set(w)-{"0", "1"} for w in expected):
        raise ValueError("expected must contain one 648-bit codeword per payload frame")
    root = Path.cwd().resolve(strict=True)
    allowed = Path("/home/xilinx/pynq_z2_shared_work").resolve(strict=True)
    if not root.is_relative_to(allowed) or any(part.lower() == "loc" for part in root.parts):
        raise ValueError("run inside /home/xilinx/pynq_z2_shared_work/ldpc_da2, outside Loc")
    print("BOARD_PARENT_ENTRIES=" + ", ".join(p.name for p in root.parent.iterdir()))
    print("BOARD_DESTINATION_ENTRIES=" + ", ".join(p.name for p in root.iterdir()))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    output_root = (root / "outfeed").resolve()
    if output_root != root / "outfeed":
        raise ValueError("outfeed must be a local directory inside the project")
    destination = output_root / ("board_result_" + stamp)
    print("EXACT_NEW_RESULT_DIRECTORY=" + str(destination), flush=True)
    from pynq import MMIO
    outputs, rows, elapsed = run_frames(MMIO(BASE_ADDRESS, 0x10000), frames)
    errors = [sum(a != b for a, b in zip(word, ref)) for word, ref in zip(outputs, expected)]
    if len(outputs) != len(expected):
        raise RuntimeError("missing output frames")
    summary = dict(output_format="COD1", input_frames=len(frames), output_frames=len(outputs),
                   compared_bits=len(outputs)*N, bit_errors=sum(errors), bad_frames=sum(e > 0 for e in errors),
                   ber=sum(errors)/(len(outputs)*N), host_seconds=elapsed,
                   host_codeword_mbps=len(outputs)*N/elapsed/1e6,
                   measurement_scope="host AXI load/start/poll/read, including two warmup/flush transactions; not pure FPGA latency",
                   result="PASS" if not sum(errors) else "FAIL")
    destination.mkdir(parents=True, exist_ok=False)
    (destination/"output_codeword.txt").write_text("\n".join(outputs)+"\n", encoding="ascii")
    (destination/"summary.json").write_text(json.dumps(summary, indent=2)+"\n", encoding="utf-8")
    with (destination/"transactions.csv").open("x", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(json.dumps(summary, indent=2))
    print("RESULT_DIRECTORY=" + str(destination))
    return 0 if not sum(errors) else 1


if __name__ == "__main__":
    raise SystemExit(main())
