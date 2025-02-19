(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*                  Xavier Leroy, INRIA Paris                          *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Strength reduction for operators and conditions.
    This is the machine-dependent part of [Constprop]. *)

Require Archi.
Require Import Coqlib Compopts.
Require Import AST Integers Floats.
Require Import Op Registers.
Require Import ValueDomain.

(** * Converting known values to constants *)

Definition const_for_result (a: aval) : option operation :=
  match a with
  | I n => Some(Ointconst n)
  | L n => if Archi.ptr64 then Some(Olongconst n) else None
  | F n => if Compopts.generate_float_constants tt then Some(Ofloatconst n) else None
  | FS n => if Compopts.generate_float_constants tt then Some(Osingleconst n) else None
  | Ptr(Gl id ofs) => Some(Oaddrsymbol id ofs)
  | Ptr(Stk ofs) => Some(Oaddrstack ofs)
  | _ => None
  end.

(** * Operator strength reduction *)

(** We now define auxiliary functions for strength reduction of
  operators and addressing modes: replacing an operator with a cheaper
  one if some of its arguments are statically known.  These are again
  large pattern-matchings expressed in indirect style. *)

(** Original definition:
<<
Nondetfunction cond_strength_reduction 
              (cond: condition) (args: list reg) (vl: list aval) :=
  match cond, args, vl with
  | Ccomp c, r1 :: r2 :: nil, I n1 :: v2 :: nil =>
      (Ccompimm (swap_comparison c) n1, r2 :: nil)
  | Ccomp c, r1 :: r2 :: nil, v1 :: I n2 :: nil =>
      (Ccompimm c n2, r1 :: nil)
  | Ccompu c, r1 :: r2 :: nil, I n1 :: v2 :: nil =>
      (Ccompuimm (swap_comparison c) n1, r2 :: nil)
  | Ccompu c, r1 :: r2 :: nil, v1 :: I n2 :: nil =>
      (Ccompuimm c n2, r1 :: nil)
  | Ccompl c, r1 :: r2 :: nil, L n1 :: v2 :: nil =>
      (Ccomplimm (swap_comparison c) n1, r2 :: nil)
  | Ccompl c, r1 :: r2 :: nil, v1 :: L n2 :: nil =>
      (Ccomplimm c n2, r1 :: nil)
  | Ccomplu c, r1 :: r2 :: nil, L n1 :: v2 :: nil =>
      (Ccompluimm (swap_comparison c) n1, r2 :: nil)
  | Ccomplu c, r1 :: r2 :: nil, v1 :: L n2 :: nil =>
      (Ccompluimm c n2, r1 :: nil)
  | _, _, _ => 
      (cond, args)
  end.
>>
*)

Inductive cond_strength_reduction_cases: forall (cond: condition) (args: list reg) (vl: list aval), Type :=
  | cond_strength_reduction_case1: forall c r1 r2 n1 v2, cond_strength_reduction_cases (Ccomp c) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | cond_strength_reduction_case2: forall c r1 r2 v1 n2, cond_strength_reduction_cases (Ccomp c) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | cond_strength_reduction_case3: forall c r1 r2 n1 v2, cond_strength_reduction_cases (Ccompu c) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | cond_strength_reduction_case4: forall c r1 r2 v1 n2, cond_strength_reduction_cases (Ccompu c) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | cond_strength_reduction_case5: forall c r1 r2 n1 v2, cond_strength_reduction_cases (Ccompl c) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | cond_strength_reduction_case6: forall c r1 r2 v1 n2, cond_strength_reduction_cases (Ccompl c) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | cond_strength_reduction_case7: forall c r1 r2 n1 v2, cond_strength_reduction_cases (Ccomplu c) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | cond_strength_reduction_case8: forall c r1 r2 v1 n2, cond_strength_reduction_cases (Ccomplu c) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | cond_strength_reduction_default: forall (cond: condition) (args: list reg) (vl: list aval), cond_strength_reduction_cases cond args vl.

Definition cond_strength_reduction_match (cond: condition) (args: list reg) (vl: list aval) :=
  match cond as zz1, args as zz2, vl as zz3 return cond_strength_reduction_cases zz1 zz2 zz3 with
  | Ccomp c, r1 :: r2 :: nil, I n1 :: v2 :: nil => cond_strength_reduction_case1 c r1 r2 n1 v2
  | Ccomp c, r1 :: r2 :: nil, v1 :: I n2 :: nil => cond_strength_reduction_case2 c r1 r2 v1 n2
  | Ccompu c, r1 :: r2 :: nil, I n1 :: v2 :: nil => cond_strength_reduction_case3 c r1 r2 n1 v2
  | Ccompu c, r1 :: r2 :: nil, v1 :: I n2 :: nil => cond_strength_reduction_case4 c r1 r2 v1 n2
  | Ccompl c, r1 :: r2 :: nil, L n1 :: v2 :: nil => cond_strength_reduction_case5 c r1 r2 n1 v2
  | Ccompl c, r1 :: r2 :: nil, v1 :: L n2 :: nil => cond_strength_reduction_case6 c r1 r2 v1 n2
  | Ccomplu c, r1 :: r2 :: nil, L n1 :: v2 :: nil => cond_strength_reduction_case7 c r1 r2 n1 v2
  | Ccomplu c, r1 :: r2 :: nil, v1 :: L n2 :: nil => cond_strength_reduction_case8 c r1 r2 v1 n2
  | cond, args, vl => cond_strength_reduction_default cond args vl
  end.

