"""
hex.py — hex code as the lingua franca over the malloc'd body.

The body is a bytearray; dump_hex is buf.hex() over the meaningful range.
feed_hex overlays a foreign hex stream onto cell pressure fields. memory_score
scores how memory-like a sequence of hex snapshots is.

Vocabulary: 'hex' = our system's state layer. 'Memory' = the universal phenomenon
we probe for. The memory_score is the probe: feed a hex sequence from anywhere
(sensor bytes, audio chunks, model activations, log dumps) — a score near 1.0
means strong memory, near 0.5 means random drift, near 0.0 means anti-correlation.
"""
import struct
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pulse"))
from pipeline import init_body, step, CELL_BASE, CELL_BYTES, CELL_COUNT

PRESSURE_OFFSET   = 40           # within a cell
MASK_BASE         = 0x3000
PRESSURED_OFFSET  = MASK_BASE + 40
DUMP_END          = 0x0500       # header + region table + cells


def dump_hex(buf: bytearray, end: int = DUMP_END) -> str:
    """Body's hex word. Default range covers header + region table + cells."""
    return bytes(buf[:end]).hex()


def feed_hex(buf: bytearray, hex_in: str) -> int:
    """Overlay foreign hex onto cell pressure fields; mark PRESSURED. Returns count reached."""
    data = bytes.fromhex(hex_in)
    n = min(len(data), CELL_COUNT)
    mask = 0
    for i in range(n):
        struct.pack_into("<f", buf, CELL_BASE + i * CELL_BYTES + PRESSURE_OFFSET, data[i] / 255.0)
        mask |= (1 << i)
    cur = struct.unpack_from("<Q", buf, PRESSURED_OFFSET)[0]
    struct.pack_into("<Q", buf, PRESSURED_OFFSET, cur | mask)
    return n


def memory_score(history: list[str]) -> float:
    """Hamming similarity averaged over consecutive hex snapshots."""
    if len(history) < 2:
        return 0.0
    scores = []
    for a, b in zip(history, history[1:]):
        ba, bb = bytes.fromhex(a), bytes.fromhex(b)
        n = min(len(ba), len(bb))
        if n == 0:
            continue
        match = sum(8 - bin(x ^ y).count("1") for x, y in zip(ba[:n], bb[:n]))
        scores.append(match / (8 * n))
    return sum(scores) / len(scores) if scores else 0.0


if __name__ == "__main__":
    buf = init_body()
    history = []
    for t in range(60):
        signal = {"amplitude": 0.8 if t % 30 < 5 else 0.0}
        step(buf, signal)
        history.append(dump_hex(buf))
    bytes_per = len(history[0]) // 2
    print(f"hex length per snapshot: {len(history[0])} chars = {bytes_per} bytes")
    print(f"snapshots: {len(history)}")
    print()
    print(f"memory_score (our own body) : {memory_score(history):.3f}")
    random_history = [os.urandom(bytes_per).hex() for _ in range(60)]
    print(f"memory_score (random noise) : {memory_score(random_history):.3f}")
    frozen = [history[-1]] * 60
    print(f"memory_score (frozen state) : {memory_score(frozen):.3f}")
