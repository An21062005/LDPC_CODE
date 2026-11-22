"""arch_study: W-sweep report. Reads the latest noisy simulation results of
outfeed/<code>/reports and writes (overwriting) into outfeed/wsweep/, then
opens the figure:
  wsweep_cycles.csv   measured decode / transaction cycles per (code, arch, W)
  wsweep_report.md    cycles per W (table) and measured vs model
  wsweep_throughput.md  1. formulas  2. measured cycles -> throughput / latency
                      at the decoder clock of config.yaml (code.clock_mhz)
  wsweep_all.png      speed-up vs W = 1 of all architectures in one plot
  wsweep_<arch>.png   one plot per architecture: fp648, fp1296, pp648, serial648
  wsweep_throughput.png  grouped bars: information throughput at the config clock vs at Fmax, code 648
  wsweep_efficiency.png  bars: Mb/s per kLUT at the config clock (LUT from Vivado reports), code 648
  wsweep_bound.png    line chart, linear: transaction cycles vs W of fully-parallel; I/O-bound vs compute-bound

Cycles are measured in simulation (core_monitor: decode = core busy,
transaction = wrapper busy). Model, 18 iterations:
  decode      FP 4*18, PP 18*(2Z+6), serial >= 18*2E (lower bound)
  transaction max(decode + 2, N/W + 3)

  python script/wsweep_report.py
"""
from datetime import datetime, timezone
import csv
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "script"))
CODES = ("648_12", "1296_12", "648_34")
TEST = {"648_34": "noisy_snr6"}          # 648_34 does not decode at SNR 3 dB
BASES = ("fully_parallel", "partly_parallel", "serial")
SHORT = {"fully_parallel": "FP", "partly_parallel": "PP", "serial": "Serial"}
ITER = 18


def split_arch(arch):
    m = re.fullmatch(r"(fully_parallel|partly_parallel|serial)(?:_w(\d+))?", arch)
    return (m[1], int(m[2] or 1)) if m else (None, None)


def code_info(code):
    from ldpc_common import CODES as C, load_h
    h = load_h(code)
    return dict(n=h.shape[1], k=h.shape[1] - h.shape[0], e=int(h.sum()), z=C[code]["z"])


