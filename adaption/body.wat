;; ============================================================================
;; body.wat — memory-native body stack as a single WebAssembly module.
;;
;; Compile:    wat2wasm body.wat -o body.wasm
;; Host:       any runtime (browser, wasmtime, deno, node).
;;             Reads the body directly through exported linear memory.
;;
;; The linear memory IS the body. No middleware truth layer.
;;
;; Cotton → amino acids → prion chain:
;;   raw bytes (cotton)            = linear memory at fixed offsets.
;;   ordered cell sequence (amino) = parentIndex + hexState modulation.
;;   self-propagating fold (prion) = `step` mutates active masks, which
;;                                   wake parents through parentLeak.
;; Same pattern scales: 12 joints → many voxels → many bodies = sociology.
;; ============================================================================
;;
;; MEMORY MAP
;;   0x0000  Header           ("body" magic, version, cell_count)
;;   0x0100  Region table     (cell_base, cell_stride, cell_count, mask_base)
;;   0x0200  Body cells       (12 × 64 bytes = 0x300 bytes, ends at 0x0500)
;;   0x3000  Bitmap directory (i64 mask per category)
;;
;; CELL LAYOUT (64 bytes per cell, little-endian)
;;   +00 posX     f32     +04 posY        f32     +08 posZ        f32
;;   +12 rotX     f32     +16 rotY        f32     +20 rotZ        f32
;;   +24 velX     f32     +28 velY        f32     +32 velZ        f32
;;   +36 radius   f32     +40 pressure    f32     +44 freedom     f32
;;   +48 parentLeak f32   +52 hexState    u32
;;   +56 parentIndex u16  +58 flags       u16     +60 kind        u16
;;   +62 reserved u16
;;
;; CELL IDS (also = bit position in masks)
;;   0 head            6 rShoulder
;;   1 body            7 rElbow
;;   2 hips            8 rHand
;;   3 lShoulder       9 lKnee
;;   4 lElbow         10 lFoot
;;   5 lHand          11 interactive (cursor proxy; mover, not movee)
;;
;; MASKS at 0x3000 (each u64, 8 bytes)
;;   +0   STATIC_HEAD          bit(0)        = 0x0001
;;   +8   STATIC_TORSO         bit(1)        = 0x0002
;;   +16  STATIC_HIPS          bit(2)        = 0x0004
;;   +24  STATIC_JOINTS        bits(3..10)   = 0x07F8
;;   +32  STATIC_INTERACTIVE   bits 5,8,11   = 0x0920
;;   +40  PRESSURED            (dynamic)
;;   +48  DIRTY                (dynamic)
;;   +56  HIP_REQUIRED         (dynamic — wakes when torso/joints under pressure)
;;
;; HEX STATE = 0xRR_GG_BB_AA = pressureBias / freedom / interactionCharge / parentLeak
;;   The init function unpacks freedom (GG) and parentLeak (AA) into f32 fields
;;   for solver use. RR/BB remain in hexState for downstream interpretation.
;; ============================================================================

