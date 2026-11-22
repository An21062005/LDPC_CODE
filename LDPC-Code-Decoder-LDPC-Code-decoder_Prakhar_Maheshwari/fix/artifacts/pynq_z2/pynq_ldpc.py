"""PYNQ userspace driver for LDPC_Decoder_PYNQ_Z2_top.

Copy the generated .bit and .hwh files plus this script to the PYNQ-Z2.
This is an AXI4-Lite control/data interface; AXI is inside the Zynq chip.
"""

from pathlib import Path
from time import monotonic, sleep

from pynq import MMIO, Overlay


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


class LDPCDecoder:
    def __init__(self, bitfile, ip_name="decoder_axi"):
        self.overlay = Overlay(str(bitfile))
        info = self.overlay.ip_dict[ip_name]
        self.mmio = MMIO(info["phys_addr"], info["addr_range"])

    def load_frame(self, samples):
        if len(samples) != DATA_COUNT:
            raise ValueError(f"expected {DATA_COUNT} samples, got {len(samples)}")
        self.mmio.write(INPUT_ADDR, 0)
        for sample in samples:
            self.mmio.write(INPUT_DATA, int(sample) & 0x1F)

    def start(self):
        if self.mmio.read(STATUS) & 0x1:
            raise RuntimeError("decoder is already busy")
        self.mmio.write(CONTROL, 1)

    def wait(self, timeout=2.0):
        deadline = monotonic() + timeout
        while monotonic() < deadline:
            status = self.mmio.read(STATUS)
            if status & 0x10:
                raise TimeoutError("hardware frame sequencer timed out")
            if status & 0x2:
                return status
            sleep(0.0001)
        raise TimeoutError("decoder did not complete before software timeout")

    def read_bits(self):
        bits = []
        for block in range(OUTPUT_BLOCKS):
            self.mmio.write(OUTPUT_ADDR, block)
            value = self.mmio.read(OUTPUT_LO)
            value |= (self.mmio.read(OUTPUT_HI) & 0xF) << 32
            bits.extend((value >> bit) & 1 for bit in range(BITS_PER_BLOCK))
        return bits

    def decode(self, samples, timeout=2.0):
        self.load_frame(samples)
        self.start()
        status = self.wait(timeout)
        return self.read_bits(), status


def read_input_frames(path):
    values = [int(token, 2) for token in Path(path).read_text().split()]
    if len(values) % DATA_COUNT:
        raise ValueError("input sample count is not a multiple of 1152")
    return [values[i:i + DATA_COUNT] for i in range(0, len(values), DATA_COUNT)]


def run_file(bitfile, input_path, output_path):
    decoder = LDPCDecoder(bitfile)
    output_lines = []
    for frame_number, frame in enumerate(read_input_frames(input_path), start=1):
        bits, status = decoder.decode(frame)
        # Match Decoder_tb.v: frames one and two warm up the pipeline.
        if status & 0x4:
            output_lines.append("".join(str(bit) for bit in bits))
        print(f"frame {frame_number}: status=0x{status:08x}")
    Path(output_path).write_text("\n".join(output_lines) + "\n")

