"""Check the PI3 state/address relationship against a valid LDPC codeword."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
EXPECTED = ROOT.parent / "expected_codeword.txt"


def main() -> None:
    bits = [int(c) for c in EXPECTED.read_text() if c in "01"]
    text = (ROOT / "permutations" / "PI_3_shuffle.v").read_text()
    blocks = re.findall(
        r"(?:if|else if) \(state == (\d+)\) begin(.*?)(?=\n(?:else if|end\n\nendmodule))",
        text,
        re.S,
    )
    maps = {
        int(state): {
            int(out_idx): int(in_idx)
            for out_idx, in_idx in re.findall(
                r"data_out\[(\d+)\].*?data_in\[(\d+)\]", body
            )
        }
        for state, body in blocks
    }

    print(f"bits={len(bits)} states={len(maps)}")
    for cycle in range(32):
        # PE index is i + 6*j.  Its third address generator starts at
        # ((i+1)*(j+2)) mod 32.
        pe_bits = [
            bits[pe * 32 + ((((pe % 6) + 1) * ((pe // 6) + 2) + cycle) % 32)]
            for pe in range(36)
        ]
        valid_states = []
        for state, mapping in maps.items():
            shuffled = [pe_bits[mapping[out_idx]] for out_idx in range(36)]
            if all(
                sum(shuffled[group * 6 : (group + 1) * 6]) % 2 == 0
                for group in range(6)
            ):
                valid_states.append(state)
        print(f"cycle={cycle:02d} valid_states={valid_states}")


if __name__ == "__main__":
    main()