(module
  ;; One page = 64 KiB. The body uses < 0x4000 bytes total.
  (memory (export "mem") 1)

  ;; ------------------------------------------------------------------ helpers
  (func $cell_base (param $i i32) (result i32)
    (i32.add (i32.const 0x0200) (i32.mul (local.get $i) (i32.const 64))))

  (func $bit (param $i i32) (result i64)
    (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $i))))

  (func $mask_load (param $off i32) (result i64)
    (i64.load (i32.add (i32.const 0x3000) (local.get $off))))

  (func $mask_store (param $off i32) (param $v i64)
    (i64.store (i32.add (i32.const 0x3000) (local.get $off)) (local.get $v)))

  ;; ----------------------------------------------------------------- init_cell
  ;; Write one body cell. freedom and parentLeak are unpacked from hex GG / AA.
  (func $init_cell
      (param $i i32)
      (param $px f32) (param $py f32) (param $pz f32)
      (param $r f32) (param $hex i32)
      (param $parent i32) (param $kind i32)
    (local $b i32)
    (local.set $b (call $cell_base (local.get $i)))
    (f32.store offset=0  (local.get $b) (local.get $px))
    (f32.store offset=4  (local.get $b) (local.get $py))
    (f32.store offset=8  (local.get $b) (local.get $pz))
    (f32.store offset=36 (local.get $b) (local.get $r))
    ;; freedom = ((hex >> 16) & 0xFF) / 255
    (f32.store offset=44 (local.get $b)
      (f32.div
        (f32.convert_i32_u
          (i32.and (i32.shr_u (local.get $hex) (i32.const 16))
                   (i32.const 0xFF)))
        (f32.const 255.0)))
    ;; parentLeak = (hex & 0xFF) / 255
    (f32.store offset=48 (local.get $b)
      (f32.div
        (f32.convert_i32_u (i32.and (local.get $hex) (i32.const 0xFF)))
        (f32.const 255.0)))
    (i32.store   offset=52 (local.get $b) (local.get $hex))
    (i32.store16 offset=56 (local.get $b) (local.get $parent))
    (i32.store16 offset=60 (local.get $b) (local.get $kind)))

  ;; ----------------------------------------------------------------------- init
  ;; Lay down the 12 cells in T-pose, then the static activation masks.
  ;; parentIndex 0xFFFF = no parent.
  (func (export "init")
    ;; header: "body" + version 1 + cell_count 12
    (i32.store  (i32.const 0x0000) (i32.const 0x79646F62))   ;; 'b','o','d','y'
    (i32.store  (i32.const 0x0004) (i32.const 1))
    (i32.store  (i32.const 0x0008) (i32.const 12))

    ;; region table: cell_base, cell_stride, cell_count, mask_base
    (i32.store  (i32.const 0x0100) (i32.const 0x0200))
    (i32.store  (i32.const 0x0104) (i32.const 64))
    (i32.store  (i32.const 0x0108) (i32.const 12))
    (i32.store  (i32.const 0x010C) (i32.const 0x3000))

    ;;             id  pos                  r     hex          parent  kind
    (call $init_cell (i32.const 0)  (f32.const  0.00) (f32.const 1.60) (f32.const 0.00)
                     (f32.const 0.12) (i32.const 0x20FF8008) (i32.const 1)     (i32.const 1))  ;; head → body
    (call $init_cell (i32.const 1)  (f32.const  0.00) (f32.const 1.25) (f32.const 0.00)
                     (f32.const 0.18) (i32.const 0x308040A0) (i32.const 2)     (i32.const 2))  ;; body → hips
    (call $init_cell (i32.const 2)  (f32.const  0.00) (f32.const 0.95) (f32.const 0.00)
                     (f32.const 0.20) (i32.const 0x40606010) (i32.const 0xFFFF) (i32.const 3)) ;; hips → none
    (call $init_cell (i32.const 3)  (f32.const  0.25) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.10) (i32.const 0x18C04030) (i32.const 1)     (i32.const 4))  ;; lShoulder → body
    (call $init_cell (i32.const 4)  (f32.const  0.50) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.09) (i32.const 0x1842AA15) (i32.const 3)     (i32.const 5))  ;; lElbow → lShoulder
    (call $init_cell (i32.const 5)  (f32.const  0.75) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.10) (i32.const 0x1060FF04) (i32.const 4)     (i32.const 6))  ;; lHand → lElbow
    (call $init_cell (i32.const 6)  (f32.const -0.25) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.10) (i32.const 0x18C04030) (i32.const 1)     (i32.const 4))  ;; rShoulder → body
    (call $init_cell (i32.const 7)  (f32.const -0.50) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.09) (i32.const 0x1842AA15) (i32.const 6)     (i32.const 5))  ;; rElbow → rShoulder
    (call $init_cell (i32.const 8)  (f32.const -0.75) (f32.const 1.40) (f32.const 0.00)
                     (f32.const 0.10) (i32.const 0x1060FF04) (i32.const 7)     (i32.const 6))  ;; rHand → rElbow
    (call $init_cell (i32.const 9)  (f32.const  0.10) (f32.const 0.55) (f32.const 0.00)
                     (f32.const 0.10) (i32.const 0x208040A0) (i32.const 2)     (i32.const 7))  ;; lKnee → hips
    (call $init_cell (i32.const 10) (f32.const  0.10) (f32.const 0.08) (f32.const 0.00)
                     (f32.const 0.11) (i32.const 0x108020C0) (i32.const 9)     (i32.const 8))  ;; lFoot → lKnee
    (call $init_cell (i32.const 11) (f32.const  0.00) (f32.const 1.20) (f32.const 0.60)
                     (f32.const 0.05) (i32.const 0x00FFFF00) (i32.const 0xFFFF) (i32.const 9)) ;; interactive

    ;; static masks
    (call $mask_store (i32.const 0)  (i64.const 0x0001))   ;; HEAD
    (call $mask_store (i32.const 8)  (i64.const 0x0002))   ;; TORSO
    (call $mask_store (i32.const 16) (i64.const 0x0004))   ;; HIPS
    (call $mask_store (i32.const 24) (i64.const 0x07F8))   ;; JOINTS = bits 3..10
    (call $mask_store (i32.const 32) (i64.const 0x0920))   ;; INTERACTIVE = bits 5,8,11
    (call $mask_store (i32.const 40) (i64.const 0))        ;; PRESSURED
    (call $mask_store (i32.const 48) (i64.const 0))        ;; DIRTY
    (call $mask_store (i32.const 56) (i64.const 0)))       ;; HIP_REQUIRED

  ;; ----------------------------------------------------------------------- step
  ;; Advance only cells in active = PRESSURED ∪ DIRTY ∪ STATIC_INTERACTIVE.
  ;; Pressure decays; correction = pressure * parentLeak * 0.001 (subtracted from x).
  ;; Parent gets pressure = max(parent.pressure, pressure * parentLeak) and joins next-tick PRESSURED ∪ DIRTY.
  ;; HIP_REQUIRED wakes when torso or any joint is under pressure.
  (func (export "step") (param $dt f32)
    (local $active i64)
    (local $newPressured i64)
    (local $newDirty i64)
    (local $i i32)
    (local $b i32)
    (local $pb i32)
    (local $parent i32)
    (local $pressure f32)
    (local $parentLeak f32)
    (local $correction f32)
    (local $leak f32)

    (local.set $active
      (i64.or
        (i64.or (call $mask_load (i32.const 40))   ;; PRESSURED
                (call $mask_load (i32.const 48)))  ;; DIRTY
        (call $mask_load (i32.const 32))))         ;; STATIC_INTERACTIVE
    (local.set $newPressured (i64.const 0))
    (local.set $newDirty     (i64.const 0))
    (local.set $i            (i32.const 0))

    (block $end
      (loop $next
        (br_if $end (i32.ge_u (local.get $i) (i32.const 12)))

        ;; skip the interactive cursor proxy (cell 11)
        (if (i32.ne (local.get $i) (i32.const 11))
          (then
            (if (i64.ne
                  (i64.and (local.get $active) (call $bit (local.get $i)))
                  (i64.const 0))
              (then
                (local.set $b (call $cell_base (local.get $i)))
                (local.set $pressure   (f32.load offset=40 (local.get $b)))
                (local.set $parentLeak (f32.load offset=48 (local.get $b)))

                (local.set $correction
                  (f32.mul
                    (f32.mul (local.get $pressure) (local.get $parentLeak))
                    (f32.const 0.001)))

                ;; velocity damping ×0.92 on all three axes
                (f32.store offset=24 (local.get $b)
                  (f32.mul (f32.load offset=24 (local.get $b)) (f32.const 0.92)))
                (f32.store offset=28 (local.get $b)
                  (f32.mul (f32.load offset=28 (local.get $b)) (f32.const 0.92)))
                (f32.store offset=32 (local.get $b)
                  (f32.mul (f32.load offset=32 (local.get $b)) (f32.const 0.92)))

                ;; pos += vel*dt, with x receiving the parentLeak correction
                (f32.store offset=0 (local.get $b)
                  (f32.sub
                    (f32.add (f32.load offset=0 (local.get $b))
                             (f32.mul (f32.load offset=24 (local.get $b)) (local.get $dt)))
                    (local.get $correction)))
                (f32.store offset=4 (local.get $b)
                  (f32.add (f32.load offset=4 (local.get $b))
                           (f32.mul (f32.load offset=28 (local.get $b)) (local.get $dt))))
                (f32.store offset=8 (local.get $b)
                  (f32.add (f32.load offset=8 (local.get $b))
                           (f32.mul (f32.load offset=32 (local.get $b)) (local.get $dt))))

                ;; pressure *= 0.94 (with floor)
                (f32.store offset=40 (local.get $b)
                  (f32.mul (local.get $pressure) (f32.const 0.94)))

                (if (f32.gt (f32.load offset=40 (local.get $b)) (f32.const 0.001))
                  (then
                    (local.set $newPressured
                      (i64.or (local.get $newPressured) (call $bit (local.get $i)))))
                  (else
                    (f32.store offset=40 (local.get $b) (f32.const 0.0))))

                ;; parent leak: wake parent and inject pressure
                (local.set $parent (i32.load16_u offset=56 (local.get $b)))
                (if (i32.ne (local.get $parent) (i32.const 0xFFFF))
                  (then
                    (local.set $leak
                      (f32.mul (local.get $pressure) (local.get $parentLeak)))
                    (if (f32.gt (local.get $leak) (f32.const 0.0001))
                      (then
                        (local.set $pb (call $cell_base (local.get $parent)))
                        (if (f32.gt (local.get $leak)
                                    (f32.load offset=40 (local.get $pb)))
                          (then
                            (f32.store offset=40 (local.get $pb) (local.get $leak))))
                        (local.set $newPressured
                          (i64.or (local.get $newPressured)
                                  (call $bit (local.get $parent))))
                        (local.set $newDirty
                          (i64.or (local.get $newDirty)
                                  (call $bit (local.get $parent))))))))))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))

    (call $mask_store (i32.const 40) (local.get $newPressured))
    (call $mask_store (i32.const 48) (local.get $newDirty))

    ;; HIP_REQUIRED = (newPressured & (TORSO | JOINTS)) ? HIPS : 0
    (if (i64.ne
          (i64.and (local.get $newPressured)
                   (i64.or (call $mask_load (i32.const 8))     ;; TORSO
                           (call $mask_load (i32.const 24))))  ;; JOINTS
          (i64.const 0))
      (then (call $mask_store (i32.const 56) (call $mask_load (i32.const 16))))
      (else (call $mask_store (i32.const 56) (i64.const 0)))))

  ;; ----------------------------------------------------------------------- poke
  ;; External emitter. Cells within radius receive pressure ∝ (1 - dist/r) * strength.
  ;; They join PRESSURED ∪ DIRTY and pick up a small outward velocity nudge.
  (func (export "poke")
        (param $x f32) (param $y f32) (param $z f32)
        (param $r f32) (param $s f32)
    (local $i i32) (local $b i32)
    (local $dx f32) (local $dy f32) (local $dz f32)
    (local $dist f32) (local $p f32) (local $k f32)
    (local $pressured i64) (local $dirty i64)

    (local.set $pressured (call $mask_load (i32.const 40)))
    (local.set $dirty     (call $mask_load (i32.const 48)))
    (local.set $i (i32.const 0))

    (block $end
      (loop $next
        (br_if $end (i32.ge_u (local.get $i) (i32.const 12)))
        (if (i32.ne (local.get $i) (i32.const 11))
          (then
            (local.set $b (call $cell_base (local.get $i)))
            (local.set $dx (f32.sub (f32.load offset=0 (local.get $b)) (local.get $x)))
            (local.set $dy (f32.sub (f32.load offset=4 (local.get $b)) (local.get $y)))
            (local.set $dz (f32.sub (f32.load offset=8 (local.get $b)) (local.get $z)))
            (local.set $dist
              (f32.sqrt
                (f32.add
                  (f32.add (f32.mul (local.get $dx) (local.get $dx))
                           (f32.mul (local.get $dy) (local.get $dy)))
                  (f32.mul (local.get $dz) (local.get $dz)))))
            (if (f32.lt (local.get $dist) (local.get $r))
              (then
                (local.set $p
                  (f32.mul (local.get $s)
                    (f32.sub (f32.const 1.0)
                             (f32.div (local.get $dist) (local.get $r)))))
                (if (f32.gt (local.get $p) (f32.load offset=40 (local.get $b)))
                  (then (f32.store offset=40 (local.get $b) (local.get $p))))
                (local.set $k
                  (f32.div (f32.mul (local.get $p) (f32.const 0.4))
                           (f32.max (local.get $dist) (f32.const 0.01))))
                (f32.store offset=24 (local.get $b)
                  (f32.add (f32.load offset=24 (local.get $b))
                           (f32.mul (local.get $dx) (local.get $k))))
                (f32.store offset=28 (local.get $b)
                  (f32.add (f32.load offset=28 (local.get $b))
                           (f32.mul (local.get $dy) (local.get $k))))
                (f32.store offset=32 (local.get $b)
                  (f32.add (f32.load offset=32 (local.get $b))
                           (f32.mul (local.get $dz) (local.get $k))))
                (local.set $pressured
                  (i64.or (local.get $pressured) (call $bit (local.get $i))))
                (local.set $dirty
                  (i64.or (local.get $dirty) (call $bit (local.get $i))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))

    (call $mask_store (i32.const 40) (local.get $pressured))
    (call $mask_store (i32.const 48) (local.get $dirty)))

  ;; ----------------------------------------------------------------- inspectors
  (func (export "pressured")    (result i64) (call $mask_load (i32.const 40)))
  (func (export "dirty")        (result i64) (call $mask_load (i32.const 48)))
  (func (export "hip_required") (result i64) (call $mask_load (i32.const 56)))
  (func (export "active")       (result i64)
    (i64.or
      (i64.or (call $mask_load (i32.const 40)) (call $mask_load (i32.const 48)))
      (call $mask_load (i32.const 32))))
  (func (export "cell_addr") (param $i i32) (result i32) (call $cell_base (local.get $i)))
  (func (export "mask_addr") (param $off i32) (result i32)
    (i32.add (i32.const 0x3000) (local.get $off))))
