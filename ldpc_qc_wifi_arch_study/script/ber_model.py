"""arch_study: BER/FER of the bit-accurate decoder model for several 802.11n codes.

The RTL of all four architectures is bit-exact with this model (sim tests with
model_check), so the curves hold for every architecture. Data: same flow as
gen_data.py (eye.png, systematic 802.11n encoding, AWGN, 5-bit LLR), all
payload frames of the image, seed 42. Definitions as ldpc_da2_qc_wifi/ber_fer:
  raw BER  : hard decision of the input LLR vs clean codeword (all N bits)
  BER      : decoded codeword vs clean codeword (all N bits)
  BER info : first K bits (systematic information)
  FER      : frames with >= 1 wrong bit
SNR is the gen_data value (sigma = 10^(-SNR/20), unit-energy BPSK), so
Es/N0 = SNR - 3.01 dB and Eb/N0 = Es/N0 - 10 log10(R).

  python script/ber_model.py [--codes 648_12,1296_12,648_34] [--snr 1.0:6.5:0.5]
Results: outfeed/ber_model_<time>/ber_fer.csv and ber_fer.md
"""
import argparse
from datetime import datetime, timezone
import math
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "script"))


def snr_list(text):
    a, b, s = (float(v) for v in text.split(":"))
    return [round(a + i * s, 3) for i in range(int(round((b - a) / s)) + 1)]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--codes", default="648_12,1296_12,648_34")
    p.add_argument("--snr", default="1.0:6.5:0.5", help="start:stop:step in dB (gen_data SNR)")
    p.add_argument("--seed", type=int, default=42)
    a = p.parse_args(argv)
    import gen_data
    from ldpc_common import CODES, decode, load_h
    out = ROOT / "outfeed" / ("ber_model_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    out.mkdir(parents=True)
    rows = []
    for code in a.codes.split(","):
        if code not in CODES:
            raise SystemExit(f"unknown code {code}")
        h = load_h(code)
        m, n = h.shape
        k = n - m
        rate = k / n
        for snr in snr_list(a.snr):
            inp, exp, meta = gen_data.generate(snr, a.seed, ROOT / "code/data/eye.png", code)
            ref = np.array([[c == "1" for c in r] for r in exp.split()], dtype=np.uint8)
            frames = ref.shape[0]
            z = np.array([[(lambda v: v - 32 if v & 16 else v)(int(t, 2)) for t in line.split()]
                          for line in inp.splitlines()[:frames]], dtype=np.int64)
            dec, _ = decode(h, z)
            raw = (z < 0).astype(np.uint8)
            err = dec != ref
            row = dict(code=code, n=n, k=k, rate=round(rate, 4), snr_db=snr,
                       esn0_db=round(snr - 10 * math.log10(2), 2),
                       ebn0_db=round(snr - 10 * math.log10(2) - 10 * math.log10(rate), 2),
                       frames=frames, raw_ber=float((raw != ref).mean()), ber=float(err.mean()),
                       ber_info=float(err[:, :k].mean()), fer=float(err.any(axis=1).mean()))
            rows.append(row)
            print(" ".join(f"{key}={row[key]}" for key in ("code", "snr_db", "ebn0_db", "frames", "raw_ber", "ber", "fer")),
                  flush=True)
    keys = list(rows[0])
    (out / "ber_fer.csv").write_text(",".join(keys) + "\n" + "".join(",".join(str(r[c]) for c in keys) + "\n"
                                                                     for r in rows), encoding="utf-8")
    md = ["| Mã | SNR (dB) | Eb/N0 (dB) | Frame | BER thô | BER | BER info | FER |", "|---|---|---|---|---|---|---|---|"]
    md += [f"| {r['code']} | {r['snr_db']} | {r['ebn0_db']} | {r['frames']} | {r['raw_ber']:.2e} | {r['ber']:.2e} | "
           f"{r['ber_info']:.2e} | {r['fer']:.2e} |" for r in rows]
    (out / "ber_fer.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("OUTPUT=" + str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