Definition cond_strength_reduction (cond: condition) (args: list reg) (vl: list aval) :=
  match cond_strength_reduction_match cond args vl with
  | cond_strength_reduction_case1 c r1 r2 n1 v2 => (* Ccomp c, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      (Ccompimm (swap_comparison c) n1, r2 :: nil)
  | cond_strength_reduction_case2 c r1 r2 v1 n2 => (* Ccomp c, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      (Ccompimm c n2, r1 :: nil)
  | cond_strength_reduction_case3 c r1 r2 n1 v2 => (* Ccompu c, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      (Ccompuimm (swap_comparison c) n1, r2 :: nil)
  | cond_strength_reduction_case4 c r1 r2 v1 n2 => (* Ccompu c, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      (Ccompuimm c n2, r1 :: nil)
  | cond_strength_reduction_case5 c r1 r2 n1 v2 => (* Ccompl c, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      (Ccomplimm (swap_comparison c) n1, r2 :: nil)
  | cond_strength_reduction_case6 c r1 r2 v1 n2 => (* Ccompl c, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      (Ccomplimm c n2, r1 :: nil)
  | cond_strength_reduction_case7 c r1 r2 n1 v2 => (* Ccomplu c, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      (Ccompluimm (swap_comparison c) n1, r2 :: nil)
  | cond_strength_reduction_case8 c r1 r2 v1 n2 => (* Ccomplu c, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      (Ccompluimm c n2, r1 :: nil)
  | cond_strength_reduction_default cond args vl =>
      (cond, args)
  end.


Definition make_cmp_base (c: condition) (args: list reg) (vl: list aval) :=
  let (c', args') := cond_strength_reduction c args vl in (Ocmp c', args').

Definition make_cmp_imm_eq (c: condition) (args: list reg) (vl: list aval) 
                           (n: int) (r1: reg) (v1: aval) :=
  if Int.eq_dec n Int.one && vincl v1 (Uns Ptop 1) then (Omove, r1 :: nil)
  else if Int.eq_dec n Int.zero && vincl v1 (Uns Ptop 1) then (Oxorimm Int.one, r1 :: nil)
  else make_cmp_base c args vl.

Definition make_cmp_imm_ne (c: condition) (args: list reg) (vl: list aval) 
                           (n: int) (r1: reg) (v1: aval) :=
  if Int.eq_dec n Int.zero && vincl v1 (Uns Ptop 1) then (Omove, r1 :: nil)
  else if Int.eq_dec n Int.one && vincl v1 (Uns Ptop 1) then (Oxorimm Int.one, r1 :: nil)
  else make_cmp_base c args vl.

(** Original definition:
<<
Nondetfunction make_cmp (c: condition) (args: list reg) (vl: list aval) :=
  match c, args, vl with
  | Ccompimm Ceq n, r1 :: nil, v1 :: nil =>
      make_cmp_imm_eq c args vl n r1 v1
  | Ccompimm Cne n, r1 :: nil, v1 :: nil =>
      make_cmp_imm_ne c args vl n r1 v1
  | Ccompuimm Ceq n, r1 :: nil, v1 :: nil =>
      make_cmp_imm_eq c args vl n r1 v1
  | Ccompuimm Cne n, r1 :: nil, v1 :: nil =>
      make_cmp_imm_ne c args vl n r1 v1
  | _, _, _ =>
      make_cmp_base c args vl
  end.
>>
*)

Inductive make_cmp_cases: forall (c: condition) (args: list reg) (vl: list aval), Type :=
  | make_cmp_case1: forall n r1 v1, make_cmp_cases (Ccompimm Ceq n) (r1 :: nil) (v1 :: nil)
  | make_cmp_case2: forall n r1 v1, make_cmp_cases (Ccompimm Cne n) (r1 :: nil) (v1 :: nil)
  | make_cmp_case3: forall n r1 v1, make_cmp_cases (Ccompuimm Ceq n) (r1 :: nil) (v1 :: nil)
  | make_cmp_case4: forall n r1 v1, make_cmp_cases (Ccompuimm Cne n) (r1 :: nil) (v1 :: nil)
  | make_cmp_default: forall (c: condition) (args: list reg) (vl: list aval), make_cmp_cases c args vl.

Definition make_cmp_match (c: condition) (args: list reg) (vl: list aval) :=
  match c as zz1, args as zz2, vl as zz3 return make_cmp_cases zz1 zz2 zz3 with
  | Ccompimm Ceq n, r1 :: nil, v1 :: nil => make_cmp_case1 n r1 v1
  | Ccompimm Cne n, r1 :: nil, v1 :: nil => make_cmp_case2 n r1 v1
  | Ccompuimm Ceq n, r1 :: nil, v1 :: nil => make_cmp_case3 n r1 v1
  | Ccompuimm Cne n, r1 :: nil, v1 :: nil => make_cmp_case4 n r1 v1
  | c, args, vl => make_cmp_default c args vl
  end.

Definition make_cmp (c: condition) (args: list reg) (vl: list aval) :=
  match make_cmp_match c args vl with
  | make_cmp_case1 n r1 v1 => (* Ccompimm Ceq n, r1 :: nil, v1 :: nil *) 
      make_cmp_imm_eq c args vl n r1 v1
  | make_cmp_case2 n r1 v1 => (* Ccompimm Cne n, r1 :: nil, v1 :: nil *) 
      make_cmp_imm_ne c args vl n r1 v1
  | make_cmp_case3 n r1 v1 => (* Ccompuimm Ceq n, r1 :: nil, v1 :: nil *) 
      make_cmp_imm_eq c args vl n r1 v1
  | make_cmp_case4 n r1 v1 => (* Ccompuimm Cne n, r1 :: nil, v1 :: nil *) 
      make_cmp_imm_ne c args vl n r1 v1
  | make_cmp_default c args vl =>
      make_cmp_base c args vl
  end.


Definition make_addimm (n: int) (r: reg) :=
  if Int.eq n Int.zero
  then (Omove, r :: nil)
  else (Oaddimm n, r :: nil).

Definition make_shlimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int.iwordsize then (Oshlimm n, r1 :: nil)
  else (Oshl, r1 :: r2 :: nil).

Definition make_shrimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int.iwordsize then (Oshrimm n, r1 :: nil)
  else (Oshr, r1 :: r2 :: nil).

Definition make_shruimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int.iwordsize then (Oshruimm n, r1 :: nil)
  else (Oshru, r1 :: r2 :: nil).

Definition make_mulimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then
    (Ointconst Int.zero, nil)
  else if Int.eq n Int.one then
    (Omove, r1 :: nil)
  else
    match Int.is_power2 n with
    | Some l => (Oshlimm l, r1 :: nil)
    | None => (Omul, r1 :: r2 :: nil)
    end.

Definition make_andimm (n: int) (r: reg) (a: aval) :=
  if Int.eq n Int.zero then (Ointconst Int.zero, nil)
  else if Int.eq n Int.mone then (Omove, r :: nil)
  else if match a with Uns _ m => Int.eq (Int.zero_ext m (Int.not n)) Int.zero
                     | _ => false end
  then (Omove, r :: nil)
  else (Oandimm n, r :: nil).

Definition make_orimm (n: int) (r: reg) :=
  if Int.eq n Int.zero then (Omove, r :: nil)
  else if Int.eq n Int.mone then (Ointconst Int.mone, nil)
  else (Oorimm n, r :: nil).

Definition make_xorimm (n: int) (r: reg) :=
  if Int.eq n Int.zero then (Omove, r :: nil)
  else (Oxorimm n, r :: nil).

Definition make_divimm n (r1 r2: reg) :=
  if Int.eq n Int.one then
    (Omove, r1 :: nil)
  else
    match Int.is_power2 n with
    | Some l => if Int.ltu l (Int.repr 31)
                then (Oshrximm l, r1 :: nil)
                else (Odiv, r1 :: r2 :: nil)
    | None   => (Odiv, r1 :: r2 :: nil)
    end.

Definition make_divuimm n (r1 r2: reg) :=
  if Int.eq n Int.one then
    (Omove, r1 :: nil)
  else
    match Int.is_power2 n with
    | Some l => (Oshruimm l, r1 :: nil)
    | None   => (Odivu, r1 :: r2 :: nil)
    end.

Definition make_moduimm n (r1 r2: reg) :=
  match Int.is_power2 n with
  | Some l => (Oandimm (Int.sub n Int.one), r1 :: nil)
  | None   => (Omodu, r1 :: r2 :: nil)
  end.

Definition make_addlimm (n: int64) (r: reg) :=
  if Int64.eq n Int64.zero
  then (Omove, r :: nil)
  else (Oaddlimm n, r :: nil).

Definition make_shllimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int64.iwordsize' then (Oshllimm n, r1 :: nil)
  else (Oshll, r1 :: r2 :: nil).

Definition make_shrlimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int64.iwordsize' then (Oshrlimm n, r1 :: nil)
  else (Oshrl, r1 :: r2 :: nil).

Definition make_shrluimm (n: int) (r1 r2: reg) :=
  if Int.eq n Int.zero then (Omove, r1 :: nil)
  else if Int.ltu n Int64.iwordsize' then (Oshrluimm n, r1 :: nil)
  else (Oshrlu, r1 :: r2 :: nil).

Definition make_mullimm (n: int64) (r1 r2: reg) :=
  if Int64.eq n Int64.zero then
    (Olongconst Int64.zero, nil)
  else if Int64.eq n Int64.one then
    (Omove, r1 :: nil)
  else
    match Int64.is_power2' n with
    | Some l => (Oshllimm l, r1 :: nil)
    | None => (Omull, r1 :: r2 :: nil)
    end.

Definition make_andlimm (n: int64) (r: reg) (a: aval) :=
  if Int64.eq n Int64.zero then (Olongconst Int64.zero, nil)
  else if Int64.eq n Int64.mone then (Omove, r :: nil)
  else (Oandlimm n, r :: nil).

Definition make_orlimm (n: int64) (r: reg) :=
  if Int64.eq n Int64.zero then (Omove, r :: nil)
  else if Int64.eq n Int64.mone then (Olongconst Int64.mone, nil)
  else (Oorlimm n, r :: nil).

Definition make_xorlimm (n: int64) (r: reg) :=
  if Int64.eq n Int64.zero then (Omove, r :: nil)
  else (Oxorlimm n, r :: nil).

Definition make_divlimm n (r1 r2: reg) :=
  match Int64.is_power2' n with
  | Some l => if Int.ltu l (Int.repr 63)
              then (Oshrxlimm l, r1 :: nil)
              else (Odivl, r1 :: r2 :: nil)
  | None   => (Odivl, r1 :: r2 :: nil)
  end.

Definition make_divluimm n (r1 r2: reg) :=
  match Int64.is_power2' n with
  | Some l => (Oshrluimm l, r1 :: nil)
  | None   => (Odivlu, r1 :: r2 :: nil)
  end.

Definition make_modluimm n (r1 r2: reg) :=
  match Int64.is_power2 n with
  | Some l => (Oandlimm (Int64.sub n Int64.one), r1 :: nil)
  | None   => (Omodlu, r1 :: r2 :: nil)
  end.

Definition make_mulfimm (n: float) (r r1 r2: reg) :=
  if Float.eq_dec n (Float.of_int (Int.repr 2))
  then (Oaddf, r :: r :: nil)
  else (Omulf, r1 :: r2 :: nil).

Definition make_mulfsimm (n: float32) (r r1 r2: reg) :=
  if Float32.eq_dec n (Float32.of_int (Int.repr 2))
  then (Oaddfs, r :: r :: nil)
  else (Omulfs, r1 :: r2 :: nil).

Definition make_cast8signed (r: reg) (a: aval) :=
  if vincl a (Sgn Ptop 8) then (Omove, r :: nil) else (Ocast8signed, r :: nil).
Definition make_cast16signed (r: reg) (a: aval) :=
  if vincl a (Sgn Ptop 16) then (Omove, r :: nil) else (Ocast16signed, r :: nil).

(** Original definition:
<<
Nondetfunction op_strength_reduction 
              (op: operation) (args: list reg) (vl: list aval) :=
  match op, args, vl with
  | Ocast8signed, r1 :: nil, v1 :: nil => make_cast8signed r1 v1
  | Ocast16signed, r1 :: nil, v1 :: nil => make_cast16signed r1 v1
  | Oadd, r1 :: r2 :: nil, I n1 :: v2 :: nil => make_addimm n1 r2
  | Oadd, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_addimm n2 r1
  | Osub, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_addimm (Int.neg n2) r1
  | Omul, r1 :: r2 :: nil, I n1 :: v2 :: nil => make_mulimm n1 r2 r1
  | Omul, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_mulimm n2 r1 r2
  | Odiv, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_divimm n2 r1 r2
  | Odivu, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_divuimm n2 r1 r2
  | Omodu, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_moduimm n2 r1 r2
  | Oand, r1 :: r2 :: nil, I n1 :: v2 :: nil => make_andimm n1 r2 v2
  | Oand, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_andimm n2 r1 v1
  | Oandimm n, r1 :: nil, v1 :: nil => make_andimm n r1 v1
  | Oor, r1 :: r2 :: nil, I n1 :: v2 :: nil => make_orimm n1 r2
  | Oor, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_orimm n2 r1
  | Oxor, r1 :: r2 :: nil, I n1 :: v2 :: nil => make_xorimm n1 r2
  | Oxor, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_xorimm n2 r1
  | Oshl, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shlimm n2 r1 r2
  | Oshr, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shrimm n2 r1 r2
  | Oshru, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shruimm n2 r1 r2
  | Oaddl, r1 :: r2 :: nil, L n1 :: v2 :: nil => make_addlimm n1 r2
  | Oaddl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_addlimm n2 r1
  | Osubl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_addlimm (Int64.neg n2) r1
  | Omull, r1 :: r2 :: nil, L n1 :: v2 :: nil => make_mullimm n1 r2 r1
  | Omull, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_mullimm n2 r1 r2
  | Odivl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_divlimm n2 r1 r2
  | Odivlu, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_divluimm n2 r1 r2
  | Omodlu, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_modluimm n2 r1 r2
  | Oandl, r1 :: r2 :: nil, L n1 :: v2 :: nil => make_andlimm n1 r2 v2
  | Oandl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_andlimm n2 r1 v1
  | Oandlimm n, r1 :: nil, v1 :: nil => make_andlimm n r1 v1
  | Oorl, r1 :: r2 :: nil, L n1 :: v2 :: nil => make_orlimm n1 r2
  | Oorl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_orlimm n2 r1
  | Oxorl, r1 :: r2 :: nil, L n1 :: v2 :: nil => make_xorlimm n1 r2
  | Oxorl, r1 :: r2 :: nil, v1 :: L n2 :: nil => make_xorlimm n2 r1
  | Oshll, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shllimm n2 r1 r2
  | Oshrl, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shrlimm n2 r1 r2
  | Oshrlu, r1 :: r2 :: nil, v1 :: I n2 :: nil => make_shrluimm n2 r1 r2
  | Ocmp c, args, vl => make_cmp c args vl
  | Omulf, r1 :: r2 :: nil, v1 :: F n2 :: nil => make_mulfimm n2 r1 r1 r2
  | Omulf, r1 :: r2 :: nil, F n1 :: v2 :: nil => make_mulfimm n1 r2 r1 r2
  | Omulfs, r1 :: r2 :: nil, v1 :: FS n2 :: nil => make_mulfsimm n2 r1 r1 r2
  | Omulfs, r1 :: r2 :: nil, FS n1 :: v2 :: nil => make_mulfsimm n1 r2 r1 r2
  | _, _, _ => (op, args)
  end.
>>
*)

Inductive op_strength_reduction_cases: forall (op: operation) (args: list reg) (vl: list aval), Type :=
  | op_strength_reduction_case1: forall r1 v1, op_strength_reduction_cases (Ocast8signed) (r1 :: nil) (v1 :: nil)
  | op_strength_reduction_case2: forall r1 v1, op_strength_reduction_cases (Ocast16signed) (r1 :: nil) (v1 :: nil)
  | op_strength_reduction_case3: forall r1 r2 n1 v2, op_strength_reduction_cases (Oadd) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | op_strength_reduction_case4: forall r1 r2 v1 n2, op_strength_reduction_cases (Oadd) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case5: forall r1 r2 v1 n2, op_strength_reduction_cases (Osub) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case6: forall r1 r2 n1 v2, op_strength_reduction_cases (Omul) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | op_strength_reduction_case7: forall r1 r2 v1 n2, op_strength_reduction_cases (Omul) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case8: forall r1 r2 v1 n2, op_strength_reduction_cases (Odiv) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case9: forall r1 r2 v1 n2, op_strength_reduction_cases (Odivu) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case10: forall r1 r2 v1 n2, op_strength_reduction_cases (Omodu) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case11: forall r1 r2 n1 v2, op_strength_reduction_cases (Oand) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | op_strength_reduction_case12: forall r1 r2 v1 n2, op_strength_reduction_cases (Oand) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case13: forall n r1 v1, op_strength_reduction_cases (Oandimm n) (r1 :: nil) (v1 :: nil)
  | op_strength_reduction_case14: forall r1 r2 n1 v2, op_strength_reduction_cases (Oor) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | op_strength_reduction_case15: forall r1 r2 v1 n2, op_strength_reduction_cases (Oor) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case16: forall r1 r2 n1 v2, op_strength_reduction_cases (Oxor) (r1 :: r2 :: nil) (I n1 :: v2 :: nil)
  | op_strength_reduction_case17: forall r1 r2 v1 n2, op_strength_reduction_cases (Oxor) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case18: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshl) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case19: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshr) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case20: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshru) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case21: forall r1 r2 n1 v2, op_strength_reduction_cases (Oaddl) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | op_strength_reduction_case22: forall r1 r2 v1 n2, op_strength_reduction_cases (Oaddl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case23: forall r1 r2 v1 n2, op_strength_reduction_cases (Osubl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case24: forall r1 r2 n1 v2, op_strength_reduction_cases (Omull) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | op_strength_reduction_case25: forall r1 r2 v1 n2, op_strength_reduction_cases (Omull) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case26: forall r1 r2 v1 n2, op_strength_reduction_cases (Odivl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case27: forall r1 r2 v1 n2, op_strength_reduction_cases (Odivlu) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case28: forall r1 r2 v1 n2, op_strength_reduction_cases (Omodlu) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case29: forall r1 r2 n1 v2, op_strength_reduction_cases (Oandl) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | op_strength_reduction_case30: forall r1 r2 v1 n2, op_strength_reduction_cases (Oandl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case31: forall n r1 v1, op_strength_reduction_cases (Oandlimm n) (r1 :: nil) (v1 :: nil)
  | op_strength_reduction_case32: forall r1 r2 n1 v2, op_strength_reduction_cases (Oorl) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | op_strength_reduction_case33: forall r1 r2 v1 n2, op_strength_reduction_cases (Oorl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case34: forall r1 r2 n1 v2, op_strength_reduction_cases (Oxorl) (r1 :: r2 :: nil) (L n1 :: v2 :: nil)
  | op_strength_reduction_case35: forall r1 r2 v1 n2, op_strength_reduction_cases (Oxorl) (r1 :: r2 :: nil) (v1 :: L n2 :: nil)
  | op_strength_reduction_case36: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshll) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case37: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshrl) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case38: forall r1 r2 v1 n2, op_strength_reduction_cases (Oshrlu) (r1 :: r2 :: nil) (v1 :: I n2 :: nil)
  | op_strength_reduction_case39: forall c args vl, op_strength_reduction_cases (Ocmp c) (args) (vl)
  | op_strength_reduction_case40: forall r1 r2 v1 n2, op_strength_reduction_cases (Omulf) (r1 :: r2 :: nil) (v1 :: F n2 :: nil)
  | op_strength_reduction_case41: forall r1 r2 n1 v2, op_strength_reduction_cases (Omulf) (r1 :: r2 :: nil) (F n1 :: v2 :: nil)
  | op_strength_reduction_case42: forall r1 r2 v1 n2, op_strength_reduction_cases (Omulfs) (r1 :: r2 :: nil) (v1 :: FS n2 :: nil)
  | op_strength_reduction_case43: forall r1 r2 n1 v2, op_strength_reduction_cases (Omulfs) (r1 :: r2 :: nil) (FS n1 :: v2 :: nil)
  | op_strength_reduction_default: forall (op: operation) (args: list reg) (vl: list aval), op_strength_reduction_cases op args vl.

Definition op_strength_reduction_match (op: operation) (args: list reg) (vl: list aval) :=
  match op as zz1, args as zz2, vl as zz3 return op_strength_reduction_cases zz1 zz2 zz3 with
  | Ocast8signed, r1 :: nil, v1 :: nil => op_strength_reduction_case1 r1 v1
  | Ocast16signed, r1 :: nil, v1 :: nil => op_strength_reduction_case2 r1 v1
  | Oadd, r1 :: r2 :: nil, I n1 :: v2 :: nil => op_strength_reduction_case3 r1 r2 n1 v2
  | Oadd, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case4 r1 r2 v1 n2
  | Osub, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case5 r1 r2 v1 n2
  | Omul, r1 :: r2 :: nil, I n1 :: v2 :: nil => op_strength_reduction_case6 r1 r2 n1 v2
  | Omul, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case7 r1 r2 v1 n2
  | Odiv, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case8 r1 r2 v1 n2
  | Odivu, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case9 r1 r2 v1 n2
  | Omodu, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case10 r1 r2 v1 n2
  | Oand, r1 :: r2 :: nil, I n1 :: v2 :: nil => op_strength_reduction_case11 r1 r2 n1 v2
  | Oand, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case12 r1 r2 v1 n2
  | Oandimm n, r1 :: nil, v1 :: nil => op_strength_reduction_case13 n r1 v1
  | Oor, r1 :: r2 :: nil, I n1 :: v2 :: nil => op_strength_reduction_case14 r1 r2 n1 v2
  | Oor, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case15 r1 r2 v1 n2
  | Oxor, r1 :: r2 :: nil, I n1 :: v2 :: nil => op_strength_reduction_case16 r1 r2 n1 v2
  | Oxor, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case17 r1 r2 v1 n2
  | Oshl, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case18 r1 r2 v1 n2
  | Oshr, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case19 r1 r2 v1 n2
  | Oshru, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case20 r1 r2 v1 n2
  | Oaddl, r1 :: r2 :: nil, L n1 :: v2 :: nil => op_strength_reduction_case21 r1 r2 n1 v2
  | Oaddl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case22 r1 r2 v1 n2
  | Osubl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case23 r1 r2 v1 n2
  | Omull, r1 :: r2 :: nil, L n1 :: v2 :: nil => op_strength_reduction_case24 r1 r2 n1 v2
  | Omull, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case25 r1 r2 v1 n2
  | Odivl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case26 r1 r2 v1 n2
  | Odivlu, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case27 r1 r2 v1 n2
  | Omodlu, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case28 r1 r2 v1 n2
  | Oandl, r1 :: r2 :: nil, L n1 :: v2 :: nil => op_strength_reduction_case29 r1 r2 n1 v2
  | Oandl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case30 r1 r2 v1 n2
  | Oandlimm n, r1 :: nil, v1 :: nil => op_strength_reduction_case31 n r1 v1
  | Oorl, r1 :: r2 :: nil, L n1 :: v2 :: nil => op_strength_reduction_case32 r1 r2 n1 v2
  | Oorl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case33 r1 r2 v1 n2
  | Oxorl, r1 :: r2 :: nil, L n1 :: v2 :: nil => op_strength_reduction_case34 r1 r2 n1 v2
  | Oxorl, r1 :: r2 :: nil, v1 :: L n2 :: nil => op_strength_reduction_case35 r1 r2 v1 n2
  | Oshll, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case36 r1 r2 v1 n2
  | Oshrl, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case37 r1 r2 v1 n2
  | Oshrlu, r1 :: r2 :: nil, v1 :: I n2 :: nil => op_strength_reduction_case38 r1 r2 v1 n2
  | Ocmp c, args, vl => op_strength_reduction_case39 c args vl
  | Omulf, r1 :: r2 :: nil, v1 :: F n2 :: nil => op_strength_reduction_case40 r1 r2 v1 n2
  | Omulf, r1 :: r2 :: nil, F n1 :: v2 :: nil => op_strength_reduction_case41 r1 r2 n1 v2
  | Omulfs, r1 :: r2 :: nil, v1 :: FS n2 :: nil => op_strength_reduction_case42 r1 r2 v1 n2
  | Omulfs, r1 :: r2 :: nil, FS n1 :: v2 :: nil => op_strength_reduction_case43 r1 r2 n1 v2
  | op, args, vl => op_strength_reduction_default op args vl
  end.

Definition op_strength_reduction (op: operation) (args: list reg) (vl: list aval) :=
  match op_strength_reduction_match op args vl with
  | op_strength_reduction_case1 r1 v1 => (* Ocast8signed, r1 :: nil, v1 :: nil *) 
      make_cast8signed r1 v1
  | op_strength_reduction_case2 r1 v1 => (* Ocast16signed, r1 :: nil, v1 :: nil *) 
      make_cast16signed r1 v1
  | op_strength_reduction_case3 r1 r2 n1 v2 => (* Oadd, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      make_addimm n1 r2
  | op_strength_reduction_case4 r1 r2 v1 n2 => (* Oadd, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_addimm n2 r1
  | op_strength_reduction_case5 r1 r2 v1 n2 => (* Osub, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_addimm (Int.neg n2) r1
  | op_strength_reduction_case6 r1 r2 n1 v2 => (* Omul, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      make_mulimm n1 r2 r1
  | op_strength_reduction_case7 r1 r2 v1 n2 => (* Omul, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_mulimm n2 r1 r2
  | op_strength_reduction_case8 r1 r2 v1 n2 => (* Odiv, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_divimm n2 r1 r2
  | op_strength_reduction_case9 r1 r2 v1 n2 => (* Odivu, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_divuimm n2 r1 r2
  | op_strength_reduction_case10 r1 r2 v1 n2 => (* Omodu, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_moduimm n2 r1 r2
  | op_strength_reduction_case11 r1 r2 n1 v2 => (* Oand, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      make_andimm n1 r2 v2
  | op_strength_reduction_case12 r1 r2 v1 n2 => (* Oand, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_andimm n2 r1 v1
  | op_strength_reduction_case13 n r1 v1 => (* Oandimm n, r1 :: nil, v1 :: nil *) 
      make_andimm n r1 v1
  | op_strength_reduction_case14 r1 r2 n1 v2 => (* Oor, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      make_orimm n1 r2
  | op_strength_reduction_case15 r1 r2 v1 n2 => (* Oor, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_orimm n2 r1
  | op_strength_reduction_case16 r1 r2 n1 v2 => (* Oxor, r1 :: r2 :: nil, I n1 :: v2 :: nil *) 
      make_xorimm n1 r2
  | op_strength_reduction_case17 r1 r2 v1 n2 => (* Oxor, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_xorimm n2 r1
  | op_strength_reduction_case18 r1 r2 v1 n2 => (* Oshl, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shlimm n2 r1 r2
  | op_strength_reduction_case19 r1 r2 v1 n2 => (* Oshr, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shrimm n2 r1 r2
  | op_strength_reduction_case20 r1 r2 v1 n2 => (* Oshru, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shruimm n2 r1 r2
  | op_strength_reduction_case21 r1 r2 n1 v2 => (* Oaddl, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      make_addlimm n1 r2
  | op_strength_reduction_case22 r1 r2 v1 n2 => (* Oaddl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_addlimm n2 r1
  | op_strength_reduction_case23 r1 r2 v1 n2 => (* Osubl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_addlimm (Int64.neg n2) r1
  | op_strength_reduction_case24 r1 r2 n1 v2 => (* Omull, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      make_mullimm n1 r2 r1
  | op_strength_reduction_case25 r1 r2 v1 n2 => (* Omull, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_mullimm n2 r1 r2
  | op_strength_reduction_case26 r1 r2 v1 n2 => (* Odivl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_divlimm n2 r1 r2
  | op_strength_reduction_case27 r1 r2 v1 n2 => (* Odivlu, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_divluimm n2 r1 r2
  | op_strength_reduction_case28 r1 r2 v1 n2 => (* Omodlu, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_modluimm n2 r1 r2
  | op_strength_reduction_case29 r1 r2 n1 v2 => (* Oandl, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      make_andlimm n1 r2 v2
  | op_strength_reduction_case30 r1 r2 v1 n2 => (* Oandl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_andlimm n2 r1 v1
  | op_strength_reduction_case31 n r1 v1 => (* Oandlimm n, r1 :: nil, v1 :: nil *) 
      make_andlimm n r1 v1
  | op_strength_reduction_case32 r1 r2 n1 v2 => (* Oorl, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      make_orlimm n1 r2
  | op_strength_reduction_case33 r1 r2 v1 n2 => (* Oorl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_orlimm n2 r1
  | op_strength_reduction_case34 r1 r2 n1 v2 => (* Oxorl, r1 :: r2 :: nil, L n1 :: v2 :: nil *) 
      make_xorlimm n1 r2
  | op_strength_reduction_case35 r1 r2 v1 n2 => (* Oxorl, r1 :: r2 :: nil, v1 :: L n2 :: nil *) 
      make_xorlimm n2 r1
  | op_strength_reduction_case36 r1 r2 v1 n2 => (* Oshll, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shllimm n2 r1 r2
  | op_strength_reduction_case37 r1 r2 v1 n2 => (* Oshrl, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shrlimm n2 r1 r2
  | op_strength_reduction_case38 r1 r2 v1 n2 => (* Oshrlu, r1 :: r2 :: nil, v1 :: I n2 :: nil *) 
      make_shrluimm n2 r1 r2
  | op_strength_reduction_case39 c args vl => (* Ocmp c, args, vl *) 
      make_cmp c args vl
  | op_strength_reduction_case40 r1 r2 v1 n2 => (* Omulf, r1 :: r2 :: nil, v1 :: F n2 :: nil *) 
      make_mulfimm n2 r1 r1 r2
  | op_strength_reduction_case41 r1 r2 n1 v2 => (* Omulf, r1 :: r2 :: nil, F n1 :: v2 :: nil *) 
      make_mulfimm n1 r2 r1 r2
  | op_strength_reduction_case42 r1 r2 v1 n2 => (* Omulfs, r1 :: r2 :: nil, v1 :: FS n2 :: nil *) 
      make_mulfsimm n2 r1 r1 r2
  | op_strength_reduction_case43 r1 r2 n1 v2 => (* Omulfs, r1 :: r2 :: nil, FS n1 :: v2 :: nil *) 
      make_mulfsimm n1 r2 r1 r2
  | op_strength_reduction_default op args vl =>
      (op, args)
  end.


(** Original definition:
<<
Nondetfunction addr_strength_reduction
                (addr: addressing) (args: list reg) (vl: list aval) :=
  match addr, args, vl with
  | Aindexed n, r1 :: nil, Ptr(Gl symb n1) :: nil =>
      if Archi.pic_code tt
      then (addr, args)
      else (Aglobal symb (Ptrofs.add n1 n), nil)
  | Aindexed n, r1 :: nil, Ptr(Stk n1) :: nil =>
      (Ainstack (Ptrofs.add n1 n), nil)
  | _, _, _ =>
      (addr, args)
  end.
>>
*)

Inductive addr_strength_reduction_cases: forall (addr: addressing) (args: list reg) (vl: list aval), Type :=
  | addr_strength_reduction_case1: forall n r1 symb n1, addr_strength_reduction_cases (Aindexed n) (r1 :: nil) (Ptr(Gl symb n1) :: nil)
  | addr_strength_reduction_case2: forall n r1 n1, addr_strength_reduction_cases (Aindexed n) (r1 :: nil) (Ptr(Stk n1) :: nil)
  | addr_strength_reduction_default: forall (addr: addressing) (args: list reg) (vl: list aval), addr_strength_reduction_cases addr args vl.

Definition addr_strength_reduction_match (addr: addressing) (args: list reg) (vl: list aval) :=
  match addr as zz1, args as zz2, vl as zz3 return addr_strength_reduction_cases zz1 zz2 zz3 with
  | Aindexed n, r1 :: nil, Ptr(Gl symb n1) :: nil => addr_strength_reduction_case1 n r1 symb n1
  | Aindexed n, r1 :: nil, Ptr(Stk n1) :: nil => addr_strength_reduction_case2 n r1 n1
  | addr, args, vl => addr_strength_reduction_default addr args vl
  end.

Definition addr_strength_reduction (addr: addressing) (args: list reg) (vl: list aval) :=
  match addr_strength_reduction_match addr args vl with
  | addr_strength_reduction_case1 n r1 symb n1 => (* Aindexed n, r1 :: nil, Ptr(Gl symb n1) :: nil *) 
      if Archi.pic_code tt then (addr, args) else (Aglobal symb (Ptrofs.add n1 n), nil)
  | addr_strength_reduction_case2 n r1 n1 => (* Aindexed n, r1 :: nil, Ptr(Stk n1) :: nil *) 
      (Ainstack (Ptrofs.add n1 n), nil)
  | addr_strength_reduction_default addr args vl =>
      (addr, args)
  end.


