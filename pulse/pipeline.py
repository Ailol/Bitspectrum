"""
pipeline.py — 5-region pipeline over a malloc'd body buffer.

The body is a fixed bytearray (65536 bytes = 1 WASM page), laid out identically
to body.wat's linear memory. Cells live at 0x0200 + i*64. The solver and pipeline
mutate bytes at offsets; nothing else. A hex dump of this bytearray is byte-
compatible with body.wasm's exported memory.

Pipeline:  signal → INTERACTIVE region → solver → AI enacts → 4D output.
4D = (x, y, z, pressure) per cell, read from raw bytes.
"""
import struct
from typing import Callable, Optional

# --- LAYOUT (mirrors body.wat) -------------------------------------------------
BUFFER_SIZE = 65536            # 1 WASM page; the malloc.
CELL_BYTES  = 64
CELL_COUNT  = 12
CELL_BASE   = 0x0200
MASK_BASE   = 0x3000

# field offsets within a 64-byte cell
F_POS_X, F_POS_Y, F_POS_Z       =  0,  4,  8
F_VEL_X, F_VEL_Y, F_VEL_Z       = 24, 28, 32
F_RADIUS, F_PRESSURE            = 36, 40
F_FREEDOM, F_PARENT_LEAK        = 44, 48
F_HEX_STATE                     = 52
F_PARENT                        = 56
F_KIND                          = 60

# mask offsets at MASK_BASE (each i64, 8 bytes)
M_HEAD, M_TORSO, M_HIPS         =  0,  8, 16
M_JOINTS, M_INTERACTIVE         = 24, 32
M_PRESSURED, M_DIRTY, M_HIP_REQ = 40, 48, 56

# region categories (visitor menu)
HEAD, BODY, HIPS, JOINTS, INTERACTIVE = 0, 1, 2, 3, 4
REGION_NAMES = ["HEAD", "BODY", "HIPS", "JOINTS", "INTERACTIVE"]
KIND_TO_REGION = {1: HEAD, 2: BODY, 3: HIPS,
                  4: JOINTS, 5: JOINTS, 6: JOINTS, 7: JOINTS, 8: JOINTS,
                  9: INTERACTIVE}

# --- accessors over the buffer -------------------------------------------------
def cell_off(i): return CELL_BASE + i * CELL_BYTES
def gf32(b, o):    return struct.unpack_from("<f", b, o)[0]
def sf32(b, o, v): struct.pack_into("<f", b, o, v)
def gu16(b, o):    return struct.unpack_from("<H", b, o)[0]
def su16(b, o, v): struct.pack_into("<H", b, o, v)
def gu32(b, o):    return struct.unpack_from("<I", b, o)[0]
def su32(b, o, v): struct.pack_into("<I", b, o, v)
def gu64(b, o):    return struct.unpack_from("<Q", b, o)[0]
def su64(b, o, v): struct.pack_into("<Q", b, o, v)


# --- malloc + init -------------------------------------------------------------
def alloc_body() -> bytearray:
    """The malloc. Fixed-size buffer; the body is enacted on these bytes."""
    return bytearray(BUFFER_SIZE)


def init_body(buf: Optional[bytearray] = None) -> bytearray:
    """Lay down 12 cells matching body.wat's T-pose into the buffer."""
    if buf is None:
        buf = alloc_body()
    # header: magic 'body' + version + cell_count
    struct.pack_into("<III", buf, 0, 0x79646F62, 1, 12)
    # region table: cell_base, cell_stride, cell_count, mask_base
    struct.pack_into("<IIII", buf, 0x0100, CELL_BASE, CELL_BYTES, CELL_COUNT, MASK_BASE)
    # (id,  x,    y,    z,    radius, hex,        parent, kind)
    rows = [
        (0,   0.00, 1.60, 0.00, 0.12, 0x20FF8008, 1,      1),
        (1,   0.00, 1.25, 0.00, 0.18, 0x308040A0, 2,      2),
        (2,   0.00, 0.95, 0.00, 0.20, 0x40606010, 0xFFFF, 3),
        (3,   0.25, 1.40, 0.00, 0.10, 0x18C04030, 1,      4),
        (4,   0.50, 1.40, 0.00, 0.09, 0x1842AA15, 3,      5),
        (5,   0.75, 1.40, 0.00, 0.10, 0x1060FF04, 4,      6),
        (6,  -0.25, 1.40, 0.00, 0.10, 0x18C04030, 1,      4),
        (7,  -0.50, 1.40, 0.00, 0.09, 0x1842AA15, 6,      5),
        (8,  -0.75, 1.40, 0.00, 0.10, 0x1060FF04, 7,      6),
        (9,   0.10, 0.55, 0.00, 0.10, 0x208040A0, 2,      7),
        (10,  0.10, 0.08, 0.00, 0.11, 0x108020C0, 9,      8),
        (11,  0.00, 1.20, 0.60, 0.05, 0x00FFFF00, 0xFFFF, 9),
    ]
    for (i, x, y, z, r, hexs, parent, kind) in rows:
        o = cell_off(i)
        sf32(buf, o + F_POS_X, x); sf32(buf, o + F_POS_Y, y); sf32(buf, o + F_POS_Z, z)
        sf32(buf, o + F_RADIUS, r)
        sf32(buf, o + F_FREEDOM,     ((hexs >> 16) & 0xFF) / 255.0)
        sf32(buf, o + F_PARENT_LEAK,  (hexs        & 0xFF) / 255.0)
        su32(buf, o + F_HEX_STATE, hexs)
        su16(buf, o + F_PARENT, parent)
        su16(buf, o + F_KIND, kind)
    # static masks
    su64(buf, MASK_BASE + M_HEAD,        0x0001)
    su64(buf, MASK_BASE + M_TORSO,       0x0002)
    su64(buf, MASK_BASE + M_HIPS,        0x0004)
    su64(buf, MASK_BASE + M_JOINTS,      0x07F8)
    su64(buf, MASK_BASE + M_INTERACTIVE, 0x0920)
    return buf


