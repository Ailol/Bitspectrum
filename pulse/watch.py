"""
watch.py — live loop over the malloc'd body. Yields only when something worthy
actually comes up.

"Worthy" = the AI-facing quant changed. We tick the body each step but only
emit an event when the projected Pauli signature differs from the previous one.
Silence (no pressure anywhere) and steady-state both compress to zero output;
transitions get a yield.

This is the generator a host or visitor consumes: a sparse stream of meaningful
moments, not a dense print of every tick.
"""
from typing import Iterator, Iterable, Optional
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "adaption"))
from pipeline import (
    init_body, step,
    gu64, MASK_BASE, M_PRESSURED, M_DIRTY, M_INTERACTIVE,
)
from bridge import project_to_pauli, pauli_to_string


def _key(pauli: Optional[dict]):
    if pauli is None:
        return None
    return (pauli["x_mask"], pauli["z_mask"], pauli["sign"], pauli["qubits"])


def watch(buf: bytearray,
          signals: Iterable[dict],
          mask_kind: str = "active") -> Iterator[dict]:
    """Tick the body forever (or until signals end). Yield on quant change.

    mask_kind selects which mask is fed to the Pauli projection:
      'pressured'   — only cells with pressure
      'interactive' — only the INTERACTIVE region
      'active'      — pressured ∪ dirty ∪ interactive (default)
    """
    last = None
    for t, signal in enumerate(signals):
        step(buf, signal)
        if mask_kind == "pressured":
            mask = gu64(buf, MASK_BASE + M_PRESSURED)
        elif mask_kind == "interactive":
            mask = gu64(buf, MASK_BASE + M_INTERACTIVE)
        else:
            mask = (gu64(buf, MASK_BASE + M_PRESSURED)
                    | gu64(buf, MASK_BASE + M_DIRTY)
                    | gu64(buf, MASK_BASE + M_INTERACTIVE))
        pauli = project_to_pauli(buf, mask) if mask else None
        k = _key(pauli)
        if k != last:
            yield {"tick": t, "mask": mask, "pauli": pauli}
            last = k


def beat(period: int = 30, width: int = 5, amplitude: float = 0.8) -> Iterator[dict]:
    """Periodic pulse signal generator. Pulse for `width` ticks every `period`."""
    t = 0
    while True:
        yield {"amplitude": amplitude if t % period < width else 0.0}
        t += 1


def asymmetric_beat(period: int = 30, width: int = 5) -> Iterator[dict]:
    """Beat with side bias — useful to make the bridge's masks visibly diverge."""
    t = 0
    while True:
        in_pulse = t % period < width
        # alternate side every two periods
        side = (t // (period * 2)) % 2
        yield {
            "amplitude": 0.8 if in_pulse else 0.0,
            "side": "left" if side == 0 else "right",
        }
        t += 1


if __name__ == "__main__":
    import itertools

    buf = init_body()
    signals = itertools.islice(beat(period=30, width=5), 120)

    print(f"{'tick':>5}  {'mask':>16}  ->pauli")
    print("-" * 60)
    for event in watch(buf, signals):
        pauli = event["pauli"]
        state = pauli_to_string(pauli) if pauli else "silent"
        print(f"{event['tick']:>5}  {bin(event['mask']):>16}  ->{state}")
