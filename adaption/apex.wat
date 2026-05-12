;; ============================================================================
;; apex.wat — binary-quantum companion to body.wat.
;;
;; Compile:  wat2wasm apex.wat -o apex.wasm
;; Host:     any runtime; reads cell state through exported `mem`.
;;
;; APEX = the quantum-signature layer.
;;   body.wat carries f32 positions/velocities/pressure — the *classical* body.
;;   apex.wat carries Pauli signatures (X-mask, Z-mask, sign) — the *meaning*.
;;   Together: classical phase-space + quantum stabilizer signature.
;;
;; Why integer-only is still "real quantum":
;;   Gottesman–Knill (1998) — the subset of quantum states reachable by
;;   Clifford gates (H, S, CNOT) on |0..0⟩ is exactly representable by binary
;;   tableaux of Pauli operators, and simulable in poly time with integer
;;   arithmetic. We carry the tableau directly. No floats, no amplitudes.
;;
;; The 5 region cells (HEAD, BODY, HIPS, JOINTS, INTERACTIVE) each hold one
;; Pauli over 32 qubits. They are NOT required to commute — anti-commuting
;; pairs are *complementary observables* (an uncertainty pair).
;;
;; Initial configuration:
;;   HEAD        = X on qubit 0          \  anticommute(HEAD, BODY) = 1
;;   BODY        = Z on qubit 0          /  (uncertainty pair, qubit 0)
;;   HIPS        = X on qubit 1          \  anticommute(HIPS, JOINTS) = 1
;;   JOINTS      = Z on qubit 1          /  (uncertainty pair, qubit 1)
;;   INTERACTIVE = X on qubit 2             commutes with all of the above
;;
;; Operations (all integer, bit-level):
;;   anticommute(a, b)        — symplectic product over GF(2). 0 commute / 1 anti.
;;   compose(out, a, b)       — out := a · b (Pauli product, sign tracked mod 2).
;;   h(d) / s(d)              — Clifford gate on qubit d, applied to all 5 cells.
;;   cnot(dc, dt)             — Clifford CNOT between qubits dc, dt, all 5 cells.
;;
;; CELL LAYOUT (32 bytes each, cells start at 0x0100):
;;   +00  X mask     u32  (bit j = 1 iff Pauli has X on qubit j)
;;   +04  Z mask     u32  (bit j = 1 iff Pauli has Z on qubit j)
;;   +08  sign       u32  (mod 2: 0 = +, 1 = −)
;;   +12  kind       u32  (0 HEAD, 1 BODY, 2 HIPS, 3 JOINTS, 4 INTERACTIVE)
;;   +16  reserved
;; ============================================================================