# --- pipeline stages -----------------------------------------------------------
def stage_signal(buf: bytearray, signal: dict) -> int:
    """Stage 1. Land signal on INTERACTIVE region cells."""
    mask = gu64(buf, MASK_BASE + M_INTERACTIVE)
    pressured = gu64(buf, MASK_BASE + M_PRESSURED)
    amp = signal.get("amplitude", 0.0)
    n = 0
    for i in range(CELL_COUNT):
        if mask & (1 << i):
            o = cell_off(i)
            if amp > gf32(buf, o + F_PRESSURE):
                sf32(buf, o + F_PRESSURE, amp)
                pressured |= (1 << i)
            n += 1
    su64(buf, MASK_BASE + M_PRESSURED, pressured)
    return n


def stage_solve(buf: bytearray, dt: float = 0.016) -> list[int]:
    """Stage 2. Decay pressure, leak to parent. Returns IDs still active."""
    active = (gu64(buf, MASK_BASE + M_PRESSURED)
              | gu64(buf, MASK_BASE + M_DIRTY)
              | gu64(buf, MASK_BASE + M_INTERACTIVE))
    new_pressured = 0
    new_dirty = 0
    for i in range(CELL_COUNT):
        if not (active & (1 << i)):
            continue
        o = cell_off(i)
        p = gf32(buf, o + F_PRESSURE)
        if p <= 0.001:
            sf32(buf, o + F_PRESSURE, 0.0)
            continue
        parent = gu16(buf, o + F_PARENT)
        pl = gf32(buf, o + F_PARENT_LEAK)
        if parent != 0xFFFF:
            leak = p * pl
            if leak > 0.0001:
                po = cell_off(parent)
                if leak > gf32(buf, po + F_PRESSURE):
                    sf32(buf, po + F_PRESSURE, leak)
                new_pressured |= (1 << parent)
                new_dirty |= (1 << parent)
        new_p = p * 0.94
        sf32(buf, o + F_PRESSURE, new_p)
        if new_p > 0.001:
            new_pressured |= (1 << i)
    su64(buf, MASK_BASE + M_PRESSURED, new_pressured)
    su64(buf, MASK_BASE + M_DIRTY, new_dirty)
    return [i for i in range(CELL_COUNT) if new_pressured & (1 << i)]


def stage_enact(buf: bytearray, active: list[int],
                visitor: Optional[Callable] = None) -> list[int]:
    """Stage 3. Visitor picks which region to vector on. Cells outside not read."""
    if visitor is not None:
        return visitor(buf, active)
    region_pressure = [0.0] * 5
    for i in active:
        o = cell_off(i)
        region = KIND_TO_REGION.get(gu16(buf, o + F_KIND), INTERACTIVE)
        region_pressure[region] += gf32(buf, o + F_PRESSURE)
    chosen = region_pressure.index(max(region_pressure))
    return [i for i in active
            if KIND_TO_REGION.get(gu16(buf, cell_off(i) + F_KIND), INTERACTIVE) == chosen]


def to_4d(buf: bytearray) -> list[tuple]:
    """Each cell → (x, y, z, pressure), straight from raw bytes."""
    return [(gf32(buf, cell_off(i) + F_POS_X),
             gf32(buf, cell_off(i) + F_POS_Y),
             gf32(buf, cell_off(i) + F_POS_Z),
             gf32(buf, cell_off(i) + F_PRESSURE)) for i in range(CELL_COUNT)]


def step(buf: bytearray, signal: dict, dt: float = 0.016, visitor=None):
    stage_signal(buf, signal)
    active = stage_solve(buf, dt)
    focus = stage_enact(buf, active, visitor)
    return focus, to_4d(buf)


if __name__ == "__main__":
    buf = init_body()
    print(f"buffer size: {len(buf)} bytes (1 WASM page)")
    print(f"{'t':>3} {'focus':>22} {'region':>12} {'max_p':>8}")
    for t in range(60):
        signal = {"amplitude": 0.8 if t % 30 < 5 else 0.0}
        focus, points = step(buf, signal)
        if focus:
            o = cell_off(focus[0])
            region = REGION_NAMES[KIND_TO_REGION.get(gu16(buf, o + F_KIND), INTERACTIVE)]
            print(f"{t:3d} {str(focus):>22} {region:>12} {max(p[3] for p in points):8.3f}")
