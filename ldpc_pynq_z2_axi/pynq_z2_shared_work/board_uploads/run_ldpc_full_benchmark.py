"""Benchmark the codeword-ordered LDPC bitstream using Python/AXI only.

Requires OUTPUT_FORMAT=COD1 from the updated RTL. Does not program the FPGA.
File parsing, saving and direct comparison happen outside the measured interval.
"""

import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics
from time import perf_counter, sleep

BASE_ADDRESS, ADDRESS_RANGE = 0x43C00000, 0x10000
CONTROL, STATUS, INPUT_ADDR, INPUT_DATA = 0x00, 0x04, 0x08, 0x0C
OUTPUT_ADDR, OUTPUT_LO, OUTPUT_HI = 0x10, 0x14, 0x18
OUTPUT_FORMAT, CODEWORD_ORDER_MAGIC = 0x20, 0x434F4431
DATA_COUNT = 1152
WORK_DIR = Path('/home/xilinx/pynq_z2_shared_work')


def require_codeword_format(mmio):
    if mmio.read(OUTPUT_FORMAT) != CODEWORD_ORDER_MAGIC:
        raise RuntimeError('Require the new COD1 bitstream: rebuild fixed_hw_project_v2 and program FPGA before running')


def read_inputs(path):
    frames = []
    with path.open(encoding='ascii') as handle:
        for number, line in enumerate(handle, 1):
            tokens = line.split()
            if len(tokens) != DATA_COUNT or any(len(t) != 5 or set(t)-{'0', '1'} for t in tokens):
                raise ValueError(f'Input line {number}: require 1152 five-bit samples')
            frames.append([int(t, 2) for t in tokens])
    if len(frames) != 698:
        raise ValueError(f'Require the existing 698-frame input; found {len(frames)}')
    return frames


