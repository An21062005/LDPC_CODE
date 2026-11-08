"""Create RTL input and clean reference codewords for the 802.11n code.

Same data path as ldpc_da2 (generate_input.py / verilog_decoder.py), only the
encoder changes: the image bits are encoded with THIS Wi-Fi H.
  grayscale eye.png -> gray2bin -> blocks of k = 324 bits
  -> systematic 802.11n codeword c = [s, p], p = Hp^-1 Hs s (GF(2))
  -> BPSK x = (-1)^c, y = x + sigma*randn (numpy RandomState(seed), as pyldpc)
  -> LLR = 2y/sigma^2 -> 5-bit sample (clip +-3.75, step 0.25, two's complement)
Two all-zero flush frames are appended (two-transaction interface latency).
Every clean codeword is checked against H before it is written.

  python script/gen_data.py --snr 20 --seed 42 --out outfeed/data/reference
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ldpc_common import CODES, DEFAULT_CODE, ROOT, gf2_inverse, load_h  # noqa: E402

FLUSH_FRAMES = 2


def calc_bits_from_float(num):
    """verilog_decoder.calc_bits_from_float, unchanged behaviour."""
    num = min(max(num, -3.75), 3.75)
    rounded = round(num / 0.25) * 0.25
    int_val = int(np.floor(rounded))
    frac = round(100 * (rounded - int_val))
    return "{0:02b}".format(int_val) + {0: "00", 25: "01", 50: "10", 75: "11"}[frac]


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


def generate(snr, seed, image_path, code=DEFAULT_CODE):
    from PIL import Image
    from pyldpc.utils_img import gray2bin

    h = load_h(code).astype(np.uint8)
    m, n = h.shape
    k = n - m
    hs, hp = h[:, :k], h[:, k:]
    encoder = (gf2_inverse(hp).astype(np.int64) @ hs.astype(np.int64)) % 2      # p = A s
    image = np.asarray(Image.open(image_path).convert("LA"))[:, :, 0]
    bits = gray2bin(image).flatten().astype(int)
    frames = (bits.size + k - 1) // k
    padded = np.zeros(k * frames, dtype=np.int64)
    padded[: bits.size] = bits
    messages = padded.reshape(k, frames)                 # same block layout as ldpc_da2
    parity = (encoder @ messages) % 2
    clean = np.vstack([messages, parity]).astype(np.int64)
    if ((h.astype(np.int64) @ clean) % 2).any():
        raise AssertionError("encoder produced a word that is not a codeword of H")
    rng = np.random.RandomState(seed)
    sigma = 10 ** (-snr / 20)
    noisy = (-1.0) ** clean + rng.randn(*clean.shape) * sigma
    lines = [frame_line(noisy[:, f], snr) for f in range(frames)]
    lines += [frame_line(np.zeros(n), snr) for _ in range(FLUSH_FRAMES)]
    input_text = "\n".join(lines)
    expected_text = "\n".join("".join(map(str, clean[:, f])) for f in range(frames)) + "\n"
    meta = dict(code=code, z=CODES[code]["z"], image=Path(image_path).relative_to(ROOT).as_posix(),
                image_shape=list(image.shape), image_bits=int(bits.size), n=int(n), k=int(k),
                payload_frames=int(frames), flush_frames=FLUSH_FRAMES, snr_db=snr, seed=seed,
                encoder="systematic 802.11n: c = [s, Hp^-1 Hs s]")
    return input_text, expected_text, meta


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--snr", type=float, default=20.0)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--code", default=DEFAULT_CODE, choices=sorted(CODES))
    p.add_argument("--image", type=Path, default=ROOT / "code/data/eye.png")
    p.add_argument("--out", type=Path, required=True, help="output directory below outfeed/")
    a = p.parse_args(argv)
    out = a.out.resolve()
    if not out.is_relative_to(ROOT / "outfeed"):
        p.error("generated data must be written below outfeed/")
    out.mkdir(parents=True, exist_ok=True)
    inp, exp, meta = generate(a.snr, a.seed, a.image.resolve(), a.code)
    (out / "input.txt").write_text(inp, encoding="ascii")
    (out / "expected_codeword.txt").write_text(exp, encoding="ascii")
    meta.update(input_sha256=hashlib.sha256(inp.encode()).hexdigest(),
                expected_sha256=hashlib.sha256(exp.encode()).hexdigest())
    (out / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
