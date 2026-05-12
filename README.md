# Bitspectrum

Memory-native body architecture + perceptual visualizer. The body is bytes at fixed offsets; the AI visits selectively and enacts onto its numbers.

## Layout

| folder | contents | role |
|---|---|---|
| `actor/` | `oppression_of_t.glb` | the body's form (5-region skeleton, baked pose) |
| `representation/` | `viewer.html` | Three.js view + audioMotion spectrum + 5-band EQ + bitroar movement |
| `pulse/` | `pipeline.py`, `watch.py` | 5-region signal cascade; sparse event stream |
| `Raw/` | `hex.py`, `glb.py`, `cells.json` | raw stream I/O + universal-memory probe |
| `adaption/` | `BAY.md`, `body.wat`, `apex.wat`, `bridge.py` | substrate + identity + Pauli quant bridge |

## Run

```bash
py pulse/pipeline.py        # body simulation, beat pulse propagates
py Raw/hex.py               # universal memory probe (0.993 / 0.500 / 1.000)
py adaption/bridge.py       # mask -> Pauli quant
py pulse/watch.py           # yields on worthy quant change
py Raw/glb.py               # regenerate cells.json from the GLB
```

Open `representation/viewer.html` in a browser for the live view — drag-drop audio, mic input, 5-band EQ, spectrum analyzer, six swappable bitroar movement styles (pulse, bounce, sway, expand, shudder, still).

## Identity

See `adaption/BAY.md` — `pirateBAY ≠ pirateSEA`.

Originally authored with **Claude Opus 4.6**, continued with Opus 4.7 (1M context).
