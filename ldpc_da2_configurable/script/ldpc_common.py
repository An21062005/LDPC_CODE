"""Shared helpers: H matrix, RTL LUT, 5-bit LLR format and a bit-accurate model.

The model reproduces the arithmetic of the da2 RTL (VNU.v, CNU.v, LUT.v,
S_to_T.v, T_to_S.v) and its schedule: flooding, 18 iterations (36 phases),
decisions frozen after the first CNU phase whose syndrome is zero. It is only
used to CHECK simulation results; it never produces DUT output.
"""
from pathlib import Path
import re

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
H_FILE = ROOT / "code/data/H_np_array.npy"
LUT_FILE = ROOT / "code/rtl/da2_core/Utilities/LUT.v"
ITERATIONS = 18          # PE_block.v: itr_count wraps at 35 -> 36 phases
SAMPLE_BITS = 5


def load_h():
    h = np.load(H_FILE).astype(np.uint8)
    if h.shape != (576, 1152):
        raise ValueError(f"unexpected H shape {h.shape}")
    return h


def edges(h):
    """Edges in VN-major order (column n, then increasing row)."""
    cols, rows = np.nonzero(h.T)
    return rows.astype(np.int64), cols.astype(np.int64)


def rtl_lut():
    """Parse LUT.v: 7-bit index -> 4-bit value; unlisted indices use default 0."""
    table = np.zeros(128, dtype=np.int64)
    text = LUT_FILE.read_text(encoding="utf-8")
    items = re.findall(r"(\d+)'b([01]+)\s*:\s*Y\s*=\s*4'b([01]+)", text)
    if len(items) != 64:
        raise ValueError(f"LUT.v parse: expected 64 entries, got {len(items)}")
    for _, index, value in items:
        table[int(index, 2)] = int(value, 2)
    return table


def parse_sample(token):
    if len(token) != SAMPLE_BITS or set(token) - {"0", "1"}:
        raise ValueError(f"bad sample {token!r}")
    value = int(token, 2)
    return value - 32 if value & 16 else value


def read_input(path, n):
    frames = []
    for number, line in enumerate(Path(path).read_text(encoding="ascii").splitlines(), 1):
        if not line.strip():
            continue
        tokens = line.split()
        if len(tokens) != n:
            raise ValueError(f"{path}:{number}: expected {n} samples")
        frames.append([parse_sample(t) for t in tokens])
    return np.array(frames, dtype=np.int64)


def read_bits(path, n):
    rows = [l.strip() for l in Path(path).read_text(encoding="ascii").splitlines() if l.strip()]
    for number, row in enumerate(rows, 1):
        if len(row) != n or set(row) - {"0", "1"}:
            raise ValueError(f"{path}:{number}: expected {n} bits")
    return np.array([[int(c) for c in row] for row in rows], dtype=np.uint8)


def decode(h, z, iterations=ITERATIONS, lut=None):
    """Bit-accurate flooding decoder. z: (frames, N) ints in -16..15."""
    import scipy.sparse as sp
    lut = rtl_lut() if lut is None else lut
    cn, vn = edges(h)
    m, n = h.shape
    e = len(vn)
    a_vn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), vn)), shape=(e, n))
    a_cn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), cn)), shape=(e, m))
    frames = z.shape[0]
    c2v = np.zeros((frames, e), dtype=np.int64)       # first VNU phase reads zero
    dec = np.zeros((frames, n), dtype=np.uint8)
    frozen = np.zeros(frames, dtype=bool)
    frozen_at = np.full(frames, -1)
    for it in range(iterations):
        total = z + (a_vn.T @ c2v.T).T                  # VNU: Z + sum of all X
        hd = (total < 0).astype(np.uint8)
        t = total[:, vn] - c2v                          # exclude own message
        if np.abs(total).max() > 63 or np.abs(t).max() > 63:
            raise AssertionError("7-bit VNU adder would overflow")
        sign_v = (t < 0).astype(np.int64)
        phi = lut[np.minimum(np.abs(t), 127)]
        dec[~frozen] = hd[~frozen]                      # DEC_RAM written unless frozen
        # CNU: magnitude = LUT(sum of other phi); sign = XOR of other signs.
        sum_phi = (a_cn.T @ phi.T).T
        other = sum_phi[:, cn] - phi
        if other.max() > 127:
            raise AssertionError("7-bit CNU adder would overflow")
        sx = (a_cn.T @ sign_v.T).T % 2
        sign_c = sx[:, cn] ^ sign_v
        mag = lut[other]
        c2v = np.where(sign_c == 1, -mag, mag)
        parity = (a_cn.T @ hd[:, vn].T.astype(np.int64)).T % 2
        newly = ~frozen & ~parity.any(axis=1)
        frozen_at[newly] = it + 1
        frozen |= newly
    return dec, frozen_at