def measure(mmio, frames, clock=perf_counter, sleeper=sleep):
    """Preserve the existing load/start/poll/read protocol and two-frame delay."""
    rows, outputs = [], []
    begin = clock()
    for transaction, samples in enumerate(frames, 1):
        t0 = clock()
        mmio.write(INPUT_ADDR, 0)
        for sample in samples:
            mmio.write(INPUT_DATA, sample)
        t1 = clock()
        if mmio.read(STATUS) & 1:
            raise RuntimeError('Decoder busy before START')
        mmio.write(CONTROL, 1)
        deadline = clock() + 2.0
        while True:
            status = mmio.read(STATUS)
            if status & 0x10:
                raise RuntimeError(f'Hardware timeout at transaction {transaction}')
            if status & 2:
                break
            if clock() >= deadline:
                raise TimeoutError(f'Software timeout at transaction {transaction}')
            sleeper(0.0001)
        t2 = clock()
        if status & 1 or status >> 16 != transaction:
            raise RuntimeError('Unexpected status/frame sequence; require fresh FPGA configuration')
        valid = bool(status & 4)
        if valid != (transaction >= 3):
            raise RuntimeError(f'Incorrect output-valid at transaction {transaction}')
        if valid:
            bits = []
            for block in range(32):
                mmio.write(OUTPUT_ADDR, block)
                value = mmio.read(OUTPUT_LO) | ((mmio.read(OUTPUT_HI) & 0xF) << 32)
                bits.extend(str((value >> bit) & 1) for bit in range(36))
            outputs.append(''.join(bits))
        t3 = clock()
        rows.append(dict(transaction=transaction, output_frame=transaction-2 if valid else 0,
                         load_ms=(t1-t0)*1000, start_to_done_observed_ms=(t2-t1)*1000,
                         output_read_ms=(t3-t2)*1000, transaction_ms=(t3-t0)*1000))
    return rows, outputs, clock()-begin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected', type=Path, help='Optional clean codeword reference, 696 lines')
    args = parser.parse_args()
    # Inspect the exact board destination before writing any result.
    root = WORK_DIR.resolve(strict=True)
    if root != WORK_DIR or not root.is_dir() or any(p.lower() == 'loc' for p in root.parts):
        raise ValueError(f'Unsafe result destination: {root}')
    print('BOARD_WRITE_ROOT=' + str(root))
    print('PARENT_ENTRIES=' + ', '.join(sorted(p.name for p in root.parent.iterdir())))
    print('DESTINATION_ENTRIES=' + ', '.join(sorted(p.name for p in root.iterdir())))
    frames = read_inputs(root/'input.txt')
    expected = None
    if args.expected:
        expected = [''.join(line.split()) for line in args.expected.read_text(encoding='ascii').splitlines()]
        if len(expected) != 696 or any(len(w) != DATA_COUNT or set(w)-{'0', '1'} for w in expected):
            raise ValueError('Require 696 clean reference codewords, 1152 bits per line')
    from pynq import MMIO
    mmio = MMIO(BASE_ADDRESS, ADDRESS_RANGE)
    require_codeword_format(mmio)
    initial = mmio.read(STATUS)
    if initial & 1 or initial >> 16:
        raise RuntimeError('Reprogram your existing fixed bitstream before this benchmark')
    print('Measuring 698 transactions; results will print after completion.', flush=True)
    rows, outputs, elapsed = measure(mmio, frames)
    if len(outputs) != 696:
        raise RuntimeError(f'Require 696 output frames; received {len(outputs)}')
    result = dict(input_frames=len(frames), output_frames=len(outputs), codeword_bits=len(outputs)*DATA_COUNT,
                  total_seconds=elapsed, frames_per_second=len(outputs)/elapsed,
                  codeword_mbps=len(outputs)*DATA_COUNT/elapsed/1e6,
                  mean_load_ms=statistics.mean(r['load_ms'] for r in rows),
                  mean_start_to_done_observed_ms=statistics.mean(r['start_to_done_observed_ms'] for r in rows),
                  mean_output_read_ms=statistics.mean(r['output_read_ms'] for r in rows if r['output_frame']),
                  mean_transaction_ms=statistics.mean(r['transaction_ms'] for r in rows),
                  scope='Python/AXI end-to-end including 2 warm-up/flush transactions; excludes file I/O and reference comparison',
                  start_to_done_scope='Host-observed wait including MMIO/status polling and 100 us sleep; not pure FPGA latency',
                  throughput_scope='1152 codeword bits/frame; not information-bit throughput',
                  output_order='codeword', output_format='COD1',
                  bit_errors=None, bad_frames=None, ber=None)
    if expected is not None:
        errors = []
        for word, ref in zip(outputs, expected):
            errors.append(sum(a != b for a, b in zip(word, ref)))
        result.update(bit_errors=sum(errors), bad_frames=sum(e > 0 for e in errors),
                      ber=sum(errors)/result['codeword_bits'])
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    dest = root/('python_benchmark_'+stamp)
    print('EXACT_NEW_RESULT_DIRECTORY=' + str(dest), flush=True)
    if dest.parent != root or any(p.lower() == 'loc' for p in dest.parts):
        raise ValueError('Unsafe result directory')
    dest.mkdir(exist_ok=False)
    with (dest/'summary.json').open('x', encoding='utf-8') as handle:
        json.dump(result, handle, indent=2)
        handle.write('\n')
    with (dest/'transactions.csv').open('x', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (dest/'output_codeword.txt').open('x', encoding='ascii') as handle:
        handle.write('\n'.join(outputs)+'\n')
    print(f'TOTAL_SECONDS={elapsed:.6f}')
    print(f'THROUGHPUT_CODEWORD_MBPS={result["codeword_mbps"]:.6f}')
    print(f'FRAMES_PER_SECOND={result["frames_per_second"]:.3f}')
    print(f'MEAN_START_TO_DONE_OBSERVED_MS={result["mean_start_to_done_observed_ms"]:.6f}')
    print(f'OUTPUT_FRAMES={len(outputs)}')
    if expected is not None:
        print(f'BIT_ERRORS={result["bit_errors"]} BAD_FRAMES={result["bad_frames"]} BER={result["ber"]}')
    print('RESULT_DIRECTORY=' + str(dest))
    return 1 if result['bit_errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
