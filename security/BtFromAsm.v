Require Import String.
Require Import Coqlib Maps Errors Integers Values Memory Globalenvs.
Require Import AST Linking Smallstep Events Behaviors.

Require Import Split.

Require Import riscV.Asm.
Require Import BtInfoAsm BtBasics.


Section WELLFORMED.

  (* Variant sf_cont_type : Type := | sf_cont: block -> signature -> sf_cont_type. *)
  Variant sf_cont_type : Type := | sf_cont: block -> sf_cont_type.
  Definition sf_conts := list sf_cont_type.

  (* wf_sem: from asm, wf_st: proof invariant for Clight states *)
  Inductive info_asm_sem_wf (ge: Asm.genv) : block -> mem -> sf_conts -> itrace -> Prop :=
  | info_asm_sem_wf_base
      cur m1 sf
    :
    info_asm_sem_wf ge cur m1 sf nil
  | info_asm_sem_wf_intra_call_external
      cur m1 sf ev ik tl
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      ef res m2
      (EXTEV: external_call_event_match_common ef ev ge cp m1 res m2)
      fb
      (IK: ik = info_external fb (ef_sig ef))
      fid
      (INV: Genv.invert_symbol ge fb = Some fid)
      (ISEXT: Genv.find_funct_ptr ge fb = Some (AST.External ef))
      (ALLOWED: Genv.allowed_call ge cp (Vptr fb Ptrofs.zero))
      (INTRA: Genv.type_of_call ge cp (Genv.find_comp ge (Vptr fb Ptrofs.zero)) <> Genv.CrossCompartmentCall)
      (NEXT: info_asm_sem_wf ge cur m2 sf tl)
    :
    info_asm_sem_wf ge cur m1 sf ((ev, ik) :: tl)
  | info_asm_sem_wf_builtin
      cur m1 sf ev ik tl
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      ef res m2
      (EXT: external_call_event_match_common ef ev ge cp m1 res m2)
      (IK: ik = info_builtin ef)
      (NEXT: info_asm_sem_wf ge cur m2 sf tl)
    :
    info_asm_sem_wf ge cur m1 sf ((ev, ik) :: tl)
  | info_asm_sem_wf_cross_call_internal
      cur m1 sf ev ik tl
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      cp' fid evargs
      (EV: ev = Event_call cp cp' fid evargs)
      sg
      (IK: ik = info_call not_cross_ext sg)
      b
      (FINDB: Genv.find_symbol ge fid = Some b)
      fd
      (FINDF: Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd)
      (CP': cp' = comp_of fd)
      (CROSS: Genv.type_of_call ge cp cp' = Genv.CrossCompartmentCall)
      args
      (NPTR: Forall not_ptr args)
      (ALLOW: Genv.allowed_cross_call ge cp (Vptr b Ptrofs.zero))
      (ESM: eventval_list_match ge evargs (sig_args sg) args)
      callee_f
      (INTERNAL: fd = AST.Internal callee_f)
      (* TODO: separate this; 
           might be better to upgrade Asm semantics to actually refer to its fn_sig.
           Note that it's not possible to recover Clight fun type data from trace since
           there can be conflicts, since Asm semantics actually allows non-fixed sigs.
       *)
      (SIG: sg = Asm.fn_sig callee_f)
      (* internal call: memory changes in Clight-side, so need inj-relation *)
      (NEXT: info_asm_sem_wf ge b m1 ((sf_cont cur) :: sf) tl)
    :
    info_asm_sem_wf ge cur m1 sf ((ev, ik) :: tl)
  | info_asm_sem_wf_cross_return_internal
      cur m1 ev ik tl
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      cp_c evres
      (EV: ev = Event_return cp_c cp evres)
      sg
      (IK: ik = info_return sg)
      cur_f
      (INTERNAL: Genv.find_funct_ptr ge cur = Some (AST.Internal cur_f))
      (* TODO: separate this *)
      (SIG: sg = Asm.fn_sig cur_f)
      (CROSS: Genv.type_of_call ge cp_c cp = Genv.CrossCompartmentCall)
      res
      (EVM: eventval_match ge evres (proj_rettype (sig_res sg)) res)
      (NPTR: not_ptr res)
      b_c sf_tl
      (CPC: cp_c = Genv.find_comp ge (Vptr b_c Ptrofs.zero))
      (* internal return: memory changes in Clight-side, so need inj-relation *)
      (NEXT: info_asm_sem_wf ge b_c m1 sf_tl tl)
    :
    info_asm_sem_wf ge cur m1 ((sf_cont b_c) :: sf_tl) ((ev, ik) :: tl)
  | info_asm_sem_wf_cross_call_external1
      (* early cut at call event *)
      cur m1 sf ev ik
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      cp' fid evargs
      (EV: ev = Event_call cp cp' fid evargs)
      sg
      (IK: ik = info_call is_cross_ext sg)
      b
      (FINDB: Genv.find_symbol ge fid = Some b)
      fd
      (FINDF: Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd)
      (CP': cp' = comp_of fd)
      (CROSS: Genv.type_of_call ge cp cp' = Genv.CrossCompartmentCall)
      args
      (NPTR: Forall not_ptr args)
      (ALLOW: Genv.allowed_cross_call ge cp (Vptr b Ptrofs.zero))
      (ESM: eventval_list_match ge evargs (sig_args sg) args)
      ef
      (EXTERNAL: fd = AST.External ef)
      (* TODO: separate this *)
      (SIG: sg = ef_sig ef)
    :
    info_asm_sem_wf ge cur m1 sf ((ev, ik) :: nil)
  | info_asm_sem_wf_cross_call_external2
      (* early cut at call-ext_call event *)
      cur m1 sf ev1 ik1
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      cp' fid evargs
      (EV: ev1 = Event_call cp cp' fid evargs)
      sg
      (IK: ik1 = info_call is_cross_ext sg)
      b
      (FINDB: Genv.find_symbol ge fid = Some b)
      fd
      (FINDF: Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd)
      (CP': cp' = comp_of fd)
      (CROSS: Genv.type_of_call ge cp cp' = Genv.CrossCompartmentCall)
      args
      (NPTR: Forall not_ptr args)
      (ALLOW: Genv.allowed_cross_call ge cp (Vptr b Ptrofs.zero))
      (ESM: eventval_list_match ge evargs (sig_args sg) args)
      ef
      (EXTERNAL: fd = AST.External ef)
      (* TODO: separate this *)
      (SIG: sg = ef_sig ef)
      (* external call part *)
      tr vres m2
      (EXTCALL: external_call ef ge cp args m1 tr vres m2)
      itr
      (INFO: itr = map (fun e => (e, info_external b (ef_sig ef))) tr)
    :
    info_asm_sem_wf ge cur m1 sf ((ev1, ik1) :: itr)
  | info_asm_sem_wf_cross_call_external3
      (* full call-ext_call-return event *)
      cur m1 sf ev1 ik1
      cp
      (CURCP: cp = Genv.find_comp ge (Vptr cur Ptrofs.zero))
      cp' fid evargs
      (EV: ev1 = Event_call cp cp' fid evargs)
      sg
      (IK: ik1 = info_call is_cross_ext sg)
      b
      (FINDB: Genv.find_symbol ge fid = Some b)
      fd
      (FINDF: Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd)
      (CP': cp' = comp_of fd)
      (CROSS: Genv.type_of_call ge cp cp' = Genv.CrossCompartmentCall)
      args
      (NPTR: Forall not_ptr args)
      (ALLOW: Genv.allowed_cross_call ge cp (Vptr b Ptrofs.zero))
      (ESM: eventval_list_match ge evargs (sig_args sg) args)
      ef
      (EXTERNAL: fd = AST.External ef)
      (* TODO: separate this *)
      (SIG: sg = ef_sig ef)
      (* external call part *)
      tr vres m2
      (EXTCALL: external_call ef ge cp args m1 tr vres m2)
      itr
      (INFO: itr = map (fun e => (e, info_external b (ef_sig ef))) tr)
      (* return part *)
      ev3 ik3 tl
      evres
      (EV: ev3 = Event_return cp cp' evres)
      sg
      (IK: ik3 = info_return sg)
      (EVM: eventval_match ge evres (proj_rettype (sig_res sg)) vres)
      (NPTR: not_ptr vres)
      (NEXT: info_asm_sem_wf ge cur m2 sf tl)
    :
    info_asm_sem_wf ge cur m1 sf ((ev1, ik1) :: (itr ++ ((ev3, ik3) :: tl)))
  .

  (* TODO *)
  (* we need a more precise invariant for the proof; counters, mem_inj, env, cont, state *)

End WELLFORMED.

Section MATCH.

  Variant match_stack_type : (sf_cont_type) -> (stackframe) -> Prop :=
    | match_stack_type_intro
        b cp sg v ofs
      :
      match_stack_type (sf_cont b) (Stackframe b cp sg v ofs).

  Definition match_stack (sf: sf_conts) (st: stack) := Forall2 match_stack_type sf st.

  Definition match_block (ge: Asm.genv) (cur: block) (b: block) : Prop :=
    Genv.find_comp ge (Vptr cur Ptrofs.zero) = Genv.find_comp ge (Vptr b Ptrofs.zero).

  Definition meminj_ge {F V} (ge: Genv.t F V): meminj :=
    fun b => match Genv.invert_symbol ge b with
          | Some id => match Genv.find_symbol ge id with
                      | Some b' => Some (b', 0)
                      | None => None
                      end
          | None => None
          end.

  Definition match_mem (ge: Asm.genv) (m_ir m_asm: mem): Prop := Mem.inject (meminj_ge ge) m_asm m_ir.

(* Definition external_call_mem_inject_gen ef := ec_mem_inject (external_call_spec ef). *)

(* external_call_mem_inject: *)
(*   forall (ef : external_function) [F V : Type] [ge : Genv.t F V] (c : compartment) [vargs : list val] [m1 : mem] (t : trace) (vres : val) (m2 : mem) [f : block -> option (block * Z)]  *)
(*     [m1' : mem] [vargs' : list val], *)
(*   meminj_preserves_globals ge f -> *)
(*   external_call ef ge c vargs m1 t vres m2 -> *)
(*   Mem.inject f m1 m1' -> *)
(*   Val.inject_list f vargs vargs' -> *)
(*   exists (f' : meminj) (vres' : val) (m2' : mem), *)
(*     external_call ef ge c vargs' m1' t vres' m2' /\ *)
(*     Val.inject f' vres vres' /\ Mem.inject f' m2 m2' /\ Mem.unchanged_on (loc_unmapped f) m1 m2 /\ Mem.unchanged_on (loc_out_of_reach f m1) m1' m2' /\ inject_incr f f' /\ inject_separated f f' m1 m1' *)

(* meminj_preserves_globals: forall [F V : Type], Genv.t F V -> (block -> option (block * Z)) -> Prop *)
(* Separation.globalenv_preserved: forall {F V : Type}, Genv.t F V -> meminj -> block -> Prop *)
(* Genv.same_symbols: forall [F V : Type], meminj -> Genv.t F V -> Prop *)
(*       Genv.init_mem p = Some m0 -> *)
(* Variable f: block -> option (block * Z). *)
(* Variable ge1 ge2: Senv.t. *)

(* Definition symbols_inject : Prop := *)
(*    (forall id, Senv.public_symbol ge2 id = Senv.public_symbol ge1 id) *)
(* /\ (forall id b1 b2 delta, *)
(*      f b1 = Some(b2, delta) -> Senv.find_symbol ge1 id = Some b1 -> *)
(*      delta = 0 /\ Senv.find_symbol ge2 id = Some b2) *)
(* /\ (forall id b1, *)
(*      Senv.public_symbol ge1 id = true -> Senv.find_symbol ge1 id = Some b1 -> *)
(*      exists b2, f b1 = Some(b2, 0) /\ Senv.find_symbol ge2 id = Some b2) *)
(* /\ (forall b1 b2 delta, *)
(*      f b1 = Some(b2, delta) -> *)
(*      Senv.block_is_volatile ge2 b2 = Senv.block_is_volatile ge1 b1). *)
(* Senv.equiv =  *)
(* fun se1 se2 : Senv.t => *)
(* (forall id : ident, Senv.find_symbol se2 id = Senv.find_symbol se1 id) /\ *)
(* (forall id : ident, Senv.public_symbol se2 id = Senv.public_symbol se1 id) /\ (forall b : block, Senv.block_is_volatile se2 b = Senv.block_is_volatile se1 b) *)
(*      : Senv.t -> Senv.t -> Prop *)

End MATCH.

Section PROOF.

  (* If main is External, treat it in a different case - the trace can start with Event_syscall, without a preceding Event_call *)
  Lemma from_info_asm_sem_wf
        ge cp s s' it
        (STAR: istar (asm_istep cp) ge s it s')
        st rs m
        (STATE: s = State st rs m)
        b ofs f
        (RSPC: rs PC = Vptr b ofs)
        (INT: Genv.find_funct_ptr ge b = Some (Internal f))
        cur m_ir k
        (MATCHB: match_block ge cur b)
        (MATCHM: match_mem ge m_ir m)
        (MATCHS: match_stack k st)
    :
    info_asm_sem_wf ge cur m_ir k it.
  Proof.


    (* TODO *)

  Inductive info_asm_sem_wf (ge: Asm.genv) : block -> mem -> sf_conts -> itrace -> Prop :=
  Definition state_has_trace_informative (L: Smallstep.semantics) (s: state L) (step: istep L) (t: itrace): Prop :=
    (exists s', (istar step (globalenv L)) s t s').
  Variant semantics_has_initial_trace_informative (L: Smallstep.semantics) (step: istep L) (t: itrace) : Prop :=
    | semantics_info_runs :
      forall s, (initial_state L s) -> (state_has_trace_informative L s step t) -> semantics_has_initial_trace_informative _ _ t
    | semantics_info_goes_initially_wrong : (forall s : state L, ~ initial_state L s) -> (t = nil) -> semantics_has_initial_trace_informative _ _ t.
  Definition asm_has_initial_trace_informative (p: Asm.program) (t: itrace) :=
    semantics_has_initial_trace_informative (semantics p) (asm_istep (comp_of_main p)) t.

Mem.alloc_left_unmapped_inject:
  forall (f : meminj) (m1 m2 : mem) (c : compartment) (lo hi : Z) (m1' : Mem.mem') (b1 : block),
  Mem.inject f m1 m2 -> Mem.alloc m1 c lo hi = (m1', b1) -> exists f' : meminj, Mem.inject f' m1' m2 /\ inject_incr f f' /\ f' b1 = None /\ (forall b : block, b <> b1 -> f' b = f b)

Mem.free_left_inject: forall (f : meminj) (m1 m2 : mem) (b : block) (lo hi : Z) (cp : compartment) (m1' : mem), Mem.inject f m1 m2 -> Mem.free m1 b lo hi cp = Some m1' -> Mem.inject f m1' m2

Mem.free_right_inject:
  forall (f : meminj) (m1 m2 : mem) (b : block) (lo hi : Z) (cp : compartment) (m2' : mem),
  Mem.inject f m1 m2 ->
  Mem.free m2 b lo hi cp = Some m2' ->
  (forall (b1 : block) (delta ofs : Z) (k : perm_kind) (p : permission), f b1 = Some (b, delta) -> Mem.perm m1 b1 ofs k p -> lo <= ofs + delta < hi -> False) -> Mem.inject f m1 m2'

End PROOF.
