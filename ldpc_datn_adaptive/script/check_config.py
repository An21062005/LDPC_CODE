"""Validate code-description files (format ldpc-code/1) against their H and
against the planned hardware limits (code/configs/hw_limits.yaml).

It builds H from each file, checks that the declared n, k, degrees and edge
count match H, and reports the shared-memory size each code needs. It does NOT
choose a PE count and does NOT simulate a decoder.

  python script/check_config.py                  # every code/configs/*.yaml
  python script/check_config.py code/configs/wifi_648_r12.yaml
Results: outfeed/config_check_<UTC>.json
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

import numpy as np
import yaml

ROOT = Path(__file__).resolve().parents[1]
ARITH = {"algorithm": {"da2_phi_lut"}, "llr_bits": {5}, "message_bits": {5},
         "stop": {"freeze_on_zero_syndrome"}}


def gf2_rank(m):
    m = (m % 2).astype(np.uint8).copy()
    r = 0
    for c in range(m.shape[1]):
        p = np.nonzero(m[r:, c])[0]
        if len(p) == 0:
            continue
        p = p[0] + r
        m[[r, p]] = m[[p, r]]
        nz = np.nonzero(m[:, c])[0]
        m[nz[nz != r]] ^= m[r]
        r += 1
        if r == m.shape[0]:
            break
    return r


def build_h(cfg):
    s = cfg["structure"]
    if s["type"] == "explicit":
        return np.load(ROOT / s["h_file"]).astype(np.uint8), None
    if s["type"] != "qc" or s.get("shift") != "right_cyclic":
        raise ValueError("structure.type must be explicit or qc with shift: right_cyclic")
    b = np.array([[int(v) for v in l.split()] for l in (ROOT / s["base_matrix_file"]).read_text().splitlines() if l.strip()])
    z = int(s["z"])
    h = np.zeros((b.shape[0] * z, b.shape[1] * z), dtype=np.uint8)
    for r, c in zip(*np.nonzero(b >= 0)):
        for i in range(z):
            h[r * z + i, c * z + (i + b[r, c]) % z] = 1
    return h, b


def check(path, limits):
    cfg = yaml.safe_load(path.read_text(encoding="utf-8"))
    issues = []
    if cfg.get("format") != "ldpc-code/1":
        issues.append("format must be ldpc-code/1")
    for key, allowed in ARITH.items():
        if cfg.get("arithmetic", {}).get(key) not in allowed:
            issues.append(f"arithmetic.{key} must be one of {sorted(allowed)} (only da2 arithmetic is defined)")
    if cfg.get("schedule") != "flooding":
        issues.append("schedule must be flooding (the only schedule implemented so far)")
    h, base = build_h(cfg)
    m, n = h.shape
    rank = gf2_rank(h)
    vn, cn = sorted(set(h.sum(0).tolist())), sorted(set(h.sum(1).tolist()))
    found = dict(n=n, m=m, rank=rank, k=n - rank, vn_degrees=vn, cn_degrees=cn, edges=int(h.sum()))
    for key, want, got in (("n", cfg.get("n"), n), ("k", cfg.get("k"), n - rank),
                           ("degrees.vn", cfg["degrees"]["vn"], vn), ("degrees.cn", cfg["degrees"]["cn"], cn),
                           ("degrees.edges", cfg["degrees"]["edges"], int(h.sum()))):
        if want != got:
            issues.append(f"{key}: declared {want}, H gives {got}")
    if base is not None:
        found.update(z=int(cfg["structure"]["z"]), base_shape=list(base.shape), nonzero_blocks=int((base >= 0).sum()))
    pe, mem, grid = limits["pe_cluster"], limits["memory"], limits["qc_grid"]
    # Degree/size limits only; whether the code actually runs on the shared
    # banks (QC grid, Z, block positions, routing) is decided by mapper.py.
    fit = {
        "vn_degree": max(vn) <= pe["vn_unit_slots"],
        "cn_degree": max(cn) <= pe["cn_active_degree_max"],
        "n": n <= grid["block_cols"] * grid["z_max"],
        "qc_grid": base is not None and list(base.shape) == [grid["block_rows"], grid["block_cols"]],
    }
    memory_bits = dict(message=int(h.sum()) * mem["message_bits"], intrinsic=mem["intrinsic_banks"] * n * cfg["arithmetic"]["llr_bits"],
                       decision=mem["decision_banks"] * n)
    return dict(file=path.relative_to(ROOT).as_posix(), name=cfg.get("name"), valid=not issues, issues=issues,
                from_h=found, fits_planned_limits=fit, memory_bits_needed=memory_bits)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("configs", nargs="*", type=Path)
    a = p.parse_args(argv)
    limits = yaml.safe_load((ROOT / "code/configs/hw_limits.yaml").read_text(encoding="utf-8"))
    files = [c.resolve() for c in a.configs] or sorted(f for f in (ROOT / "code/configs").glob("*.yaml") if f.name != "hw_limits.yaml")
    results = [check(f, limits) for f in files]
    out = ROOT / "outfeed" / f"config_check_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(dict(limits=limits, results=results), indent=2) + "\n", encoding="utf-8")
    for r in results:
        print(f"{'VALID' if r['valid'] else 'INVALID':8} {r['name']:15} {json.dumps(r['from_h'])}")
        print(f"         fits planned limits: {r['fits_planned_limits']}  memory bits: {r['memory_bits_needed']}")
        for i in r["issues"]:
            print("         ISSUE: " + i)
    print("RESULT_FILE=" + str(out))
    return 0 if all(r["valid"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
