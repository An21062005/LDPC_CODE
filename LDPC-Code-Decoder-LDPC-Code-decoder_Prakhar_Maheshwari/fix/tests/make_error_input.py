"""Create a copy of input.txt with selected payload LLR signs inverted."""

from pathlib import Path
import argparse


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("positions", type=int, nargs="+", help="payload word indices")
    args = parser.parse_args()

    lines = [line.split() for line in args.source.read_text().splitlines() if line.strip()]
    if not lines or len(lines[0]) != 1152:
        raise SystemExit("source must contain 1152 five-bit LLR words per frame")

    for position in args.positions:
        if not 0 <= position < 1152:
            raise SystemExit(f"position out of range: {position}")
        word = lines[0][position]
        if len(word) != 5 or set(word) - {"0", "1"}:
            raise SystemExit(f"invalid LLR word at {position}: {word}")
        lines[0][position] = ("1" if word[0] == "0" else "0") + word[1:]

    args.destination.write_text(
        "\n".join(" ".join(frame) for frame in lines) + "\n", encoding="ascii"
    )
    print(f"Created {args.destination} with flipped positions {args.positions}")


if __name__ == "__main__":
    main()
