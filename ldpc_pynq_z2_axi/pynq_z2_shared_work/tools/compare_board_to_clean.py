"""Compare board output with expected; use --raw for the legacy bitstream."""

import argparse
from pathlib import Path


# CAU HINH: EXPECTED = codeword chuan, ACTUAL = output vua tai tu board.
# Bitstream cu: output_raw.txt, chay them --raw de doi thu tu khi so sanh.
# COD1: output_codeword.txt, chay khong co --raw de so truc tiep.
# Dan nguyen duong dan vao giua dau ngoac kep.
# Giu tien to r de Python doc dung duong dan Windows co dau backslash.
EXPECTED = Path(r"C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\FINAL_REPORT_PACKAGE\results\expected_codeword.txt")
ACTUAL = Path(r"C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\FINAL_REPORT_PACKAGE\results\output_fixed_full_board.txt")

L = 32
K = 6
N = L * K * K


def binary_lines(path: Path) -> list[str]:
    lines = ["".join(line.split()) for line in path.read_text().splitlines() if line.strip()]
    if not lines:
        raise SystemExit(f"Empty output/reference file: {path}")
    for number, line in enumerate(lines, start=1):
        if len(line) != N or set(line) - {"0", "1"}:
            raise SystemExit(f"Invalid binary frame {number} in {path}")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', action='store_true', help='Convert legacy block/lane order in memory before comparison; leave output file unchanged')
    parser.add_argument('--expected', type=Path, default=EXPECTED)
    parser.add_argument('--actual', type=Path, default=ACTUAL)
    args = parser.parse_args()
    for path in (args.expected, args.actual):
        if not path.is_file():
            raise SystemExit(f"File not found: {path}\nSet EXPECTED and ACTUAL at the top; use --raw only for legacy output_raw.txt.")
    expected = binary_lines(args.expected)
    actual = binary_lines(args.actual)
    compared = min(len(expected), len(actual))
    bit_errors = 0
    bad_frames = 0

    for index in range(compared):
        word = actual[index]
        if args.raw:
            word = ''.join(word[b*K*K+(q % K)*K+q//K] for q in range(K*K) for b in range(L))
        frame_errors = sum(left != right for left, right in zip(expected[index], word))
        bit_errors += frame_errors
        bad_frames += frame_errors > 0

    bit_errors += abs(len(expected) - len(actual)) * N
    reference_bits = len(expected) * N
    ber = bit_errors / reference_bits if reference_bits else 1.0
    passed = bit_errors == 0 and len(expected) == len(actual)

    print(f"EXPECTED_FILE={args.expected}")
    print(f"ACTUAL_FILE={args.actual}")
    print(f"COMPARISON_ORDER={'raw-to-codeword' if args.raw else 'direct-codeword'}")
    print(f"EXPECTED_FRAMES={len(expected)}")
    print(f"ACTUAL_FRAMES={len(actual)}")
    print(f"REFERENCE_BITS={reference_bits}")
    print(f"BIT_ERRORS={bit_errors}")
    print(f"BAD_FRAMES={bad_frames}")
    print(f"BER={ber:.12g}")
    print(f"RESULT={'PASS' if passed else 'FAIL'}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