(module
  (memory (export "mem") 1)

  ;; ------------------------------------------------------------------ helpers
  (func $cell_base (param $i i32) (result i32)
    (i32.add (i32.const 0x0100) (i32.mul (local.get $i) (i32.const 32))))

  (func $get_bit (param $v i32) (param $d i32) (result i32)
    (i32.and (i32.shr_u (local.get $v) (local.get $d)) (i32.const 1)))

  ;; Replace bit at position $d in $v with $b (0 or 1).
  (func $set_bit (param $v i32) (param $d i32) (param $b i32) (result i32)
    (i32.or
      (i32.and (local.get $v)
               (i32.xor (i32.shl (i32.const 1) (local.get $d)) (i32.const -1)))
      (i32.shl (local.get $b) (local.get $d))))

  ;; --------------------------------------------------------------------- init
  ;; Lay down 5 concept cells as listed in the header comment.
  (func (export "init")
    (local $b i32)

    ;; header: magic "apex", version 1, cell_count 5, qubit_count 32
    (i32.store (i32.const 0x0000) (i32.const 0x78657061))   ;; 'a','p','e','x'
    (i32.store (i32.const 0x0004) (i32.const 1))
    (i32.store (i32.const 0x0008) (i32.const 5))
    (i32.store (i32.const 0x000C) (i32.const 32))

    ;; HEAD = X_0
    (local.set $b (call $cell_base (i32.const 0)))
    (i32.store offset=0  (local.get $b) (i32.const 0x00000001))
    (i32.store offset=4  (local.get $b) (i32.const 0x00000000))
    (i32.store offset=8  (local.get $b) (i32.const 0))
    (i32.store offset=12 (local.get $b) (i32.const 0))

    ;; BODY = Z_0          (anticommutes with HEAD on qubit 0)
    (local.set $b (call $cell_base (i32.const 1)))
    (i32.store offset=0  (local.get $b) (i32.const 0x00000000))
    (i32.store offset=4  (local.get $b) (i32.const 0x00000001))
    (i32.store offset=8  (local.get $b) (i32.const 0))
    (i32.store offset=12 (local.get $b) (i32.const 1))

    ;; HIPS = X_1
    (local.set $b (call $cell_base (i32.const 2)))
    (i32.store offset=0  (local.get $b) (i32.const 0x00000002))
    (i32.store offset=4  (local.get $b) (i32.const 0x00000000))
    (i32.store offset=8  (local.get $b) (i32.const 0))
    (i32.store offset=12 (local.get $b) (i32.const 2))

    ;; JOINTS = Z_1        (anticommutes with HIPS on qubit 1)
    (local.set $b (call $cell_base (i32.const 3)))
    (i32.store offset=0  (local.get $b) (i32.const 0x00000000))
    (i32.store offset=4  (local.get $b) (i32.const 0x00000002))
    (i32.store offset=8  (local.get $b) (i32.const 0))
    (i32.store offset=12 (local.get $b) (i32.const 3))

    ;; INTERACTIVE = X_2   (commutes with everyone above)
    (local.set $b (call $cell_base (i32.const 4)))
    (i32.store offset=0  (local.get $b) (i32.const 0x00000004))
    (i32.store offset=4  (local.get $b) (i32.const 0x00000000))
    (i32.store offset=8  (local.get $b) (i32.const 0))
    (i32.store offset=12 (local.get $b) (i32.const 4)))

  ;; --------------------------------------------------------------- anticommute
  ;; Symplectic inner product over GF(2).
  ;; Returns 0 if cells a, b commute as Paulis; 1 if they anticommute.
  (func (export "anticommute") (param $a i32) (param $b i32) (result i32)
    (local $ba i32) (local $bb i32)
    (local.set $ba (call $cell_base (local.get $a)))
    (local.set $bb (call $cell_base (local.get $b)))
    (i32.and
      (i32.popcnt
        (i32.xor
          (i32.and (i32.load offset=0 (local.get $ba))
                   (i32.load offset=4 (local.get $bb)))
          (i32.and (i32.load offset=4 (local.get $ba))
                   (i32.load offset=0 (local.get $bb)))))
      (i32.const 1)))

  ;; ------------------------------------------------------------------- compose
  ;; out := a · b. X-masks XOR, Z-masks XOR, sign tracked mod 2.
  ;; Sign rule: every qubit where a has Z and b has X picks up a −1 when we
  ;; commute Z_a past X_b to combine them (ZX = −XZ).
  (func (export "compose") (param $out i32) (param $a i32) (param $b i32)
    (local $bo i32) (local $ba i32) (local $bb i32)
    (local $xa i32) (local $za i32) (local $xb i32) (local $zb i32)
    (local.set $bo (call $cell_base (local.get $out)))
    (local.set $ba (call $cell_base (local.get $a)))
    (local.set $bb (call $cell_base (local.get $b)))
    (local.set $xa (i32.load offset=0 (local.get $ba)))
    (local.set $za (i32.load offset=4 (local.get $ba)))
    (local.set $xb (i32.load offset=0 (local.get $bb)))
    (local.set $zb (i32.load offset=4 (local.get $bb)))
    (i32.store offset=0 (local.get $bo) (i32.xor (local.get $xa) (local.get $xb)))
    (i32.store offset=4 (local.get $bo) (i32.xor (local.get $za) (local.get $zb)))
    (i32.store offset=8 (local.get $bo)
      (i32.xor
        (i32.xor (i32.load offset=8 (local.get $ba))
                 (i32.load offset=8 (local.get $bb)))
        (i32.and
          (i32.popcnt (i32.and (local.get $za) (local.get $xb)))
          (i32.const 1)))))

  ;; ----------------------------------------------------------------------- h
  ;; Hadamard on qubit $d, applied to all 5 cells.
  ;; Rule (Aaronson–Gottesman): r ^= x_d & z_d; swap x_d and z_d.
  (func (export "h") (param $d i32)
    (local $i i32) (local $b i32)
    (local $x i32) (local $z i32) (local $xj i32) (local $zj i32)
    (local.set $i (i32.const 0))
    (block $end
      (loop $next
        (br_if $end (i32.ge_u (local.get $i) (i32.const 5)))
        (local.set $b (call $cell_base (local.get $i)))
        (local.set $x (i32.load offset=0 (local.get $b)))
        (local.set $z (i32.load offset=4 (local.get $b)))
        (local.set $xj (call $get_bit (local.get $x) (local.get $d)))
        (local.set $zj (call $get_bit (local.get $z) (local.get $d)))
        ;; r ^= xj & zj
        (i32.store offset=8 (local.get $b)
          (i32.xor (i32.load offset=8 (local.get $b))
                   (i32.and (local.get $xj) (local.get $zj))))
        ;; swap bit d of X and Z
        (i32.store offset=0 (local.get $b)
          (call $set_bit (local.get $x) (local.get $d) (local.get $zj)))
        (i32.store offset=4 (local.get $b)
          (call $set_bit (local.get $z) (local.get $d) (local.get $xj)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next))))

  ;; ----------------------------------------------------------------------- s
  ;; Phase gate S on qubit $d, applied to all 5 cells.
  ;; Rule: r ^= x_d & z_d; z_d ^= x_d.
  (func (export "s") (param $d i32)
    (local $i i32) (local $b i32)
    (local $x i32) (local $z i32) (local $xj i32) (local $zj i32)
    (local.set $i (i32.const 0))
    (block $end
      (loop $next
        (br_if $end (i32.ge_u (local.get $i) (i32.const 5)))
        (local.set $b (call $cell_base (local.get $i)))
        (local.set $x (i32.load offset=0 (local.get $b)))
        (local.set $z (i32.load offset=4 (local.get $b)))
        (local.set $xj (call $get_bit (local.get $x) (local.get $d)))
        (local.set $zj (call $get_bit (local.get $z) (local.get $d)))
        (i32.store offset=8 (local.get $b)
          (i32.xor (i32.load offset=8 (local.get $b))
                   (i32.and (local.get $xj) (local.get $zj))))
        (i32.store offset=4 (local.get $b)
          (call $set_bit (local.get $z) (local.get $d)
                (i32.xor (local.get $zj) (local.get $xj))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next))))

  ;; --------------------------------------------------------------------- cnot
  ;; CNOT(control qubit $dc, target qubit $dt), applied to all 5 cells.
  ;; Rule: r ^= x_c & z_t & (x_t ^ z_c ^ 1); x_t ^= x_c; z_c ^= z_t.
  (func (export "cnot") (param $dc i32) (param $dt i32)
    (local $i i32) (local $b i32)
    (local $x i32) (local $z i32)
    (local $xa i32) (local $xb i32) (local $za i32) (local $zb i32)
    (local.set $i (i32.const 0))
    (block $end
      (loop $next
        (br_if $end (i32.ge_u (local.get $i) (i32.const 5)))
        (local.set $b (call $cell_base (local.get $i)))
        (local.set $x (i32.load offset=0 (local.get $b)))
        (local.set $z (i32.load offset=4 (local.get $b)))
        (local.set $xa (call $get_bit (local.get $x) (local.get $dc)))
        (local.set $xb (call $get_bit (local.get $x) (local.get $dt)))
        (local.set $za (call $get_bit (local.get $z) (local.get $dc)))
        (local.set $zb (call $get_bit (local.get $z) (local.get $dt)))
        ;; r ^= xa & zb & (xb ^ za ^ 1)
        (i32.store offset=8 (local.get $b)
          (i32.xor (i32.load offset=8 (local.get $b))
            (i32.and
              (i32.and (local.get $xa) (local.get $zb))
              (i32.xor (i32.xor (local.get $xb) (local.get $za)) (i32.const 1)))))
        ;; x_t ^= x_c
        (i32.store offset=0 (local.get $b)
          (call $set_bit (local.get $x) (local.get $dt)
                (i32.xor (local.get $xb) (local.get $xa))))
        ;; z_c ^= z_t   (reload Z because it didn't change, but X did — recompute base)
        (local.set $z (i32.load offset=4 (local.get $b)))
        (i32.store offset=4 (local.get $b)
          (call $set_bit (local.get $z) (local.get $dc)
                (i32.xor (local.get $za) (local.get $zb))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next))))

  ;; ----------------------------------------------------------------- inspectors
  (func (export "cell_addr") (param $i i32) (result i32) (call $cell_base (local.get $i)))
  (func (export "x_mask")    (param $i i32) (result i32)
    (i32.load offset=0 (call $cell_base (local.get $i))))
  (func (export "z_mask")    (param $i i32) (result i32)
    (i32.load offset=4 (call $cell_base (local.get $i))))
  (func (export "sign")      (param $i i32) (result i32)
    (i32.load offset=8 (call $cell_base (local.get $i))))
  (func (export "kind")      (param $i i32) (result i32)
    (i32.load offset=12 (call $cell_base (local.get $i)))))
