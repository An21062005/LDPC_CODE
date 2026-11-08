"""Code descriptions, H, bit-accurate model and data for ldpc_datn_adaptive.

* Codes come from code/configs/<name>.yaml (format ldpc-code/1).
* The model is the da2 algorithm (LUT.v phi, 5-bit LLR, 5/6-bit messages,
  flooding, 18 iterations, decisions frozen after the first zero-syndrome CN
  phase) - the same function as ldpc_da2_qc_wifi/script/ldpc_common.py. It is
  only used to CHECK simulation output, never to produce DUT output.
* Data: eye.png -> gray2bin -> systematic encoding with THIS code's H ->
  BPSK + AWGN (numpy RandomState(seed)) -> 5-bit samples, as in ldpc_da2.
"""
from pathlib import Path
import hashlib
import json
import re

import numpy as np
import yaml

ROOT = Path(__file__).resolve().parents[1]
LUT_FILE = ROOT / "code/rtl/da2_units/Utilities/LUT.v"
ITERATIONS = 18


def load_code(name):
    path = ROOT / "code/configs" / f"{name}.yaml"
    cfg = yaml.safe_load(path.read_text(encoding="utf-8"))
    if cfg.get("format") != "ldpc-code/1":
        raise ValueError(f"{path}: format must be ldpc-code/1")
    return cfg


def base_matrix(cfg):
    s = cfg["structure"]
    if s["type"] != "qc":
        return None
    rows = [[int(v) for v in l.split()] for l in (ROOT / s["base_matrix_file"]).read_text().splitlines() if l.strip()]
    b = np.array(rows, dtype=np.int64)
    b[b < 0] = -1
    return b


def build_h(cfg):
    s = cfg["structure"]
    if s["type"] == "explicit":
        return np.load(ROOT / s["h_file"]).astype(np.uint8)
    if s.get("shift") != "right_cyclic":
        raise ValueError("only right_cyclic QC shifts are defined")
    b, z = base_matrix(cfg), int(s["z"])
    h = np.zeros((b.shape[0] * z, b.shape[1] * z), dtype=np.uint8)
    for r, c in zip(*np.nonzero(b >= 0)):
        for i in range(z):
            h[r * z + i, c * z + (i + b[r, c]) % z] = 1
    return h


def gf2_inverse(a):
    n = a.shape[0]
    m = np.concatenate([a % 2, np.eye(n, dtype=np.uint8)], axis=1).astype(np.uint8)
    for c in range(n):
        p = np.nonzero(m[c:, c])[0]
        if len(p) == 0:
            raise ValueError("singular over GF(2)")
        p = p[0] + c
        m[[c, p]] = m[[p, c]]
        nz = np.nonzero(m[:, c])[0]
        m[nz[nz != c]] ^= m[c]
    return m[:, n:]


def rtl_lut():
    table = np.zeros(128, dtype=np.int64)
    items = re.findall(r"(\d+)'b([01]+)\s*:\s*Y\s*=\s*4'b([01]+)", LUT_FILE.read_text(encoding="utf-8"))
    if len(items) != 64:
        raise ValueError("LUT.v parse")
    for _, i, v in items:
        table[int(i, 2)] = int(v, 2)
    return table


def parse_sample(t):
    v = int(t, 2)
    return v - 32 if v & 16 else v


def read_input(path, n):
    rows = [l.split() for l in Path(path).read_text(encoding="ascii").splitlines() if l.strip()]
    if any(len(r) != n for r in rows):
        raise ValueError(f"{path}: expected {n} samples per line")
    return np.array([[parse_sample(t) for t in r] for r in rows], dtype=np.int64)


def read_bits(path, n):
    rows = [l.strip() for l in Path(path).read_text(encoding="ascii").splitlines() if l.strip()]
    if any(len(r) != n for r in rows):
        raise ValueError(f"{path}: expected {n} bits per line")
    return np.array([[int(c) for c in r] for r in rows], dtype=np.uint8)


