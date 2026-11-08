"""Create RTL input and clean reference codewords from code/data/eye.png.

Same data path as the original generate_input.py / verilog_decoder.py:
grayscale image -> gray2bin -> pyldpc generator from H -> BPSK + AWGN
(pyldpc.encode, numpy RandomState(seed)) -> LLR = 2y/sigma^2 -> 5-bit sample
(clip to +-3.75, step 0.25, two's complement). Two all-zero flush frames are
appended because the decoder interface has a two-transaction latency.

Usage (from ldpc_da2_configurable):
  python script/gen_data.py --snr 20 --seed 42 --out outfeed/data/snr20
  python script/gen_data.py --verify-reference   # must reproduce code/data
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ldpc_common import ROOT, load_h  # noqa: E402

FLUSH_FRAMES = 2


def round_to(num, target):
    return round(num / target) * target


def calc_bits_from_float(num):
    """verilog_decoder.calc_bits_from_float, unchanged behaviour."""
    num = min(max(num, -3.75), 3.75)
    rounded = round_to(num, 0.25)
    int_val = int(np.floor(rounded))
    frac = round(100 * (rounded - int_val))
    frac_str = {0: "00", 25: "01", 50: "10", 75: "11"}[frac]
    return "{0:02b}".format(int_val) + frac_str


def twos_complement(text):
    """verilog_decoder.findTwoscomplement, unchanged behaviour."""
    i = len(text) - 1
    while i >= 0 and text[i] != "1":
        i -= 1
    out = list(text)
    for k in range(i - 1, -1, -1):
        out[k] = "1" if out[k] == "0" else "0"
    return "".join(out)


def llr_to_binary_str(llr):
    magnitude = calc_bits_from_float(abs(llr))
    return twos_complement("0" + magnitude) if llr < 0 else "0" + magnitude


def frame_line(samples, snr):
    sigma = 10 ** (-snr / 20)
    return "".join(llr_to_binary_str((2 * y) / (sigma * sigma)) + " " for y in samples)


def generate(snr, seed, image_path):
    from PIL import Image
    from pyldpc import coding_matrix, encode
    from pyldpc.utils import binaryproduct
    from pyldpc.utils_img import gray2bin

    h = load_h().astype(np.int64)
    generator = coding_matrix(h, sparse=True)
    image = np.asarray(Image.open(image_path).convert("LA"))[:, :, 0]
    bits = gray2bin(image).flatten().astype(int)
    n, k = generator.shape
    frames = (bits.size + k - 1) // k
    padded = np.zeros(k * frames, dtype=int)
    padded[: bits.size] = bits
    messages = padded.reshape(k, frames)
    clean = (np.asarray(binaryproduct(generator, messages), dtype=int) % 2).reshape(n, frames)
    noisy = np.asarray(encode(generator, messages, snr, seed=seed), dtype=float).reshape(n, frames)
    lines = [frame_line(noisy[:, f], snr) for f in range(frames)]
    lines += [frame_line(np.zeros(n), snr) for _ in range(FLUSH_FRAMES)]
    input_text = "\n".join(lines)            # same layout as the original file
    expected_text = "\n".join("".join(map(str, clean[:, f])) for f in range(frames)) + "\n"
    meta = dict(image=str(Path(image_path).relative_to(ROOT).as_posix()), image_shape=list(image.shape),
                image_bits=int(bits.size), n=int(n), k=int(k), payload_frames=int(frames),
                flush_frames=FLUSH_FRAMES, snr_db=snr, seed=seed)
    return input_text, expected_text, meta


def sha(text):
    return hashlib.sha256(text.encode("ascii")).hexdigest()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--snr", type=float, default=20.0)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--image", type=Path, default=ROOT / "code/data/eye.png")
    p.add_argument("--out", type=Path, help="output directory (inside outfeed/)")
    p.add_argument("--verify-reference", action="store_true",
                   help="regenerate SNR 20 dB / seed 42 and compare with code/data")
    a = p.parse_args(argv)
    if a.verify_reference:
        inp, exp, _ = generate(20.0, 42, ROOT / "code/data/eye.png")
        ok_in = inp == (ROOT / "code/data/input.txt").read_text(encoding="ascii")
        ok_ex = exp == (ROOT / "code/data/expected_codeword.txt").read_text(encoding="ascii")
        print(f"REFERENCE_INPUT_MATCH={ok_in} REFERENCE_EXPECTED_MATCH={ok_ex}")
        return 0 if ok_in and ok_ex else 1
    if a.out is None:
        p.error("--out is required")
    out = a.out.resolve()
    if not out.is_relative_to(ROOT / "outfeed"):
        p.error("generated data must be written below outfeed/")
    out.mkdir(parents=True, exist_ok=True)
    inp, exp, meta = generate(a.snr, a.seed, a.image.resolve())
    (out / "input.txt").write_text(inp, encoding="ascii")
    (out / "expected_codeword.txt").write_text(exp, encoding="ascii")
    meta.update(input_sha256=sha(inp), expected_sha256=sha(exp))
    (out / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
