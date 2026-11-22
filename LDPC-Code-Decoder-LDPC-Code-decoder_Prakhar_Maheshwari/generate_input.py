"""Generate input.txt and expected_codeword.txt from data/eye.png.

This follows the author's example.py data path:

    grayscale image -> gray2bin -> LDPC encode -> AWGN channel

The noisy channel samples are converted to the RTL's 5-bit LLR format using
verilog_decoder.write_frame_to_file.  The clean encoded bits, before AWGN, are
saved separately as the reference codewords.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from pyldpc import coding_matrix, encode
from pyldpc.utils import binaryproduct
from pyldpc.utils_img import gray2bin

import verilog_decoder


K = 6
FLUSH_FRAMES = 2


def parse_args() -> argparse.Namespace:
    project_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Create noisy RTL input and clean LDPC reference codewords."
    )
    parser.add_argument(
        "--image",
        type=Path,
        default=project_dir / "data" / "eye.png",
        help="source image (default: data/eye.png)",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=project_dir / "input.txt",
        help="RTL input file (default: input.txt)",
    )
    parser.add_argument(
        "--expected",
        type=Path,
        default=project_dir / "expected_codeword.txt",
        help="clean codeword reference file",
    )
    parser.add_argument(
        "--snr",
        type=float,
        default=20.0,
        help="channel SNR in dB, matching example.py (default: 20)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="AWGN random seed, matching example.py (default: 42)",
    )
    parser.add_argument(
        "--resize",
        nargs=2,
        type=int,
        metavar=("WIDTH", "HEIGHT"),
        help="optional resize before encoding, for example: --resize 8 8",
    )
    return parser.parse_args()


def ensure_h_matrix(project_dir: Path) -> Path:
    h_path = project_dir / "permutations" / "H_np_array.npy"
    if h_path.is_file():
        return h_path

    generator_script = project_dir / "permutations" / "Gen_Permutations.py"
    print("H_np_array.npy is missing; generating H and matching PI modules...")
    subprocess.run([sys.executable, str(generator_script)], check=True)
    if not h_path.is_file():
        raise SystemExit(f"Generator did not create: {h_path}")
    return h_path


def write_clean_codewords(path: Path, codewords: np.ndarray) -> None:
    lines = [
        "".join(codewords[:, frame].astype(str).tolist())
        for frame in range(codewords.shape[1])
    ]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> None:
    args = parse_args()
    project_dir = Path(__file__).resolve().parent
    os.chdir(project_dir)

    image_path = args.image.resolve()
    input_path = args.input.resolve()
    expected_path = args.expected.resolve()
    if not image_path.is_file():
        raise SystemExit(f"Image not found: {image_path}")

    ensure_h_matrix(project_dir)
    h_matrix = verilog_decoder.get_H()
    generator = coding_matrix(h_matrix, sparse=True)

    image = Image.open(image_path).convert("LA")
    if args.resize:
        width, height = args.resize
        if width < 1 or height < 1:
            raise SystemExit("--resize WIDTH HEIGHT must use positive dimensions")
        image = image.resize((width, height), Image.Resampling.LANCZOS)
    image_array = np.asarray(image)[:, :, 0]
    image_bits = gray2bin(image_array).flatten().astype(int)

    n, message_length = generator.shape
    if n != h_matrix.shape[1]:
        raise SystemExit(f"Generator length {n} does not match H length {h_matrix.shape[1]}")

    payload_frames = (image_bits.size + message_length - 1) // message_length
    padded_bits = np.zeros(message_length * payload_frames, dtype=int)
    padded_bits[: image_bits.size] = image_bits
    message_blocks = padded_bits.reshape(message_length, payload_frames)

    # Clean encoded bits before the channel: this is the decoder reference.
    clean_codewords = np.asarray(binaryproduct(generator, message_blocks), dtype=int) % 2
    clean_codewords = clean_codewords.reshape(n, payload_frames)

    # pyldpc.encode performs the same BPSK + AWGN channel used by example.py.
    noisy_samples = np.asarray(
        encode(generator, message_blocks, args.snr, seed=args.seed), dtype=float
    ).reshape(n, payload_frames)

    input_path.parent.mkdir(parents=True, exist_ok=True)
    expected_path.parent.mkdir(parents=True, exist_ok=True)
    with input_path.open("w", encoding="ascii") as input_file:
        for frame in range(payload_frames):
            verilog_decoder.write_frame_to_file(
                h_matrix.shape[1] // (K * K),
                K,
                noisy_samples[:, frame],
                input_file,
                args.snr,
            )
            input_file.write("\n")

        dummy = np.zeros(n)
        for flush_index in range(FLUSH_FRAMES):
            verilog_decoder.write_frame_to_file(
                h_matrix.shape[1] // (K * K), K, dummy, input_file, args.snr
            )
            if flush_index + 1 < FLUSH_FRAMES:
                input_file.write("\n")

    write_clean_codewords(expected_path, clean_codewords)

    metadata = {
        "image": str(image_path),
        "image_width": int(image_array.shape[1]),
        "image_height": int(image_array.shape[0]),
        "image_bits": int(image_bits.size),
        "codeword_bits": int(n),
        "message_bits_per_frame": int(message_length),
        "payload_frames": int(payload_frames),
        "flush_frames": FLUSH_FRAMES,
        "rtl_frames": int(payload_frames + FLUSH_FRAMES),
        "snr_db": args.snr,
        "seed": args.seed,
        "input_file": str(input_path),
        "expected_codeword_file": str(expected_path),
    }
    artifacts_dir = project_dir / "artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    (artifacts_dir / "test_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )

    print(f"Image: {image_path} ({image_array.shape[1]}x{image_array.shape[0]})")
    print(f"H shape: {h_matrix.shape}")
    print(f"G shape: {generator.shape}")
    print(f"SNR: {args.snr:g} dB, seed: {args.seed}")
    print(f"Payload frames: {payload_frames}")
    print(f"RTL frames including flush: {payload_frames + FLUSH_FRAMES}")
    print(f"Created: {input_path}")
    print(f"Created: {expected_path}")


if __name__ == "__main__":
    main()
