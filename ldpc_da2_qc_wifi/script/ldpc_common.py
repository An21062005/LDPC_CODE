"""IEEE 802.11n QC-LDPC: H from the base matrix, RTL LUT, 5-bit samples, model.

Base matrices: code/data/base_matrices/<n>_<rate>.txt, copied unchanged from
https://github.com/simgunz/802.11n-ldpc (commit 615b594, protoH/). Entry < 0 is
an all-zero Z x Z block; entry k >= 0 is the identity with columns cyclically
shifted right by k (buildH.m: circshift(eye(Z), [0 k])), i.e.
    H[r*Z + i, c*Z + (i + k) mod Z] = 1.
Codeword bit n = column n of H; bits 0..k-1 are the systematic information.

The decoder model is the da2 algorithm (LUT.v phi, 5-bit sign-magnitude
messages, flooding, 18 iterations, decisions frozen at the first zero
syndrome). Only the VN adder width grows with the degree (exact sums, no
overflow, as in da2); LUT.v already returns 0 for every index >= 64, so the
7-bit LUT index is clamped at 127 without changing any value.
"""
from pathlib import Path
import re

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
CODES = {"648_12": dict(file="648_12.txt", z=27), "1296_12": dict(file="1296_12.txt", z=54)}
DEFAULT_CODE = "648_12"
LUT_FILE = ROOT / "code/rtl/da2_units/Utilities/LUT.v"
ITERATIONS = 18
SAMPLE_BITS = 5


def base_matrix(code=DEFAULT_CODE):
    path = ROOT / "code/data/base_matrices" / CODES[code]["file"]
    rows = [[int(v) for v in line.split()] for line in path.read_text().splitlines() if line.strip()]
    b = np.array(rows, dtype=np.int64)
    b[b < 0] = -1
    return b


def load_h(code=DEFAULT_CODE):
    b = base_matrix(code)
    z = CODES[code]["z"]
    mb, nb = b.shape
    h = np.zeros((mb * z, nb * z), dtype=np.uint8)
    for r in range(mb):
        for c in range(nb):
            if b[r, c] >= 0:
                for i in range(z):
                    h[r * z + i, c * z + (i + b[r, c]) % z] = 1
    return h


def check_structure(code=DEFAULT_CODE):
    """Facts that must hold for the 802.11n rate-1/2 matrices."""
    b, h = base_matrix(code), load_h(code)
    z = CODES[code]["z"]
    mb, nb = b.shape
    k = (nb - mb) * z
    hp = h[:, k:]
    rank = gf2_rank(h)
    facts = dict(code=code, z=z, base_shape=list(b.shape), h_shape=list(h.shape), nonzero_blocks=int((b >= 0).sum()),
                 edges=int(h.sum()), vn_degrees=sorted(set(h.sum(0).tolist())), cn_degrees=sorted(set(h.sum(1).tolist())),
                 rank=int(rank), k=int(h.shape[1] - rank), parity_part_rank=int(gf2_rank(hp)),
                 parity_column0_shifts=[int(v) for v in b[:, nb - mb] if v >= 0],
                 # parity block column j >= 1 holds shift-0 blocks in rows j-1 and j only
                 dual_diagonal=all(b[r, nb - mb + j] == (0 if r in (j - 1, j) else -1)
                                   for j in range(1, mb) for r in range(mb)))
    return facts


def gf2_rank(m):
    m = (m % 2).astype(np.uint8).copy()
    r = 0
    rows, cols = m.shape
    for c in range(cols):
        p = np.nonzero(m[r:, c])[0]
        if len(p) == 0:
            continue
        p = p[0] + r
        m[[r, p]] = m[[p, r]]
        nz = np.nonzero(m[:, c])[0]
        nz = nz[nz != r]
        m[nz] ^= m[r]
        r += 1
        if r == rows:
            break
    return r


def gf2_inverse(a):
    n = a.shape[0]
    m = np.concatenate([a % 2, np.eye(n, dtype=np.uint8)], axis=1).astype(np.uint8)
    for c in range(n):
        p = np.nonzero(m[c:, c])[0]
        if len(p) == 0:
            raise ValueError("matrix is singular over GF(2)")
        p = p[0] + c
        m[[c, p]] = m[[p, c]]
        nz = np.nonzero(m[:, c])[0]
        nz = nz[nz != c]
        m[nz] ^= m[c]
    return m[:, n:]


def edges(h):
    """Edges in VN-major order (column n, then increasing row)."""
    cols, rows = np.nonzero(h.T)
    return rows.astype(np.int64), cols.astype(np.int64)


def rtl_lut():
    table = np.zeros(128, dtype=np.int64)
    items = re.findall(r"(\d+)'b([01]+)\s*:\s*Y\s*=\s*4'b([01]+)", LUT_FILE.read_text(encoding="utf-8"))
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
        if line.strip():
            tokens = line.split()
            if len(tokens) != n:
                raise ValueError(f"{path}:{number}: expected {n} samples")
            frames.append([parse_sample(t) for t in tokens])
    return np.array(frames, dtype=np.int64)


def read_bits(path, n):
    rows = [l.strip() for l in Path(path).read_text(encoding="ascii").splitlines() if l.strip()]
    if any(len(r) != n or set(r) - {"0", "1"} for r in rows):
        raise ValueError(f"{path}: expected rows of {n} bits")
    return np.array([[int(c) for c in r] for r in rows], dtype=np.uint8)


def decode(h, z, iterations=ITERATIONS, lut=None):
    """Bit-accurate flooding decoder (same arithmetic as ldpc_da2_configurable)."""
    import scipy.sparse as sp
    lut = rtl_lut() if lut is None else lut
    cn, vn = edges(h)
    m, n = h.shape
    e = len(vn)
    a_vn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), vn)), shape=(e, n))
    a_cn = sp.csr_matrix((np.ones(e, dtype=np.int64), (np.arange(e), cn)), shape=(e, m))
    frames = z.shape[0]
    c2v = np.zeros((frames, e), dtype=np.int64)
    dec = np.zeros((frames, n), dtype=np.uint8)
    frozen = np.zeros(frames, dtype=bool)
    frozen_at = np.full(frames, -1)
    for it in range(iterations):
        total = z + (a_vn.T @ c2v.T).T
        hd = (total < 0).astype(np.uint8)
        t = total[:, vn] - c2v
        sign_v = (t < 0).astype(np.int64)
        phi = lut[np.minimum(np.abs(t), 127)]
        dec[~frozen] = hd[~frozen]
        sum_phi = (a_cn.T @ phi.T).T
        other = sum_phi[:, cn] - phi
        if other.max() > 127:
            raise AssertionError("7-bit CNU adder would overflow")
        sign_c = ((a_cn.T @ sign_v.T).T % 2)[:, cn] ^ sign_v
        mag = lut[other]
        c2v = np.where(sign_c == 1, -mag, mag)
        parity = (a_cn.T @ hd[:, vn].T.astype(np.int64)).T % 2
        newly = ~frozen & ~parity.any(axis=1)
        frozen_at[newly] = it + 1
        frozen |= newly
    return dec, frozen_at
