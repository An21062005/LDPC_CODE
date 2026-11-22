"""Print a compact error count for RTL phase-alignment sweeps."""

from pathlib import Path
import sys


def bits(path: Path) -> list[int]:
    return [int(char) for char in path.read_text() if char in "01"]


def raw_to_codeword(raw: list[int], length: int = 32, size: int = 6) -> list[int]:
    rows: list[list[int]] = []
    for address in range(length):
        block = raw[address * size * size : (address + 1) * size * size]
        rows.append(
            [block[row * size + column] for column in range(size) for row in range(size)]
        )
    return [rows[address][pe] for pe in range(size * size) for address in range(length)]


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: count_errors.py LABEL EXPECTED ACTUAL")
    label, expected_path, actual_path = sys.argv[1:]
    expected = bits(Path(expected_path))
    actual = raw_to_codeword(bits(Path(actual_path)))
    errors = sum(left != right for left, right in zip(expected, actual))
    errors += abs(len(expected) - len(actual))
    print(f"{label} errors={errors}")


if __name__ == "__main__":
    main()