def model(base, w, c):
    dec = {"fully_parallel": 4 * ITER, "partly_parallel": ITER * (2 * c["z"] + 6),
           "serial": ITER * 2 * c["e"]}[base]
    return dec, max(dec + 2, c["n"] // w + 3)


def current_sha(code):
    """{arch: rtl sha256 of the current sources} (as run.py report)."""
    import importlib
    os.environ["LDPC_CODE"] = code
    for m in ("run", "ldpc_common"):
        sys.modules.pop(m, None)
    run = importlib.import_module("run")
    run.CODE = code
    cfg = run.load_config(ROOT / "script/config.yaml")
    return {a: run.arch_sources(cfg, a)[2] for a in cfg["architectures"]}


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    out = ROOT / "outfeed" / "wsweep"
    info = {c: code_info(c) for c in CODES}
    sha = {c: current_sha(c) for c in CODES}
    rows = []
    for code in CODES:
        test = TEST.get(code, "noisy")
        for p in sorted((ROOT / "outfeed" / code / "reports").glob(f"latest_sim_*_{test}.json")):
            s = load(p)
            base, w = split_arch(s.get("arch", ""))
            if base is None or s.get("test") != test or s.get("kind") != "axi" or not s.get("transaction_cycles_per_frame"):
                continue
            dec, txn = s["decode_cycles_per_frame"], s["transaction_cycles_per_frame"]
            r = dict(code=code, arch=s["arch"], base=base, w=w, test=s["test"], result=s["result"],
                     frames=s["compared_frames"], bit_errors=s["bit_errors"], model_match=s.get("model_match"),
                     decode=max(dec), decode_values=len(dec), txn=max(txn), txn_values=len(txn),
                     current=s["rtl_sha256"] == sha[code].get(s["arch"]), run=s["run_directory"])
            pd, pt = model(base, w, info[code])
            r.update(decode_model=pd, txn_model=pt, txn_err_pct=round(100 * (r["txn"] - pt) / pt, 2))
            rows.append(r)

    out.mkdir(parents=True, exist_ok=True)
    keys = ["code", "arch", "base", "w", "test", "result", "frames", "bit_errors", "model_match", "decode",
            "decode_values", "decode_model", "txn", "txn_values", "txn_model", "txn_err_pct", "current", "run"]
    with open(out / "wsweep_cycles.csv", "w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=keys)
        wr.writeheader()
        for r in sorted(rows, key=lambda r: (r["code"], r["base"], r["w"])):
            wr.writerow({k: r[k] for k in keys})

    cols = [("fully_parallel", "648_12", "FP 648"), ("fully_parallel", "1296_12", "FP 1296"),
            ("fully_parallel", "648_34", "FP 648 R3/4"),
            ("partly_parallel", "648_12", "PP 648"), ("serial", "648_12", "Serial 648")]
    get = {(r["base"], r["code"], r["w"]): r["txn"] for r in rows}
    md = ["# Quét W: chu kỳ / transaction đo trong mô phỏng", "",
          f"Sinh lúc {datetime.now(timezone.utc).isoformat(timespec='seconds')}. Chu kỳ đo bằng core_monitor "
          "(test noisy; mã 648_34 dùng noisy_snr6 vì không giải được ở SNR 3 dB; 20 frame so sánh, bit-exact với mô hình). Mô hình: transaction = max(giải mã + 2, N/W + 3); "
          "giải mã FP = 72, PP = 18(2Z+6), serial ≥ 36E (cận dưới).", "",
          "PP và serial với W > 1: bộ nhớ nạp ghi nhiều ô mỗi chu kỳ, chỉ để đo chu kỳ trong mô phỏng.", "",
          "| W | " + " | ".join(c[2] for c in cols) + " |", "|---|" + "---|" * len(cols)]
    for w in sorted({r["w"] for r in rows}):
        md.append(f"| {w} | " + " | ".join(str(get.get((b, c, w), "-")) for b, c, _ in cols) + " |")
    md += ["", "## Chi tiết: đo so với mô hình", "",
           "| Mã | Kiến trúc | W | Kết quả | Bit lỗi | Khớp mô hình | Giải mã đo | Giải mã mô hình | Transaction đo | Transaction mô hình | Sai số | Số giá trị | RTL |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["code"], BASES.index(r["base"]), r["w"])):
        lb = "≥ " if r["base"] == "serial" else ""
        md.append(f"| {r['code']} | {SHORT[r['base']]} | {r['w']} | {r['result']} | {r['bit_errors']} | {r['model_match']} | "
                  f"{r['decode']} | {lb}{r['decode_model']} | {r['txn']} | {lb}{r['txn_model']} | {r['txn_err_pct']:+.2f} % | "
                  f"{max(r['decode_values'], r['txn_values'])} | {'hiện tại' if r['current'] else 'cũ'} |")
    (out / "wsweep_report.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    hw = hw_data(sha["648_12"])
    throughput_md(rows, info, hw, out / "wsweep_throughput.md")
    try:
        plot(rows, out)
        throughput_plot(rows, info, hw, out)
        efficiency_plot(rows, info, hw, out)
        bound_plot(rows, info, out)
    except OSError:
        print("Không ghi được hình .png: hãy đóng ảnh đang mở rồi chạy lại.")
        return 1
    print("\n".join(md))
    print(f"\nOUTPUT={out.relative_to(ROOT).as_posix()}")
    if hasattr(os, "startfile"):                  # Windows: show the figure
        os.startfile(out / "wsweep_all.png")
    return 0


def throughput_md(rows, info, hw, path):
    """Section 1: formulas. Section 2: measured cycles of every (code, arch, W)
    and the throughput / latency they give at the decoder clock f of config.yaml."""
    import yaml
    f = float(yaml.safe_load((ROOT / "script/config.yaml").read_text(encoding="utf-8"))["code"]["clock_mhz"])
    name = {"fully_parallel": "Fully-parallel", "partly_parallel": "Partly-parallel", "serial": "Serial"}
    md = ["# Thông lượng các kiến trúc giải mã LDPC 802.11n", "",
          f"Sinh lúc {datetime.now(timezone.utc).isoformat(timespec='seconds')} bởi `python script/wsweep_report.py`.", "",
          "## 1. Công thức", "",
          "Ký hiệu: N = độ dài codeword, K = số bit thông tin, R = K/N, Z = kích thước khối QC, "
          f"E = số cạnh của H, I = {ITER} vòng lặp (cố định, không dừng sớm), W = số mẫu nạp / bit đọc mỗi chu kỳ, "
          "f = tần số clock lõi.", "",
          "| Đại lượng | Công thức | Ghi chú |",
          "|---|---|---|",
          "| Chu kỳ giải mã D, Fully-parallel | D = 4·I = 72 | 4 chu kỳ / vòng lặp, không phụ thuộc mã |",
          "| Chu kỳ giải mã D, Partly-parallel | D = I·(2Z + 6) | pha VN Z+3, pha CN Z+2, EVAL 1 |",
          "| Chu kỳ giải mã D, Serial | D ≥ I·2E | 1 cạnh / chu kỳ mỗi pha; đo thực tế cao hơn < 1 % (chờ FIFO) |",
          "| Chu kỳ / transaction T | T = max(D + 2, N/W + 3) | nạp frame mới song song với giải mã frame trước |",
          "| Thông lượng codeword | Θc = N·f / T | Mb/s khi f tính bằng MHz |",
          "| Thông lượng thông tin | Θi = K·f / T = R·Θc | |",
          "| Thời gian một transaction | L = T / f | µs khi f tính bằng MHz; kết quả một frame ra sau 2 transaction |",
          "| Tăng tốc theo W | S(W) = T(1) / T(W) | |", "",
          "Tham số các mã:", "",
          "| Mã | N | K | R | Z | E | D Fully | D Partly | D Serial (cận dưới) |",
          "|---|---|---|---|---|---|---|---|---|"]
    for code in CODES:
        c = info[code]
        md.append(f"| {code} | {c['n']} | {c['k']} | {c['k'] / c['n']:.2f} | {c['z']} | {c['e']} | "
                  f"{model('fully_parallel', 1, c)[0]} | {model('partly_parallel', 1, c)[0]} | "
                  f"{model('serial', 1, c)[0]} |")
    md += ["", f"## 2. Số liệu đo và thông lượng (f = {f:g} MHz)", "",
           f"Chu kỳ D và T đo trong mô phỏng (core_monitor, 20 frame nhiễu, 0 bit lỗi, bit-exact với mô hình). "
           f"f = {f:g} MHz là clock lõi của hệ thống PYNQ-Z2 (config.yaml), dùng chung cho mọi kiến trúc như một "
           "mức quy đổi cùng tần số (iso-frequency) để so sánh kiến trúc; chỉ Partly-parallel W = 1 đã build và đạt "
           f"timing ở {f:g} MHz trong hệ thống, các cấu hình khác chưa được xác nhận chạy ở tần số này. "
           "Thông lượng là của lõi + wrapper, không gồm thời gian PS ghi dữ liệu qua AXI-Lite. "
           "Partly-parallel và Serial với W > 1 chỉ dùng để đo chu kỳ (không đại diện tài nguyên thật). "
           "Fully-parallel không vừa chip của PYNQ-Z2 (xc7z020): số của nó ở đây là so sánh cùng clock, "
           "không phải đo trên board.", "",
           "| Kiến trúc | Mã | W | D đo | T đo | T mô hình | Tăng tốc S(W) | Θc (Mb/s) | Θi (Mb/s) | L (µs) |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    t1 = {(r["base"], r["code"]): r["txn"] for r in rows if r["w"] == 1}
    for r in sorted(rows, key=lambda r: (BASES.index(r["base"]), CODES.index(r["code"]), r["w"])):
        c = info[r["code"]]
        lb = "≥ " if r["base"] == "serial" else ""
        s1 = t1.get((r["base"], r["code"]))
        md.append(f"| {name[r['base']]} | {r['code']} | {r['w']} | {r['decode']} | {r['txn']} | {lb}{r['txn_model']} | "
                  f"{(s1 / r['txn']) if s1 else float('nan'):.2f}× | {c['n'] * f / r['txn']:.3f} | "
                  f"{c['k'] * f / r['txn']:.3f} | {r['txn'] / f:.2f} |")
    md += ["", "## 3. Hiệu quả phần cứng, mã 648 (LUT và Fmax từ báo cáo Vivado trong outfeed)", "",
           "LUT và Fmax lấy từ báo cáo place & route out-of-context (chỉ lõi, không wrapper). "
           "Fmax = chu kỳ ngắn nhất đạt timing sau place & route; '≥' = mọi lần thử đều đạt, Fmax thật có thể cao hơn "
           "(Fully W = 6: đường tới hạn là một net fanout lớn chưa được nhân bản ở ràng buộc 20 ns). "
           "Các kiến trúc được đặt trên chip khác nhau vì Fully-parallel không vừa xc7z020; xc7z045/xc7z100 có "
           "fabric nhanh hơn xc7z020, nên cột Θi @ Fmax không phải so sánh cùng chip. "
           "'RTL cũ' = báo cáo chạy trước lần sửa cổng nạp (Partly/Serial) và wrapper 75 MHz; với W = 1 logic tương "
           "đương (output mô phỏng giống từng bit) nhưng chưa synth lại.", "",
           f"| Cấu hình | Chip (place & route) | LUT | Fmax (MHz) | T | Θi @ {f:g} MHz (Mb/s) | Θi @ Fmax (Mb/s) | "
           f"Mb/s / kLUT @ {f:g} MHz | RTL |",
           "|---|---|---|---|---|---|---|---|---|"]
    k = info["648_12"]["k"]
    txn = {(r["base"], r["w"]): r["txn"] for r in rows if r["code"] == "648_12"}
    for key, label in HW_CFGS:
        h, t = hw.get(key), txn.get(key)
        if not h or not t:
            continue
        ge = "≥ " if h["ge"] else ""
        md.append(f"| {label} | {h['part']} | {h['lut']:.0f} | {ge}{h['fmax']:g} | {t} | {k * f / t:.3f} | "
                  f"{ge}{k * h['fmax'] / t:.3f} | {k * f / t / (h['lut'] / 1000):.3f} | "
                  f"{'hiện tại' if h['current'] else 'cũ'} |")
    path.write_text("\n".join(md) + "\n", encoding="utf-8")


HW_CFGS = [(("serial", 1), "Serial, W = 1"), (("partly_parallel", 1), "Partly-parallel, W = 1"),
           (("fully_parallel", 1), "Fully-parallel, W = 1"), (("fully_parallel", 6), "Fully-parallel, W = 6")]


def hw_data(sha648):
    """{(base, W): dict(part, lut, fmax, ge, current)} for code 648 from the
    latest OOC place & route reports. fmax = shortest met period; ge = every
    try met timing, so the true Fmax may be higher."""
    res = {}
    for p in sorted((ROOT / "outfeed" / "648_12" / "reports").glob("latest_ooc_*_impl.json")):
        s = load(p)
        base, w = split_arch(s["arch"])
        best = [x for x in s["iterations"] if x["met"] and x["period_ns"] == s.get("best_period_ns")]
        if base is None or not best or not s.get("fmax_met_mhz"):
            continue
        res[(base, w)] = dict(part=s["part"], lut=best[0]["utilization_impl"]["lut"]["used"],
                              fmax=s["fmax_met_mhz"], ge=all(x["met"] for x in s["iterations"]),
                              current=s["rtl_sha256"] == sha648.get(s["arch"]))
    return res


def _clock():
    import yaml
    return float(yaml.safe_load((ROOT / "script/config.yaml").read_text(encoding="utf-8"))["code"]["clock_mhz"])


def _style(plt):
    plt.rcParams.update({"font.family": "serif", "font.serif": ["Times New Roman"], "mathtext.fontset": "stix",
                         "font.size": 7, "axes.labelsize": 7, "legend.fontsize": 6.5,
                         "xtick.labelsize": 6.5, "ytick.labelsize": 6.5,
                         "axes.linewidth": 0.5, "xtick.direction": "in", "ytick.direction": "in",
                         "xtick.major.width": 0.5, "ytick.major.width": 0.5,
                         "xtick.major.size": 2.5, "ytick.major.size": 2.5})


def throughput_plot(rows, info, hw, out):
    """IEEE single-column grouped bars, code 648: information throughput K*f/T
    at the system clock (config.yaml) and at the measured core Fmax (OOC place
    & route). Linear axis from zero, values on the bars."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    _style(plt)
    f = _clock()
    k = info["648_12"]["k"]
    txn = {(r["base"], r["w"]): r["txn"] for r in rows if r["code"] == "648_12"}
    cfgs = [(("serial", 1), "Serial\n$W$=1"), (("partly_parallel", 1), "Partly\n$W$=1"),
            (("fully_parallel", 1), "Fully\n$W$=1"), (("fully_parallel", 6), "Fully\n$W$=6"),
            (("fully_parallel", 12), "Fully\n$W$=12")]
    cfgs = [c for c in cfgs if c[0] in txn]
    fig, ax = plt.subplots(figsize=(3.5, 2.3))
    bw, top, labels = 0.38, 0, []
    for i, (key, _) in enumerate(cfgs):
        v1 = k * f / txn[key]
        ax.bar(i - bw / 2, v1, bw, color="#2a78d6", edgecolor="white", lw=0.5, zorder=2)
        labels.append((i - bw / 2, v1, f"{v1:.3g}"))
        h = hw.get(key)
        if h:
            v2 = k * h["fmax"] / txn[key]
            ax.bar(i + bw / 2, v2, bw, color="#eb6834", edgecolor="white", lw=0.5, zorder=2)
            labels.append((i + bw / 2, v2, ("≥" if h["ge"] else "") + f"{v2:.3g}"))
        else:
            labels.append((i + bw / 2, 0, "n/a"))
        top = max(top, v1, labels[-1][1])
    for x, v, t in labels:
        ax.text(x, v + top * 0.02, t, ha="center", va="bottom", fontsize=5.8, color="0.15")
    from matplotlib.patches import Patch
    handles = [Patch(color="#2a78d6", label=f"normalized at {f:g} MHz (iso-frequency)"),
               Patch(color="#eb6834", label="at measured core Fmax (OOC place & route)")]
    ax.set_xticks(range(len(cfgs))); ax.set_xticklabels([c[1] for c in cfgs])
    ax.set_ylim(0, top * 1.2)
    ax.set_ylabel("Info. throughput (Mb/s)")
    ax.yaxis.grid(True, color="#e3e3e3", lw=0.4); ax.set_axisbelow(True)
    ax.tick_params(axis="x", length=0)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.legend(handles=handles, loc="upper left", frameon=False, handlelength=1.2)
    fig.tight_layout(pad=0.3)
    fig.savefig(out / "wsweep_throughput.png", dpi=600)
    plt.close(fig)


def efficiency_plot(rows, info, hw, out):
    """IEEE single-column bar chart, code 648: hardware efficiency = information
    throughput at the system clock / core kLUT (OOC place & route). Same clock
    for all, so only the architecture differs. LUT written under each name."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    _style(plt)
    f = _clock()
    k = info["648_12"]["k"]
    txn = {(r["base"], r["w"]): r["txn"] for r in rows if r["code"] == "648_12"}
    cfgs = [(("serial", 1), "Serial\n$W$=1", "#eda100"), (("partly_parallel", 1), "Partly\n$W$=1", "#1baf7a"),
            (("fully_parallel", 1), "Fully\n$W$=1", "#86b6ef"), (("fully_parallel", 6), "Fully\n$W$=6", "#1c5cab")]
    cfgs = [c for c in cfgs if c[0] in hw and c[0] in txn]
    eff = [k * f / txn[c[0]] / (hw[c[0]]["lut"] / 1000) for c in cfgs]
    fig, ax = plt.subplots(figsize=(3.5, 2.3))
    x = range(len(cfgs))
    ax.bar(x, eff, width=0.6, color=[c[2] for c in cfgs], edgecolor="white", lw=0.5, zorder=2)
    for xi, v in zip(x, eff):
        ax.text(xi, v + max(eff) * 0.02, f"{v:.2f}", ha="center", va="bottom", color="0.15")
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"{c[1]}\n{hw[c[0]]['lut'] / 1000:.3g}k LUT" for c in cfgs])
    ax.set_ylim(0, max(eff) * 1.18)
    ax.set_ylabel(f"Mb/s per kLUT at {f:g} MHz")
    ax.yaxis.grid(True, color="#e3e3e3", lw=0.4); ax.set_axisbelow(True)
    ax.tick_params(axis="x", length=0)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    fig.tight_layout(pad=0.3)
    fig.savefig(out / "wsweep_efficiency.png", dpi=600)
    plt.close(fig)


def bound_plot(rows, info, out):
    """IEEE single-column line chart (linear axes), fully-parallel: transaction
    cycles T vs W. Line = model max(D + 2, N/W + 3) drawn continuously (smooth
    N/W + 3 curve, then the flat decode floor D + 2); markers = measured.
    W* = N/(D - 1) marks where loading stops being the bottleneck."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    _style(plt)
    fig, ax = plt.subplots(figsize=(3.5, 2.4))
    dec = model("fully_parallel", 1, info["648_12"])[0]
    wf = np.linspace(1, 24, 800)
    ax.axhline(dec + 2, color="0.6", lw=0.6, ls=(0, (3, 2)), zorder=1)
    ax.text(0.4, dec + 2 - 12, f"decode floor $D$ + 2 = {dec + 2}", ha="left", va="top", color="0.35",
            fontsize=6.3)
    for code, label, col, mk in (("648_12", "$N$ = 648", "#2a78d6", "o"), ("1296_12", "$N$ = 1296", "#eb6834", "s")):
        n = info[code]["n"]
        ax.plot(wf, np.maximum(dec + 2, n / wf + 3), color=col, lw=1.0, zorder=2)
        pts = sorted((r["w"], r["txn"]) for r in rows if r["base"] == "fully_parallel" and r["code"] == code)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], ls="none", marker=mk, ms=3.4, mfc="white", mew=0.8,
                color=col, zorder=3)
        ax.plot([], [], color=col, lw=1.0, marker=mk, ms=3.4, mfc="white", mew=0.8, label=f"Fully-parallel, {label}")
        wk = n / (dec - 1)
        ax.annotate(f"$W^*$ ≈ {wk:.1f}", (wk, dec + 2), xytext=(0, 26), textcoords="offset points",
                    ha="center", color=col, fontsize=6.3,
                    arrowprops=dict(arrowstyle="-", lw=0.5, color=col, shrinkA=0, shrinkB=2))
    ax.text(3.2, 900, "I/O-bound: $T$ = $N/W$ + 3", color="0.3", fontsize=6.5)
    ax.set_xticks([1, 3, 6, 9, 12, 18, 24]); ax.set_xlim(0, 25)
    ax.set_ylim(0, 1400); ax.set_yticks(range(0, 1401, 200))
    ax.set_xlabel("Samples loaded per clock, $W$")
    ax.set_ylabel("Cycles per transaction $T$")
    ax.yaxis.grid(True, color="#ececec", lw=0.4); ax.set_axisbelow(True)
    ax.legend(loc="upper right", frameon=False, handlelength=2.2, borderaxespad=0.3)
    fig.tight_layout(pad=0.3)
    fig.savefig(out / "wsweep_bound.png", dpi=600)
    plt.close(fig)


SERIES = [("fully_parallel", "648_12", "fp648", "Fully-parallel (648)", "#2a78d6", "o", "-"),
          ("fully_parallel", "1296_12", "fp1296", "Fully-parallel (1296)", "#eb6834", "s", (0, (4, 1.5))),
          ("partly_parallel", "648_12", "pp648", "Partly-parallel (648)", "#1baf7a", "^", "-"),
          ("serial", "648_12", "serial648", "Serial (648)", "#eda100", "D", (0, (5, 1.5, 1, 1.5)))]


def plot(rows, out):
    """IEEE-style figures (single column, 3.5 in, Times 7 pt) of the transaction
    speed-up versus W = 1, i.e. cycles(W=1) / cycles(W), from measured cycles.
    Line = model speed-up (N+3)/max(decode+2, N/W+3) drawn continuously in W
    (smooth rise, one real corner where loading stops being the bottleneck);
    markers = measured points (they lie on the line: 0 % error for FP/PP);
    dashed line = ideal speed-up (= W). Writes, as .png
    (600 dpi): wsweep_<name>.png for each architecture and wsweep_all.png."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    plt.rcParams.update({"font.family": "serif", "font.serif": ["Times New Roman"], "mathtext.fontset": "stix",
                         "font.size": 7, "axes.labelsize": 7, "legend.fontsize": 6.5,
                         "xtick.labelsize": 6.5, "ytick.labelsize": 6.5,
                         "axes.linewidth": 0.5, "xtick.direction": "in", "ytick.direction": "in",
                         "xtick.major.width": 0.5, "ytick.major.width": 0.5,
                         "xtick.major.size": 2.5, "ytick.major.size": 2.5})

    def speedup(base, code):
        pts = dict(sorted((r["w"], r["txn"]) for r in rows if r["base"] == base and r["code"] == code))
        ws = sorted(pts)
        return (ws, [pts[1] / pts[w] for w in ws]) if 1 in pts else ([], [])

    def axes(ax):
        ax.plot([0, 20], [0, 20], color="0.6", ls=(0, (3, 2)), lw=0.6, zorder=1)
        ax.set_xticks([1, 3, 6, 9, 12, 18, 24]); ax.set_xlim(0, 25.5)
        ax.set_ylim(0, 20.5); ax.set_yticks(range(0, 21, 4))
        ax.set_xlabel("Samples loaded per clock, $W$"); ax.set_ylabel("Speed-up vs. $W = 1$")
        ax.yaxis.grid(True, color="#e3e3e3", lw=0.4); ax.set_axisbelow(True)

    info = {}

    def curve(ax, ws, sp, col, mk, ls, base, code, label=None, z=3):
        c = info.setdefault(code, code_info(code))
        dec = model(base, 1, c)[0]
        wf = np.linspace(ws[0], ws[-1], 800)
        ax.plot(wf, model(base, 1, c)[1] / np.maximum(dec + 2, c["n"] / wf + 3), color=col, ls=ls, lw=1.0, zorder=z)
        ax.plot(ws, sp, ls="none", color=col, marker=mk, ms=3.0, mfc="white", mew=0.8, zorder=z + 1)
        if label:                                   # legend entry: line + marker together
            ax.plot([], [], color=col, ls=ls, lw=1.0, marker=mk, ms=3.0, mfc="white", mew=0.8, label=label)

    def save(fig, name):
        fig.tight_layout(pad=0.3)
        fig.savefig(out / f"wsweep_{name}.png", dpi=600)
        plt.close(fig)

    # one figure per architecture
    for base, code, name, label, col, mk, ls in SERIES:
        ws, sp = speedup(base, code)
        if not ws:
            continue
        fig, ax = plt.subplots(figsize=(3.5, 2.3))
        axes(ax)
        curve(ax, ws, sp, col, mk, "-", base, code, label=label)
        ax.plot([], [], color="0.6", ls=(0, (3, 2)), lw=0.6, label="Ideal")
        low = sp[-1] < 3
        ax.text(24.5, sp[-1] + (0.8 if low else -1.2), f"{sp[-1]:.1f}×", ha="right",
                va="bottom" if low else "top", color="0.15")
        ax.legend(loc="upper left", frameon=False, handlelength=2.2, borderaxespad=0.4)
        save(fig, name)

    # all architectures in one figure (FP-1296 dashed over FP-648, PP drawn over Serial)
    fig, ax = plt.subplots(figsize=(3.5, 2.5))
    axes(ax)
    for base, code, name, label, col, mk, ls in SERIES:
        ws, sp = speedup(base, code)
        if ws:
            curve(ax, ws, sp, col, mk, ls, base, code, label=label, z={"fp1296": 5, "pp648": 7, "serial648": 3}.get(name, 3))
            if base == "fully_parallel":
                ax.text(24.5, sp[-1] - 1.2, f"{sp[-1]:.1f}×", ha="right", va="top", color="0.15")
    ax.text(24.5, 1.8, "Partly-parallel = Serial: 1.0×", ha="right", va="bottom", color="0.15")
    ax.plot([], [], color="0.6", ls=(0, (3, 2)), lw=0.6, label="Ideal")
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=3, frameon=False,
              handlelength=2.4, columnspacing=0.8, handletextpad=0.3, borderaxespad=0.2)
    save(fig, "all")


if __name__ == "__main__":
    sys.exit(main())
