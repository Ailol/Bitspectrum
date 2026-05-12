"""
glb.py — connect the GLB rig to the body memory.

Reads t-pose/*.glb's JSON chunk (no binary mesh parsing). Extracts the bone
hierarchy + rest positions, maps GLB bones to our 12 body cells, writes
cells.json — the AI-readable manifest of what each cell IS, what bone it
tracks, and where it lives.

The GLB stays as the 3D visual asset. cells.json is the meaning layer.

After running this, a visiting AI reading cells.json knows:
  cell 5 = leftHand (region JOINTS, kind 6) = GLB bone 'LeftHand'
        at rest position (x, y, z)

Execution direction: visual ↔ memory. Driving cell positions from GLB rest
pose is a follow-up — for now the manifest carries semantic context only.
"""
import struct
import json
from pathlib import Path

REPO = Path(__file__).parent
GLB_PATH = REPO.parent / "actor" / "oppression_of_t.glb"   # actor/ is sibling folder
MANIFEST_PATH = REPO / "cells.json"                        # manifest stays with glb.py

# (cell_idx, name, region, kind, glb_bone_name)
# Our canonical GLB uses cell names directly, so the mapping is near-identity;
# the region + kind columns are the semantic categorization glb.py adds on top.
CELL_TO_BONE = [
    (0,  "head",        "HEAD",        1, "head"),
    (1,  "body",        "BODY",        2, "body"),
    (2,  "hips",        "HIPS",        3, "hips"),
    (3,  "lShoulder",   "JOINTS",      4, "lShoulder"),
    (4,  "lElbow",      "JOINTS",      5, "lElbow"),
    (5,  "lHand",       "JOINTS",      6, "lHand"),
    (6,  "rShoulder",   "JOINTS",      4, "rShoulder"),
    (7,  "rElbow",      "JOINTS",      5, "rElbow"),
    (8,  "rHand",       "JOINTS",      6, "rHand"),
    (9,  "lKnee",       "JOINTS",      7, "lKnee"),
    (10, "lFoot",       "JOINTS",      8, "lFoot"),
    (11, "interactive", "INTERACTIVE", 9, "interactive"),
]


def read_glb_json(path: Path) -> dict:
    """Parse just the GLB's JSON chunk."""
    data = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"Not a GLB file: {path}")
    chunk_len = struct.unpack_from("<I", data, 12)[0]
    chunk_type = struct.unpack_from("<I", data, 16)[0]
    if chunk_type != 0x4E4F534A:
        raise ValueError("First chunk is not JSON")
    return json.loads(data[20:20 + chunk_len])


def bone_index(glb: dict, name: str):
    for i, node in enumerate(glb.get("nodes", [])):
        if node.get("name") == name:
            return i
    return None


def parent_of(glb: dict, child_idx: int):
    for i, n in enumerate(glb.get("nodes", [])):
        if child_idx in n.get("children", []):
            return i
    return None


def local_translation(glb: dict, idx: int):
    return glb["nodes"][idx].get("translation", [0.0, 0.0, 0.0])


def world_position(glb: dict, idx: int):
    """Walk to root summing local translations (rest pose, no rotations applied)."""
    pos = [0.0, 0.0, 0.0]
    cur = idx
    while cur is not None:
        t = local_translation(glb, cur)
        pos[0] += t[0]; pos[1] += t[1]; pos[2] += t[2]
        cur = parent_of(glb, cur)
    return pos


def build_manifest() -> dict:
    glb = read_glb_json(GLB_PATH)
    cells = []
    for (idx, name, region, kind, bone) in CELL_TO_BONE:
        b_idx = bone_index(glb, bone) if bone else None
        rest = world_position(glb, b_idx) if b_idx is not None else None
        cells.append({
            "cell": idx,
            "name": name,
            "region": region,
            "kind": kind,
            "glb_bone": bone,
            "glb_node": b_idx,
            "rest_position": rest,
        })
    return {
        "source_glb": GLB_PATH.name,
        "regions": ["HEAD", "BODY", "HIPS", "JOINTS", "INTERACTIVE"],
        "cells": cells,
    }


if __name__ == "__main__":
    manifest = build_manifest()
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {MANIFEST_PATH.name}")
    print()
    print(f"{'cell':>4}  {'name':<13}  {'region':<12}  {'glb_bone':<14}  rest")
    print("-" * 78)
    for c in manifest["cells"]:
        rest = c["rest_position"]
        rest_s = (f"({rest[0]:+.3f}, {rest[1]:+.3f}, {rest[2]:+.3f})"
                  if rest else "-")
        bone = c["glb_bone"] or "-"
        print(f"{c['cell']:>4}  {c['name']:<13}  {c['region']:<12}  {bone:<14}  {rest_s}")