def decode(h, z, iterations=ITERATIONS):
    """Bit-accurate flooding model (identical to the ldpc_da2_* models)."""
    import scipy.sparse as sp
    lut = rtl_lut()
    cols, rows = np.nonzero(h.T)
    cn, vn = rows.astype(np.int64), cols.astype(np.int64)
    m, n = h.shape
    e = len(vn)
    a_vn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), vn)), shape=(e, n))
    a_cn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), cn)), shape=(e, m))
    f = z.shape[0]
    c2v = np.zeros((f, e), dtype=np.int64)
    dec = np.zeros((f, n), dtype=np.uint8)
    frozen = np.zeros(f, dtype=bool)
    frozen_at = np.full(f, -1)
    for it in range(iterations):
        total = z + (a_vn.T @ c2v.T).T
        hd = (total < 0).astype(np.uint8)
        t = total[:, vn] - c2v
        sign_v = (t < 0).astype(np.int64)
        phi = lut[np.minimum(np.abs(t), 127)]
        dec[~frozen] = hd[~frozen]
        other = (a_cn.T @ phi.T).T[:, cn] - phi
        if other.max() > 127:
            raise AssertionError("7-bit CN sum overflow")
        sign_c = ((a_cn.T @ sign_v.T).T % 2)[:, cn] ^ sign_v
        mag = lut[other]
        c2v = np.where(sign_c == 1, -mag, mag)
        parity = (a_cn.T @ hd[:, vn].T.astype(np.int64)).T % 2
        newly = ~frozen & ~parity.any(axis=1)
        frozen_at[newly] = it + 1
        frozen |= newly
    return dec, frozen_at


def _llr_str(llr):
    num = min(max(abs(llr), -3.75), 3.75)
    r = round(num / 0.25) * 0.25
    iv = int(np.floor(r))
    bits = "0" + "{0:02b}".format(iv) + {0: "00", 25: "01", 50: "10", 75: "11"}[round(100 * (r - iv))]
    if llr >= 0:
        return bits
    i = len(bits) - 1
    while i >= 0 and bits[i] != "1":
        i -= 1
    out = list(bits)
    for k in range(i - 1, -1, -1):
        out[k] = "1" if out[k] == "0" else "0"
    return "".join(out)


def generate_data(code, snr, seed, out):
    """Same path as ldpc_da2_qc_wifi/script/gen_data.py; QC codes only."""
    from PIL import Image
    from pyldpc.utils_img import gray2bin
    cfg = load_code(code)
    h = build_h(cfg)
    m, n = h.shape
    k = n - m
    enc = (gf2_inverse(h[:, k:]).astype(np.int64) @ h[:, :k].astype(np.int64)) % 2
    img = np.asarray(Image.open(ROOT / "code/data/eye.png").convert("LA"))[:, :, 0]
    bits = gray2bin(img).flatten().astype(int)
    frames = (bits.size + k - 1) // k
    pad = np.zeros(k * frames, dtype=np.int64)
    pad[: bits.size] = bits
    msg = pad.reshape(k, frames)
    clean = np.vstack([msg, (enc @ msg) % 2])
    if ((h.astype(np.int64) @ clean) % 2).any():
        raise AssertionError("encoder output is not a codeword")
    sigma = 10 ** (-snr / 20)
    y = (-1.0) ** clean + np.random.RandomState(seed).randn(*clean.shape) * sigma
    line = lambda col: "".join(_llr_str(2 * v / (sigma * sigma)) + " " for v in col)
    lines = [line(y[:, f]) for f in range(frames)] + [line(np.zeros(n)) for _ in range(2)]
    out.mkdir(parents=True, exist_ok=True)
    inp = "\n".join(lines)
    exp = "\n".join("".join(map(str, clean[:, f])) for f in range(frames)) + "\n"
    (out / "input.txt").write_text(inp, encoding="ascii")
    (out / "expected_codeword.txt").write_text(exp, encoding="ascii")
    meta = dict(code=code, n=n, k=k, snr_db=snr, seed=seed, payload_frames=frames, flush_frames=2,
                input_sha256=hashlib.sha256(inp.encode()).hexdigest(),
                expected_sha256=hashlib.sha256(exp.encode()).hexdigest())
    (out / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return meta
