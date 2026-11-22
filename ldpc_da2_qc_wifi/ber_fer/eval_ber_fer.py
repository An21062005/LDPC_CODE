"""BER/FER of the 3 decoder architectures from the RTL simulation files.

Python twin of eval_ber_fer.m (same inputs, same numbers).

Reads, for every simulation run in outfeed/sim/<arch>_<test>_<time>/ (the files
written by 'python script/run.py sim'):
  stimulus/input.txt              LLR fed to the decoder, 648 samples per line,
                                  5-bit two's complement, step 0.25 (gen_data.py)
  stimulus/expected_codeword.txt  clean codeword (reference), 648 bits per line
  output_codeword.txt             codeword decoded by the RTL, 648 bits per line
Line f of the three files is the same frame. The SNR of a run is found by
matching stimulus/input.txt with code/data/<dataset>/input.txt (metadata.json).
For each architecture and SNR only the newest finished run (status.json written) is used.

  before decoding : hard decision of the input LLR (LLR < 0 -> bit 1)
  after decoding  : output_codeword.txt
  BER = wrong bits / compared bits, FER = frames with >= 1 wrong bit / frames
  BER info = BER over the K = 324 information bits (systematic: first K bits)

Only reads files: no simulation is run and nothing is written.

  python ber_fer/eval_ber_fer.py
"""
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]          # ldpc_da2_qc_wifi
ARCHS = ("serial", "partly_parallel", "fully_parallel")
# Line style / marker size per architecture: identical curves (bit-exact RTL) stay visible on top of each other
STYLE = {"serial": ("-s", 11), "partly_parallel": ("-o", 9), "fully_parallel": ("--x", 7)}
N, K = 648, 324


def bit_rows(text):
    """One codeword per line, '0'/'1' characters -> F x N array of 0/1."""
    rows = [line.strip() for line in text.strip().splitlines() if line.strip()]
    b = np.array([[c == "1" for c in r] for r in rows], dtype=np.uint8)
    if b.ndim != 2 or b.shape[1] != N or any(set(r) - {"0", "1"} for r in rows):
        raise ValueError(f"expected {N} bits per line")
    return b


def llr_rows(text, frames):
    """First `frames` lines of input.txt -> frames x N LLR (5-bit two's complement / 4)."""
    rows = text.strip().splitlines()[:frames]
    x = np.zeros((frames, N))
    for f, line in enumerate(rows):
        v = np.array([int(s, 2) for s in line.split()])
        if v.size != N:
            raise ValueError(f"expected {N} samples of 5 bits per line")
        v[v >= 16] -= 32
        x[f] = v / 4
    return x


def evaluate():
    datasets = {}                                       # input.txt text -> (name, SNR)
    for meta in sorted((ROOT / "code/data").glob("*/metadata.json")):
        datasets[(meta.parent / "input.txt").read_text()] = (meta.parent.name,
                                                             json.loads(meta.read_text())["snr_db"])
    res = []
    for arch in ARCHS:
        runs = sorted((p for p in (ROOT / "outfeed/sim").glob(f"{arch}_*") if p.is_dir()),
                      key=lambda p: p.stat().st_mtime, reverse=True)      # newest first
        used = set()
        for d in runs:
            fin, fref, fout = d / "stimulus/input.txt", d / "stimulus/expected_codeword.txt", d / "output_codeword.txt"
            if not (fin.is_file() and fref.is_file() and fout.is_file() and (d / "status.json").is_file()):
                continue
            text = fin.read_text()
            if text not in datasets or datasets[text][0] in used:
                continue
            name, snr = datasets[text]
            used.add(name)
            dec = bit_rows(fout.read_text())
            frames = dec.shape[0]
            ref = bit_rows(fref.read_text())[:frames]
            raw = (llr_rows(text, frames) < 0).astype(np.uint8)
            e_raw, e_dec = raw != ref, dec != ref
            st = json.loads((d / "status.json").read_text())
            res.append(dict(arch=arch, dataset=name, snr=snr, frames=frames,
                            ber_raw=e_raw.sum() / (frames * N), fer_raw=e_raw.any(1).mean(),
                            ber_dec=e_dec.sum() / (frames * N), ber_info=e_dec[:, :K].sum() / (frames * K),
                            fer_dec=e_dec.any(1).mean(), err_dec=int(e_dec.sum()),
                            result=st.get("result", "-"), model=str(st.get("model_match", "-")),
                            run=d.name))
    return res


def plot(res):
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.5))
    for ax, key, raw_key, label in ((axes[0], "ber_dec", "ber_raw", "BER"), (axes[1], "fer_dec", "fer_raw", "FER")):
        for arch in ARCHS:
            s = sorted((r for r in res if r["arch"] == arch), key=lambda r: r["snr"])
            if len(s) < 2:
                continue
            y = [r[key] if r[key] > 0 else np.nan for r in s]      # 0 cannot be drawn on a log axis
            ax.plot([r["snr"] for r in s], y, STYLE[arch][0], markersize=STYLE[arch][1], label=arch.replace("_", "-"))
        raw = {r["snr"]: r[raw_key] for r in res}
        x = sorted(raw)
        ax.plot(x, [raw[v] if raw[v] > 0 else np.nan for v in x], "k--", label="before decoding")
        ax.set_yscale("log"); ax.grid(True, which="both"); ax.legend(loc="lower left")
        ax.set_xlabel("SNR (dB)"); ax.set_ylabel(label)
    fig.suptitle("BER/FER vs SNR")
    fig.tight_layout()
    plt.show()


def main():
    res = evaluate()
    if not res:
        raise SystemExit("No simulation run with output_codeword.txt in outfeed/sim; "
                         "run python script/run.py sim first.")
    print(f"QC-LDPC ({N},{K}) 802.11n - BER/FER from RTL simulation output\n")
    print(f"{'Architecture':16} {'Dataset':11} {'SNR':>6} {'Frames':>6} | {'BER raw':>10} {'FER raw':>8} | "
          f"{'BER dec':>10} {'BER info':>10} {'FER dec':>8} {'Errors':>7} | {'Sim':6} {'Model':6} Run")
    for r in res:
        print(f"{r['arch']:16} {r['dataset']:11} {r['snr']:6.1f} {r['frames']:6d} | {r['ber_raw']:10.3e} "
              f"{r['fer_raw']:8.3f} | {r['ber_dec']:10.3e} {r['ber_info']:10.3e} {r['fer_dec']:8.3f} "
              f"{r['err_dec']:7d} | {r['result']:6} {r['model']:6} {r['run']}")
    print(f"\nBER dec = 0 means no wrong bit in the compared bits (frames x {N}); "
          f"the BER is then below 1/(frames x {N}).\n"
          "Sim = testbench result (FAIL when errors remain after decoding, expected at low SNR); "
          "Model = RTL output bit-exact with the Python model (True/False, '-' = not checked).")
    if any(len({r["snr"] for r in res if r["arch"] == a}) >= 2 for a in ARCHS):
        plot(res)
    else:
        print("Only one SNR per architecture: no BER/FER curve is drawn.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
