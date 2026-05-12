"""
bridge.py — masking technique: body memory → quant the AI can read.

Pauli encoding under Gottesman–Knill. The mask is the selector ('which cells').
The projection reads each selected cell's region + pressure and contributes one
Pauli factor on a chosen qubit. The composed Pauli (X-mask, Z-mask, sign) is
the quant — the same shape apex.wat carries.

Mapping rule:
  - Conjugate pairs (HEAD ↔ BODY on qubit 0; HIPS ↔ JOINTS on qubit 1)
    are decided by *which side has more pressure under the mask*.
    The X-side wins → contribute X_q; the Z-side wins → contribute Z_q.
    Below threshold → identity on that qubit.
  - Independent regions (INTERACTIVE on qubit 2) contribute X_q if any masked
    cell of that region has pressure ≥ threshold.

The AI reads the output as:
  - hex word: 16 bytes packing (x_mask, z_mask, sign, qubits_used).
  - human Pauli string: e.g. '+ X_0 Z_1 X_2'.

Compose multiple bridge calls via apex's `compose` to build richer signatures.
"""
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pulse"))
from pipeline import (
    init_body, step,
    cell_off, gf32, gu16, gu64,
    CELL_COUNT, MASK_BASE, F_PRESSURE, F_KIND,
    M_PRESSURED, M_INTERACTIVE,
    HEAD, BODY, HIPS, JOINTS, INTERACTIVE, KIND_TO_REGION,
)

# (X-side region, Z-side region, qubit index)
CONJUGATE_PAIRS = [
    (HEAD,  BODY,   0),
    (HIPS,  JOINTS, 1),
]
# (region, qubit) for solitary axes
INDEPENDENT = [
    (INTERACTIVE, 2),
]


def _region_pressure(buf: bytearray, selection_mask: int) -> dict:
    """Sum pressure over masked cells, grouped by region."""
    by_region = {HEAD: 0.0, BODY: 0.0, HIPS: 0.0, JOINTS: 0.0, INTERACTIVE: 0.0}
    for i in range(CELL_COUNT):
        if not (selection_mask & (1 << i)):
            continue
        o = cell_off(i)
        region = KIND_TO_REGION.get(gu16(buf, o + F_KIND), INTERACTIVE)
        by_region[region] += gf32(buf, o + F_PRESSURE)
    return by_region


def project_to_pauli(buf: bytearray, selection_mask: int,
                     threshold: float = 0.05) -> dict:
    """Bridge. Body memory + selection mask → Pauli signature dict."""
    by_region = _region_pressure(buf, selection_mask)
    x_mask = 0
    z_mask = 0
    qubits_used = 0

    for x_region, z_region, q in CONJUGATE_PAIRS:
        qubits_used |= (1 << q)
        px = by_region[x_region]
        pz = by_region[z_region]
        if max(px, pz) < threshold:
            continue
        if px >= pz:
            x_mask |= (1 << q)
        else:
            z_mask |= (1 << q)

    for region, q in INDEPENDENT:
        qubits_used |= (1 << q)
        if by_region[region] >= threshold:
            x_mask |= (1 << q)

    return {"x_mask": x_mask, "z_mask": z_mask, "sign": 0, "qubits": qubits_used}


def pauli_to_hex(pauli: dict) -> str:
    """Pauli signature as a 16-byte hex word the AI ingests."""
    return struct.pack("<IIII",
                       pauli["x_mask"], pauli["z_mask"],
                       pauli["sign"],   pauli["qubits"]).hex()


def pauli_to_string(pauli: dict) -> str:
    """Human-readable Pauli string, e.g. '+ X_0 Z_1 X_2'."""
    parts = []
    for q in range(32):
        x = (pauli["x_mask"] >> q) & 1
        z = (pauli["z_mask"] >> q) & 1
        if x and z: parts.append(f"Y_{q}")
        elif x:     parts.append(f"X_{q}")
        elif z:     parts.append(f"Z_{q}")
    sign = "-" if pauli["sign"] else "+"
    return f"{sign} " + (" ".join(parts) if parts else "I")


if __name__ == "__main__":
    buf = init_body()
    for t in range(20):
        signal = {"amplitude": 0.8 if t < 5 else 0.0}
        step(buf, signal)

    pressured = gu64(buf, MASK_BASE + M_PRESSURED)
    pauli = project_to_pauli(buf, pressured)
    print(f"mask              : PRESSURED ({bin(pressured)})")
    print(f"pauli (string)    : {pauli_to_string(pauli)}")
    print(f"pauli (hex word)  : {pauli_to_hex(pauli)}")
    print()

    interactive = gu64(buf, MASK_BASE + M_INTERACTIVE)
    pauli2 = project_to_pauli(buf, interactive)
    print(f"mask              : INTERACTIVE ({bin(interactive)})")
    print(f"pauli (string)    : {pauli_to_string(pauli2)}")
    print(f"pauli (hex word)  : {pauli_to_hex(pauli2)}")
    print()

    all_cells = (1 << CELL_COUNT) - 1
    pauli3 = project_to_pauli(buf, all_cells)
    print(f"mask              : ALL ({bin(all_cells)})")
    print(f"pauli (string)    : {pauli_to_string(pauli3)}")
    print(f"pauli (hex word)  : {pauli_to_hex(pauli3)}")
