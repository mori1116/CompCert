Require Import String.
Require Import Coqlib Maps Errors Integers Values Memory Globalenvs.
Require Import AST Linking Smallstep Events Behaviors.

Require Import Split.

Require Import riscV.Asm.
Require Import Ctypes Clight.



Section AUX.

  (* f doesn't map anything to [b], e.g. the counter and function parameters *)
  Definition meminj_notmap (f: meminj) b := forall b0 ofs0, ~ (f b0 = Some (b, ofs0)).

  Lemma loc_out_of_reach_unchanged_on_content:
    forall f b ofs m1 m1' m2'
      (NOTMAP: meminj_notmap f b),
      Mem.perm m1' b ofs Cur Readable ->
      (* Mem.perm m1' b ofs Cur Writable -> *)
      Mem.unchanged_on (loc_out_of_reach f m1) m1' m2' ->
      ZMap.get ofs (Mem.mem_contents m2') !! b = ZMap.get ofs (Mem.mem_contents m1') !! b.
  Proof.
    intros. destruct H0. apply unchanged_on_contents; eauto.
    unfold loc_out_of_reach. intros. now specialize (NOTMAP _ _ H0).
    (* eapply Mem.perm_implies; eauto. constructor. *)
  Qed.

  Lemma loc_out_of_reach_unchanged_on_perm:
    forall f b ofs m1 m1' m2' k p
      (NOTMAP: meminj_notmap f b),
      Mem.perm m1' b ofs k p ->
      Mem.unchanged_on (loc_out_of_reach f m1) m1' m2' ->
      Mem.perm m2' b ofs k p.
  Proof.
    intros. destruct H0. apply unchanged_on_perm; eauto.
    unfold loc_out_of_reach. intros. now specialize (NOTMAP _ _ H0).
    eapply Mem.perm_valid_block; eauto.
  Qed.

  (* Record unchanged_on (P : block -> Z -> Prop) (m_before m_after : mem) : Prop := mk_unchanged_on *)
  (* { unchanged_on_nextblock : Ple (Mem.nextblock m_before) (Mem.nextblock m_after); *)
  (*   unchanged_on_perm : forall (b : block) (ofs : Z) (k : perm_kind) (p : permission), P b ofs -> Mem.valid_block m_before b -> Mem.perm m_before b ofs k p <-> Mem.perm m_after b ofs k p; *)
  (*   unchanged_on_contents : forall (b : block) (ofs : Z), P b ofs -> Mem.perm m_before b ofs Cur Readable -> ZMap.get ofs (Mem.mem_contents m_after) !! b = ZMap.get ofs (Mem.mem_contents m_before) !! b; *)
  (*   unchanged_on_own : forall (b : block) (cp : option compartment), Mem.valid_block m_before b -> Mem.can_access_block m_before b cp <-> Mem.can_access_block m_after b cp }. *)

  Lemma inject_separated_notmap
        f f' m m' b
        (NM: meminj_notmap f b)
        (VALID: Mem.valid_block m' b)
        (* (INJ: Mem.inject f m m') *)
        (INCR: inject_incr f f')
        (SEP: inject_separated f f' m m')
    :
    meminj_notmap f' b.
  Proof.
    unfold meminj_notmap, inject_incr, inject_separated in *.
    intros. intros CONTRA. specialize (NM b0 ofs0). destruct (f b0) eqn:FB.
    { destruct p. specialize (INCR _ _ _ FB). rewrite CONTRA in INCR. inversion INCR; clear INCR; subst. congruence. }
    specialize (SEP _ _ _ FB CONTRA). destruct SEP as [NV1 NV2]. congruence.
  Qed.

  (*
forall b, b is the block of one of the counter ->
     (forall b0 ofs, ~ (f b0 = Some (b, ofs)))
   *)

  (*   (** External calls must commute with memory injections, *)
   (* in the following sense. *) *)
  (* ec_mem_inject: *)
  (*   forall ge1 ge2 c vargs m1 t vres m2 f m1' vargs', *)
  (*   symbols_inject f ge1 ge2 -> *)
  (*   sem ge1 c vargs m1 t vres m2 -> *)
  (*   Mem.inject f m1 m1' -> *)
  (*   Val.inject_list f vargs vargs' -> *)
  (*   exists f', exists vres', exists m2', *)
  (*      sem ge2 c vargs' m1' t vres' m2' *)
  (*   /\ Val.inject f' vres vres' *)
  (*   /\ Mem.inject f' m2 m2' *)
  (*   /\ Mem.unchanged_on (loc_unmapped f) m1 m2 *)
  (*   /\ Mem.unchanged_on (loc_out_of_reach f m1) m1' m2' *)
  (*   /\ inject_incr f f' *)
  (*   /\ inject_separated f f' m1 m1'; *)

End AUX.


Section Backtranslation.

  Ltac simpl_expr :=
    repeat (match goal with
            | |- eval_expr _ _ _ _ _ _ _ => econstructor
            | |- eval_lvalue _ _ _ _ _ _ _ _ _ => econstructor 2
            (* | |- eval_lvalue _ _ _ _ _ _ _ _ _ => econstructor *)
            | |- deref_loc _ _ _ _ _ _ _ => econstructor
            | |- assign_loc _ _ _ _ _ _ _ _ _ => econstructor
            | |- Cop.sem_cmp _ _ _ _ _ _ = Some _ => unfold Cop.sem_cmp
            | |- Cop.sem_add _ _ _ _ _ _ = Some _ => unfold Cop.sem_add
            | |- Cop.sem_binarith _ _ _ _ _ _ _ _ _ = Some _ => unfold Cop.sem_binarith
            | |- match Cop.sem_cast _ ?x ?x _ with | _ => _ end = Some _ => rewrite Cop.cast_val_casted
            | |- Cop.sem_cast _ ?y ?y _ = Some _ => rewrite Cop.cast_val_casted
            | |- Cop.val_casted _ _ => constructor
            | H: ?x = _ |- Cop.bool_val (_ ?x) _ _ = Some _ => rewrite H; try reflexivity
            end; simpl; eauto).

  Ltac take_step := econstructor; [econstructor; simpl_expr | | traceEq]; simpl.

  (* Variable bt_env: backtranslation_environment. *)

  Section SWITCH.
    (** switch statement; use to convert a trace to a code **)

    Definition type_counter: type := Tlong Unsigned noattr.
    Definition type_bool:    type := Tint IBool Signed noattr.

    Definition switch_clause (cnt: ident) (n: Z) (s_then s_else: statement): statement :=
      let one := Econst_long Int64.one type_counter in
      Sifthenelse (Ebinop Cop.Oeq
                          (Evar cnt type_counter)
                          (Econst_long (Int64.repr n) type_counter)
                          type_bool)
                  (* if true *)
                  (Ssequence
                     (Sassign (Evar cnt type_counter)
                              (Ebinop Cop.Oadd (Evar cnt type_counter) one type_counter))
                     s_then)
                  (* if false *)
                  s_else.

    Ltac simpl_expr' :=
      unfold type_counter; unfold type_bool; simpl; simpl_expr.

    Ltac take_step' := econstructor; [econstructor; simpl_expr' | | traceEq]; simpl.

    Lemma switch_clause_spec p (cnt: ident) f e le m b (n: int64) (n': Z) s_then s_else:
      let cp := comp_of f in
      let ge := globalenv p in
      e ! cnt = None ->
      Genv.find_symbol ge cnt = Some b ->
      (* e ! cnt = Some (b, type_counter) -> *)
      Mem.valid_access m Mint64 b 0 Writable (Some cp) ->
      Mem.loadv Mint64 m (Vptr b Ptrofs.zero) (Some cp) = Some (Vlong n) ->
      if Int64.eq n (Int64.repr n') then
        exists m',
          Mem.storev Mint64 m (Vptr b Ptrofs.zero) (Vlong (Int64.add n Int64.one)) cp = Some m' /\
            Star (Clight.semantics1 p) (State f (switch_clause cnt n' s_then s_else) Kstop e le m) E0 (State f s_then Kstop e le m')
      else
        Star (Clight.semantics1 p) (State f (switch_clause cnt n' s_then s_else) Kstop e le m) E0 (State f s_else Kstop e le m).
    Proof.
      intros; subst cp ge.
      destruct (Int64.eq n (Int64.repr n')) eqn:eq_n_n'.
      - simpl.
        destruct (Mem.valid_access_store m Mint64 b 0%Z (comp_of f) (Vlong (Int64.add n Int64.one))) as [m' m_m']; try assumption.
        exists m'. split; eauto.
        do 4 take_step'.
        now apply star_refl.
      - (* take_steps. *)
        take_step'. rewrite Int.eq_true; simpl.
        now apply star_refl.
    Qed.


    Definition switch_add_statement cnt s res :=
      (Z.pred (fst res), switch_clause cnt (Z.pred (fst res)) s (snd res)).

    Definition switch (cnt: ident) (ss: list statement) (s_else: statement): statement :=
      snd (fold_right (switch_add_statement cnt) (Z.of_nat (length ss), s_else) ss).

    Lemma fst_switch (cnt: ident) n (s_else: statement) (ss : list statement) :
      fst (fold_right (switch_add_statement cnt) (n, s_else) ss) = (n - Z.of_nat (length ss))%Z.
    Proof.
      induction ss as [|s' ss IH]; try now rewrite Z.sub_0_r.
      simpl; lia.
    Qed.

    Lemma switch_spec_else
          p (cnt: ident) f (e: env) le m b (n: Z) ss s_else
          (WF: Z.of_nat (length ss) < Int64.modulus)
          (RANGE: Z.of_nat (length ss) <= n < Int64.modulus)
      :
      let ge := globalenv p in
      let cp := comp_of f in
      e ! cnt = None ->
      Genv.find_symbol ge cnt = Some b ->
      (* e ! (bt_env.(local_counter) cp) = Some (b, type_counter) -> *)
      (* Mem.valid_access m Mint64 b 0 Writable (Some cp) -> *)
      Mem.loadv Mint64 m (Vptr b Ptrofs.zero) (Some cp) = Some (Vlong (Int64.repr n)) ->
      Star (Clight.semantics1 p)
           (State f (switch cnt ss s_else) Kstop e le m)
           E0
           (State f s_else Kstop e le m).
    Proof.
      intros; subst cp ge. unfold switch. destruct RANGE as [RA1 RA2].
      assert (G: forall n',
                 (Z.of_nat (length ss)) <= n' ->
                 n' <= n ->
                 Star (Clight.semantics1 p)
                      (State f (snd (fold_right (switch_add_statement cnt) (n', s_else) ss)) Kstop e le m)
                      E0
                      (State f s_else Kstop e le m)).
      { intros n' LE1 LE2.
        induction ss as [|s ss IH]; try apply star_refl.
        simpl. simpl in RA1, LE1. rewrite fst_switch, <- Z.sub_succ_r.
        take_step'.
        { rewrite Int64.eq_false. reflexivity. clear - WF RA1 RA2 LE1 LE2.
          destruct (Z.eqb_spec n (n' - Z.of_nat (S (length ss)))) as [n_eq_0|?]; simpl.
          - lia.
          - intros EQ. apply n0; clear n0.
            rewrite <- (Int64.unsigned_repr n).
            rewrite EQ. rewrite Int64.unsigned_repr. lia.
            1: split.
            all: unfold Int64.max_unsigned; try lia.
        }
        rewrite Int.eq_true; simpl.
        eapply IH; lia.
      }
      now apply G; lia.
    Qed.

    Let nat64 n := Int64.repr (Z.of_nat n).

    Lemma switch_spec
          p (cnt: ident) f (e: env) le m b
          ss s ss' s_else
          (WF: Z.of_nat (length (ss ++ s :: ss')) < Int64.modulus)
      :
      let ge := globalenv p in
      let cp := comp_of f in
      e ! cnt = None ->
      Genv.find_symbol ge cnt = Some b ->
      (* e ! (bt_env.(local_counter) cp) = Some (b, type_counter) -> *)
      Mem.valid_access m Mint64 b 0 Writable (Some cp) ->
      Mem.loadv Mint64 m (Vptr b Ptrofs.zero) (Some cp) = Some (Vlong (nat64 (length ss))) ->
      exists m',
        Mem.storev Mint64 m (Vptr b Ptrofs.zero) (Vlong (Int64.add (nat64 (length ss)) Int64.one)) cp = Some m' /\
          Star (Clight.semantics1 p)
               (State f (switch cnt (ss ++ s :: ss') s_else) Kstop e le m)
               E0
               (State f s Kstop e le m').
    Proof.
      intros.
      assert (Eswitch :
               exists s_else',
                 switch cnt (ss ++ s :: ss') s_else =
                   switch cnt ss (switch_clause cnt (Z.of_nat (length ss)) s s_else')).
      { unfold switch. rewrite fold_right_app, app_length. simpl.
        exists (snd (fold_right (switch_add_statement cnt) (Z.of_nat (length ss + S (length ss')), s_else) ss')).
        repeat f_equal. rewrite -> surjective_pairing at 1. simpl.
        rewrite fst_switch, Nat.add_succ_r.
        assert (A: Z.pred (Z.of_nat (S (Datatypes.length ss + Datatypes.length ss')) - Z.of_nat (Datatypes.length ss')) = Z.of_nat (Datatypes.length ss)) by lia.
        rewrite A. reflexivity.
      }
      destruct Eswitch as [s_else' ->]. clear s_else. rename s_else' into s_else.
      exploit (switch_clause_spec p cnt f e le m b (nat64 (length ss)) (Z.of_nat (length ss)) s s_else); auto.
      unfold nat64. rewrite Int64.eq_true. intro Hcont.
      destruct Hcont as (m' & Hstore & Hstar2).
      exists m'. split; trivial.
      apply (fun H => @star_trans _ _ _ _ _ E0 _ H E0 _ _ Hstar2); trivial.
      assert (WF2: Z.of_nat (Datatypes.length ss) < Int64.modulus).
      { clear - WF. rewrite app_length in WF. lia. }
      eapply switch_spec_else; eauto. split; auto. reflexivity.
    Qed.

  End SWITCH.


  Section CONV.
    (** converting event to data **)

    Context {F: Type}.
    Context {V: Type}.
    Variable ge: Genv.t F V.

    Definition wf_env (e: env) id := e ! id = None.

    Definition eventval_to_type (v: eventval): type :=
      match v with
      | EVint _ => Tint I32 Signed noattr
      | EVlong _ => Tlong Signed noattr
      | EVfloat _ => Tfloat F64 noattr
      | EVsingle _ => Tfloat F32 noattr
      | EVptr_global id _ => Tpointer Tvoid noattr
      end.

    Definition ptr_of_id_ofs (id: ident) (ofs: ptrofs): expr :=
      if Archi.ptr64
      then
        Ebinop Cop.Oadd
               (Eaddrof (Evar id Tvoid) (Tpointer Tvoid noattr))
               (Econst_long (Ptrofs.to_int64 ofs) (Tlong Signed noattr))
               (Tpointer Tvoid noattr)
      else
        Ebinop Cop.Oadd
               (Eaddrof (Evar id Tvoid) (Tpointer Tvoid noattr))
               (Econst_int (Ptrofs.to_int ofs) (Tint I32 Signed noattr))
               (Tpointer Tvoid noattr).

    Lemma ptr_of_id_ofs_typeof
          i i0
      :
      typeof (ptr_of_id_ofs i i0) = Tpointer Tvoid noattr.
    Proof. unfold ptr_of_id_ofs. destruct Archi.ptr64; simpl; auto. Qed.

    Definition eventval_to_expr (v: eventval): expr :=
      match v with
      | EVint i => Econst_int i (Tint I32 Signed noattr)
      | EVlong i => Econst_long i (Tlong Signed noattr)
      | EVfloat f => Econst_float f (Tfloat F64 noattr)
      | EVsingle f => Econst_single f (Tfloat F32 noattr)
      | EVptr_global id ofs => ptr_of_id_ofs id ofs
      end.

    Definition wf_eventval_env (e: env) (v: eventval): Prop :=
      match v with
      | EVptr_global id _ => wf_env e id
      | _ => True
      end.

    Definition wf_eventval_pub (v: eventval): Prop :=
      match v with
      | EVptr_global id _ => (Senv.public_symbol ge id = true)
      | _ => True
      end.

    Definition wf_eventval_ge (v: eventval): Prop :=
      match v with
      | EVptr_global id _ => (exists b, Genv.find_symbol ge id = Some b)
      | _ => True
      end.

    Lemma wf_eventval_pub_ge
          v
      :
      wf_eventval_pub v -> wf_eventval_ge v.
    Proof. intros H. destruct v; simpl in *; auto. apply Genv.public_symbol_exists in H; auto. Qed.

    Definition eventval_to_val (v: eventval): val :=
      match v with
      | EVint i => Vint i
      | EVlong i => Vlong i
      | EVfloat f => Vfloat f
      | EVsingle f => Vsingle f
      | EVptr_global id ofs => match Senv.find_symbol ge id with
                              | Some b => Vptr b ofs
                              | None => Vundef
                              end
      end.

    Fixpoint list_eventval_to_typelist (vs: list eventval): typelist :=
      match vs with
      | nil => Tnil
      | cons v vs' => Tcons (eventval_to_type v) (list_eventval_to_typelist vs')
      end.

    Definition list_eventval_to_list_expr (vs: list eventval): list expr :=
      List.map eventval_to_expr vs.

    Definition list_eventval_to_list_val (vs: list eventval): list val :=
      List.map (eventval_to_val) vs.

    Lemma typeof_eventval_to_expr_type
          v
      :
      typeof (eventval_to_expr v) = eventval_to_type v.
    Proof. destruct v; simpl; auto. apply ptr_of_id_ofs_typeof. Qed.

  End CONV.


  Section CODEAUX.

    (* We extract function data: argument types, fn_return, rn_callconv from signature of Asm.function *)
    (* Coreectness should follow from the semantics of Asm, especially eventval_match *)
    Definition typ_to_type: typ -> type :=
      fun t: typ =>
        match t with
        | AST.Tint => Tint I32 Signed noattr
        | AST.Tfloat => Tfloat F64 noattr
        | AST.Tlong => Tlong Signed noattr
        | AST.Tsingle => Tfloat F32 noattr
        (* will not appear in well formed traces *)
        | AST.Tany32 => Tvoid
        | AST.Tany64 => Tvoid
        end.

    Fixpoint list_typ_to_typelist (ts: list typ): typelist :=
      match ts with
      | nil => Tnil
      | cons t ts' => Tcons (typ_to_type t) (list_typ_to_typelist ts')
      end.

    Definition rettype_to_type: rettype -> type :=
      fun rt: rettype =>
        match rt with
        | Tint8signed => Tint I8 Signed noattr
        | Tint8unsigned => Tint I8 Unsigned noattr
        | Tint16signed => Tint I16 Signed noattr
        | Tint16unsigned => Tint I16 Unsigned noattr
        | AST.Tvoid => Tvoid
        | Tret t => typ_to_type t
        end.

    (* Wanted internal function data from signature *)
    (* Definition fun_data : Type := (typelist * type * calling_convention). *)
    Record fun_data : Type := mkfundata { dargs: typelist; dret: type; dcc: calling_convention }.
    Definition funs_data : Type := (PTree.tree fun_data).

    (* Definition from_sig_fun_data (sig: signature): fun_data := (list_typ_to_typelist sig.(sig_args), rettype_to_type sig.(sig_res), sig.(sig_cc)). *)
    Definition from_sig_fun_data (sig: signature): fun_data :=
      mkfundata (list_typ_to_typelist sig.(sig_args)) (rettype_to_type sig.(sig_res)) (sig.(sig_cc)).

    (* Extract from Asm *)
    Definition from_asmfun_fun_data (af: Asm.function): fun_data := from_sig_fun_data af.(fn_sig).
    Definition from_extfun_fun_data (ef: external_function): fun_data := from_sig_fun_data (ef_sig ef).
    Definition from_asmfd_fun_data (fd: Asm.fundef): fun_data :=
      match fd with | AST.Internal af => from_asmfun_fun_data af | AST.External ef => from_extfun_fun_data ef end.
    Definition from_asmgd_fun_data (gd: globdef Asm.fundef unit): option fun_data :=
      match gd with | Gfun fd => Some (from_asmfd_fun_data fd) | Gvar _ => None end.

    Definition from_asm_funs_data (asm: Asm.program): funs_data :=
      let defs := Genv.genv_defs (Genv.globalenv asm) in
      PTree.map_filter1 from_asmgd_fun_data defs.

    (* Extract from Clight *)
    Definition from_clfun_fun_data (cf: Clight.function): fun_data := mkfundata (type_of_params cf.(fn_params)) cf.(fn_return) cf.(fn_callconv).
    Definition from_clfd_fun_data (fd: Clight.fundef): fun_data :=
      match fd with | Ctypes.Internal cf => from_clfun_fun_data cf | Ctypes.External _ tps tr cc => mkfundata tps tr cc end.
    Definition from_clgd_fun_data (gd: globdef Clight.fundef type): option fun_data :=
      match gd with | Gfun fd => Some (from_clfd_fun_data fd) | Gvar _ => None end.

    Definition from_cl_funs_data (cl: Clight.program): funs_data :=
      let defs := Genv.genv_defs (genv_genv (globalenv cl)) in
      PTree.map_filter1 from_clgd_fun_data defs.

  End CODEAUX.


  Section CODE.
    (** converting trace to code **)

    (* converting functions *)
    Definition code_of_vload (ch: memory_chunk) (id: ident) (ofs: Ptrofs.int) (v: eventval) :=
      Sbuiltin None (EF_vload ch) (dargs (from_extfun_fun_data (EF_vload ch))) (ptr_of_id_ofs id ofs :: nil).

    Definition code_of_vstore (ch: memory_chunk) (id: ident) (ofs: Ptrofs.int) (v: eventval) :=
      Sbuiltin None (EF_vstore ch) (dargs (from_extfun_fun_data (EF_vstore ch))) ((ptr_of_id_ofs id ofs) :: (eventval_to_expr v) :: nil).

    Definition code_of_annot (str: string) (vs: list eventval) :=
      let efa := (EF_annot
                    (Pos.of_nat (List.length (typlist_of_typelist (list_eventval_to_typelist vs))))
                    str
                    (typlist_of_typelist (list_eventval_to_typelist vs))
                 )
      in
      Sbuiltin None efa (dargs (from_extfun_fun_data efa)) (list_eventval_to_list_expr vs).

    Definition code_of_call (fds: funs_data) (cp cp': compartment) (id: ident) (vs: list eventval) :=
      let '(targs, tret, cc) := match fds ! id with
                                | Some data => (dargs data, dret data, dcc data)
                                | None => (Tnil, Tvoid, cc_default)
                                end
      in
      Scall None (Evar id (Tfunction targs tret cc)) (list_eventval_to_list_expr vs).
      (* Scall None (Evar id (Tfunction (list_eventval_to_typelist vs) Tvoid cc_default)) (list_eventval_to_list_expr vs). *)

    (* An [event_syscall] does not need any code, because it is only generated after a call to an external function *)
    Definition code_of_syscall (name: string) (vs: list eventval) (v: eventval) := Sskip.

    Definition code_of_return (cp cp': compartment) (v: eventval) :=
      Sreturn (Some (eventval_to_expr v)).

    Definition code_of_event (fds: funs_data) (e: event): statement :=
      match e with
      | Event_vload ch id ofs v => code_of_vload ch id ofs v
      | Event_vstore ch id ofs v => code_of_vstore ch id ofs v
      | Event_annot str vs => code_of_annot str vs
      | Event_call cp cp' id vs => code_of_call fds cp cp' id vs
      | Event_syscall name vs v => code_of_syscall name vs v
      | Event_return cp cp' v => code_of_return cp cp' v
      end.

    (* A while(1)-loop with a big switch inside it *)
    Definition code_of_trace (fds: funs_data) (t: trace) cnt: statement :=
      Swhile (Econst_int Int.one (Tint I32 Signed noattr)) (switch cnt (map (code_of_event fds) t) (Sreturn None)).

  End CODE.


  Section CODEPROP.

    Let cgenv := Genv.t fundef type.

    (* Properties *)
    Lemma eventval_match_transl
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      eventval_match ge ev (typ_of_type (typ_to_type ty)) (eventval_to_val ge ev).
    Proof.
      inversion EM; subst; simpl; try constructor.
      setoid_rewrite H0. unfold Tptr in *. destruct Archi.ptr64; auto.
    Qed.

    Lemma eventval_match_eventval_to_val
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      eventval_to_val ge ev = v.
    Proof. inversion EM; subst; simpl; auto. setoid_rewrite H0. auto. Qed.

    Lemma eventval_match_wf_eventval_ge
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      wf_eventval_ge ge ev.
    Proof. inversion EM; subst; simpl; eauto. Qed.

    Lemma eventval_list_match_transl
          F V (ge: Genv.t F V)
          evs tys vs
          (EM: eventval_list_match ge evs tys vs)
      :
      eventval_list_match ge evs (typlist_of_typelist (list_typ_to_typelist tys)) (list_eventval_to_list_val ge evs).
    Proof.
      induction EM; simpl. constructor. constructor; auto. eapply eventval_match_transl; eauto.
    Qed.

    Lemma typ_type_typ
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      typ_of_type (typ_to_type ty) = ty.
    Proof. inversion EM; simpl; auto. subst. unfold Tptr. destruct Archi.ptr64; simpl; auto. Qed.

    Lemma ptr_of_id_ofs_eval
          id ofs e (ge: genv) b cp le m
          (GE1: wf_env e id)
          (GE2: Genv.find_symbol ge id = Some b)
      :
      eval_expr ge e cp le m (ptr_of_id_ofs id ofs) (Vptr b ofs).
    Proof.
      unfold ptr_of_id_ofs. destruct (Archi.ptr64) eqn:ARCH.
      - eapply eval_Ebinop. eapply eval_Eaddrof. eapply eval_Evar_global; eauto.
        simpl_expr.
        simpl. simpl_expr. rewrite Ptrofs.mul_commut, Ptrofs.mul_one. rewrite Ptrofs.add_zero_l.
        rewrite Ptrofs.of_int64_to_int64; auto.
      - eapply eval_Ebinop. eapply eval_Eaddrof. eapply eval_Evar_global; eauto.
        simpl_expr.
        simpl. simpl_expr. rewrite Ptrofs.mul_commut, Ptrofs.mul_one. rewrite Ptrofs.add_zero_l.
        erewrite Ptrofs.agree32_of_ints_eq; auto. apply Ptrofs.agree32_to_int; auto.
    Qed.

    Lemma eventval_to_expr_val_eval
          (ge: genv) en cp temp m ev
          (WFENV: wf_eventval_env en ev)
          (WFGE: wf_eventval_ge ge ev)
      :
      eval_expr ge en cp temp m (eventval_to_expr ev) (eventval_to_val ge ev).
    Proof.
      destruct ev; simpl in *; try constructor.
      destruct WFGE as [b WFGE].
      rewrite WFGE. unfold ptr_of_id_ofs. destruct Archi.ptr64 eqn:ARCH.
      - econstructor; try econstructor. eapply eval_Evar_global; eauto.
        simpl. simpl_expr. rewrite Ptrofs.mul_commut, Ptrofs.mul_one. rewrite Ptrofs.add_zero_l.
        rewrite Ptrofs.of_int64_to_int64; auto.
      - econstructor; try econstructor. eapply eval_Evar_global; eauto.
        simpl. simpl_expr. rewrite Ptrofs.mul_commut, Ptrofs.mul_one. rewrite Ptrofs.add_zero_l.
        erewrite Ptrofs.agree32_of_ints_eq; auto. apply Ptrofs.agree32_to_int; auto.
    Qed.

    Lemma sem_cast_eventval_match
          (ge: cgenv) v ty vv m
          (EM: eventval_match ge v (typ_of_type (typ_to_type ty)) vv)
      :
      Cop.sem_cast vv (typeof (eventval_to_expr v)) (typ_to_type ty) m = Some vv.
    Proof.
      destruct ty; simpl in *; inversion EM; subst; simpl in *; simpl_expr.
      all: try rewrite ptr_of_id_ofs_typeof; simpl.
      all: try (cbn; auto).
      all: unfold Tptr in *; destruct Archi.ptr64 eqn:ARCH; try congruence.
      { unfold Cop.sem_cast. simpl. rewrite ARCH. simpl. rewrite pred_dec_true; auto. }
      { unfold Cop.sem_cast. simpl. rewrite ARCH. auto. }
    Qed.

    Lemma list_eventval_to_expr_val_eval
          (ge: genv) en cp temp m evs tys
          (WFENV: Forall (wf_eventval_env en) evs)
          (EMS: eventval_list_match ge evs (typlist_of_typelist (list_typ_to_typelist tys)) (list_eventval_to_list_val ge evs))
      :
      eval_exprlist ge en cp temp m (list_eventval_to_list_expr evs) (list_typ_to_typelist tys) (list_eventval_to_list_val ge evs).
    Proof.
      revert en cp temp m WFENV.
      match goal with | [H: eventval_list_match _ _ ?t ?v |- _] => remember t as tys2; remember v as vs2 end.
      revert tys Heqtys2 Heqvs2. induction EMS; intros; subst; simpl in *.
      { destruct tys; simpl in *. constructor. congruence. }
      inversion Heqvs2; clear Heqvs2; subst; simpl in *.
      inversion WFENV; clear WFENV; subst.
      destruct tys; simpl in Heqtys2. congruence with Heqtys2.
      inversion Heqtys2; clear Heqtys2; subst; simpl in *.
      econstructor; eauto. eapply eventval_to_expr_val_eval; eauto.
      eapply eventval_match_wf_eventval_ge; eauto.
      eapply sem_cast_eventval_match; eauto.
    Qed.

    Lemma eventval_match_eventval_to_type
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      eventval_match ge ev (typ_of_type (eventval_to_type ev)) v.
    Proof. inversion EM; subst; simpl; auto. Qed.

    Lemma list_eventval_match_eventval_to_type
          F V (ge: Genv.t F V)
          evs tys vs
          (ESM: eventval_list_match ge evs tys vs)
      :
      eventval_list_match ge evs (typlist_of_typelist (list_eventval_to_typelist evs)) vs.
    Proof. induction ESM; simpl. constructor. constructor; auto. eapply eventval_match_eventval_to_type; eauto. Qed.

    Lemma val_load_result_idem
          ch v
      :
      Val.load_result ch (Val.load_result ch v) = Val.load_result ch v.
    Proof.
      destruct ch, v; simpl; auto.
      5,6,7: destruct Archi.ptr64; simpl; auto.
      1,3: rewrite Int.sign_ext_idem; auto.
      3,4: rewrite Int.zero_ext_idem; auto.
      all: lia.
    Qed.

    Lemma val_load_result_aux
          F V (ge: Genv.t F V)
          ev ch v
          (EM: eventval_match ge ev (type_of_chunk ch) (Val.load_result ch v))
      :
      eventval_match ge ev (type_of_chunk ch) (Val.load_result ch (eventval_to_val ge ev)).
    Proof.
      inversion EM; subst; simpl in *; auto.
      1,2,3,4: rewrite H1, H2; rewrite val_load_result_idem; auto.
      rewrite H3, H. rewrite H0. rewrite val_load_result_idem. auto.
    Qed.

    Lemma eventval_match_proj_rettype
          F V (ge: Genv.t F V)
          ev ty v
          (EM: eventval_match ge ev ty v)
      :
      eventval_match ge ev (proj_rettype (rettype_of_type (typ_to_type ty))) v.
    Proof.
      inversion EM; subst; simpl; try constructor.
      unfold Tptr in *. destruct Archi.ptr64; simpl; auto.
    Qed.


    (* Step lemmas *)
    Lemma code_of_event_step_vload
          ev
          ch id ofs v
          p f k e le m
          (EV: ev = Event_vload ch id ofs v)
          (* bt_wf *)
          (WFENV: wf_env e id)
          (* from_asm *)
          b
          (VOL: Senv.block_is_volatile (globalenv p) b = true)
          (GE: Genv.find_symbol (globalenv p) id = Some b)
          rv
          (MATCH: eventval_match (globalenv p) v (type_of_chunk ch) rv)
      :
        Star (Clight.semantics1 p)
             (State f (code_of_event (from_cl_funs_data p) ev) k e le m)
             (ev :: nil)
             (State f Sskip k e le m).
    Proof.
      subst; simpl in *. unfold code_of_vload. simpl.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_builtin.
        { econstructor; eauto. 3: econstructor.
          - eapply ptr_of_id_ofs_eval; eauto.
          - destruct Archi.ptr64 eqn:ARCH.
            + unfold ptr_of_id_ofs, Tptr. rewrite ARCH. simpl. unfold Cop.sem_cast. simpl. rewrite ARCH. eauto.
            + unfold ptr_of_id_ofs, Tptr. rewrite ARCH. simpl. unfold Cop.sem_cast. simpl. rewrite ARCH. eauto.
        }
        repeat econstructor; eauto.
      }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_vstore
          ev
          ch id ofs v
          p f k e le m
          (EV: ev = Event_vstore ch id ofs v)
          (* bt_wf *)
          (WFENV: wf_env e id)
          (WFSV1: wf_eventval_env e v)
          (* from_asm *)
          b
          (VOL: Senv.block_is_volatile (globalenv p) b = true)
          (GE: Genv.find_symbol (globalenv p) id = Some b)
          vv
          (MATCH: eventval_match (globalenv p) v (type_of_chunk ch) (Val.load_result ch vv))
      :
        Star (Clight.semantics1 p)
             (State f (code_of_event (from_cl_funs_data p) ev) k e le m)
             (ev :: nil)
             (State f Sskip k e le m).
    Proof.
      apply val_load_result_aux in MATCH.
      subst; simpl in *. unfold code_of_vstore.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_builtin.
        { econstructor; eauto.
          { eapply ptr_of_id_ofs_eval; eauto. }
          { destruct Archi.ptr64 eqn:ARCH.
            - unfold ptr_of_id_ofs, Tptr. rewrite ARCH; simpl. unfold Cop.sem_cast. simpl. rewrite ARCH. eauto.
            - unfold ptr_of_id_ofs, Tptr. rewrite ARCH; simpl. unfold Cop.sem_cast. simpl. rewrite ARCH. eauto.
          }
          econstructor; eauto. 3: econstructor.
          { eapply eventval_to_expr_val_eval; auto. eapply eventval_match_wf_eventval_ge; eauto. }
          { eapply sem_cast_eventval_match; eauto. eapply eventval_match_transl. eauto. }
        }
        simpl. repeat econstructor; eauto.
      }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_annot
          ev
          str vs
          p f k e le m
          (EV: ev = Event_annot str vs)
          (* bt_wf *)
          (WFENV: Forall (wf_eventval_env e) vs)
          (* from_asm *)
          targs vargs
          (ESM: eventval_list_match (globalenv p) vs targs vargs)
      :
        Star (Clight.semantics1 p)
             (State f (code_of_event (from_cl_funs_data p) ev) k e le m)
             (ev :: nil)
             (State f Sskip k e le m).
    Proof.
      subst; simpl in *. unfold code_of_annot.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_builtin; simpl.
        { eapply list_eventval_to_expr_val_eval; auto. eapply eventval_list_match_transl. eapply list_eventval_match_eventval_to_type; eauto. }
        { repeat econstructor; eauto. eapply list_eventval_match_eventval_to_type. eapply eventval_list_match_transl; eauto. }
      }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_call_start
          ev
          cp cp' id vs
          p f k e le m
          ge data
          (GE: ge = globalenv p)
          (EV: ev = Event_call cp cp' id vs)
          (FDATA: (from_cl_funs_data p) ! id = Some data)
          (* bt_wf *)
          (GLOB: e ! id = None)
          (WFARGS1: Forall (wf_eventval_env e) vs)
          (* from_asm *)
          b
          (FINDB: Genv.find_symbol ge id = Some b)
          fd
          (FINDF: Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd)
          (TYPEF: type_of_fundef fd = Tfunction data.(dargs) data.(dret) data.(dcc))
          (CP1: cp = comp_of f)
          (CP2: cp' = comp_of fd)
          (CROSS: Genv.type_of_call ge (comp_of f) (comp_of fd) = Genv.CrossCompartmentCall)
          (NPTR: Forall not_ptr (list_eventval_to_list_val ge vs))
          (ALLOW: Genv.allowed_cross_call ge (comp_of f) (Vptr b Ptrofs.zero))
          some_sig_args some_vals
          (ESM: eventval_list_match ge vs some_sig_args some_vals)
          (SIGARGS: data.(dargs) = (list_typ_to_typelist some_sig_args))
      :
        Star (Clight.semantics1 p)
             (State f (code_of_event (from_cl_funs_data p) ev) k e le m)
             (ev :: nil)
             (Callstate fd (list_eventval_to_list_val ge vs) (Kcall None f e le k) m).
    Proof.
      subst; simpl. unfold code_of_call. rewrite FDATA.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_call; simpl; eauto.
        { eapply eval_Elvalue.
          - eapply eval_Evar_global; eauto.
          - eapply deref_loc_reference. auto.
        }
        { rewrite SIGARGS. apply list_eventval_to_expr_val_eval; auto. eapply eventval_list_match_transl. eauto. }
        red; auto.
        unfold Genv.find_comp. setoid_rewrite FINDF.
        eapply call_trace_cross; eauto. apply Genv.find_invert_symbol; auto.
        rewrite SIGARGS. eapply eventval_list_match_transl; eauto.
      }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_return
          ev
          cp cp' rv
          p f k e le m
          ge
          (GE: ge = globalenv p)
          (EV: ev = Event_return cp' cp rv)
          (* bt should ensure them *)
          (WFRV1: wf_eventval_env e rv)
          (* asm should ensure them *)
          (NPTR: not_ptr (eventval_to_val ge rv))
          some_sig_ret some_val
          (EM: eventval_match ge rv some_sig_ret some_val)
          (RTTYP: fn_return f = typ_to_type some_sig_ret)
          (* handle during proving *)
          optid f' e' le' k'
          (CONT: call_cont k = Kcall optid f' e' le' k')
          (CP1: cp = comp_of f)
          (CP2: cp' = comp_of f')
          (CROSS: Genv.type_of_call ge (comp_of f') (comp_of f) = Genv.CrossCompartmentCall)
          m'
          (FREE: Mem.free_list m (blocks_of_env ge e) (comp_of f) = Some m')
      :
      Star (Clight.semantics1 p)
           (State f (code_of_event (from_cl_funs_data p) ev) k e le m)
           (ev :: nil)
           (State f' Sskip k' e' (set_opttemp optid (eventval_to_val ge rv) le') m').
    Proof.
      subst; simpl. unfold code_of_return.
      econstructor 2.
      3:{ rewrite E0_left. reflexivity. }
      { eapply step_return_1; simpl; eauto.
        { eapply eventval_to_expr_val_eval; auto. eapply eventval_match_wf_eventval_ge; eauto. }
        { rewrite RTTYP. eapply sem_cast_eventval_match. eapply eventval_match_transl; eauto. }
      }
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { rewrite CONT. eapply step_returnstate; auto.
        econstructor 2; auto. rewrite RTTYP. apply eventval_match_proj_rettype. erewrite eventval_match_eventval_to_val; eauto.
      }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_call_internal
          p f k e le m
          ge
          (GE: ge = globalenv p)
          (* bt should ensure them *)
          fd args f1
          (INTERNAL: fd = Internal f1)
          (* asm should ensure them *)
          (* handle during proving *)
          e1 le1 m1
          (ENTRY: function_entry1 ge f1 args m e1 le1 m1)
      :
        Star (Clight.semantics1 p)
             (Callstate fd args (Kcall None f e le k) m)
             nil
             (State f1 (fn_body f1) (Kcall None f e le k) e1 le1 m1).
    Proof.
      subst; simpl.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_internal_function; eauto. }
      econstructor 1.
    Qed.

    Lemma code_of_event_step_call_external
          p m
          ge
          (GE: ge = globalenv p)
          (* bt should ensure them *)
          fd k args ef targs tres cconv
          (EXTERNAL: fd = External ef targs tres cconv)
          (* asm should ensure them *)
          sev
          vres m1
          (SEM: external_call ef ge (call_comp k) args m (sev :: nil) vres m1)
          (* handle during proving *)
          sname sargs svr
          (SYSEV: sev = Event_syscall sname sargs svr)
      :
        Star (Clight.semantics1 p)
             (Callstate fd args k m)
             (sev :: nil)
             (Returnstate vres k m1 (rettype_of_type tres) (comp_of ef)).
    Proof.
      subst; simpl.
      econstructor 2.
      3:{ rewrite E0_right. reflexivity. }
      { eapply step_external_function; eauto. }
      econstructor 1.
    Qed.

  End CODEPROP.


  Section WELLFORMED.

    Definition empty_le := PTree.empty val.

    (* wf_sem: from asm, wf_st: proof invariant for Clight states *)
    Definition wf_sem_vload {F V} (ge: Genv.t F V) (ch: memory_chunk) (id: ident) (ofs: ptrofs) (v: eventval) :=
      (exists b, (Genv.find_symbol ge id = Some b) /\ (Senv.block_is_volatile ge b = true)) /\
        (exists rv, (eventval_match ge v (type_of_chunk ch) rv)).

    Definition wf_st_vload (ch: memory_chunk) (id: ident) (ofs: ptrofs) (v: eventval) e :=
      (wf_env e id).

    Definition wf_sem_vstore {F V} (ge: Genv.t F V) (ch: memory_chunk) (id: ident) (ofs: ptrofs) v :=
      (exists b, (Genv.find_symbol ge id = Some b) /\ (Senv.block_is_volatile ge b = true)) /\
        (exists vv, eventval_match ge v (type_of_chunk ch) (Val.load_result ch vv)).

    Definition wf_st_vstore (ch: memory_chunk) (id: ident) (ofs: ptrofs) v e :=
      (wf_env e id) /\ (wf_eventval_env e v).

    Definition wf_sem_annot {F V} (ge: Genv.t F V) (str: string) (vs: list eventval) :=
      exists targs vargs, eventval_list_match ge vs targs vargs.

    Definition wf_st_annot (str: string) (vs: list eventval) e :=
      (Forall (wf_eventval_env e) vs).

    Definition wf_sem_call_start_cl (ge: genv) (cp cp': compartment) (id: ident) (vs: list eventval) (fd: Clight.fundef) :=
      exists b,
        (Genv.find_symbol ge id = Some b) /\
          (Genv.find_funct ge (Vptr b Ptrofs.zero) = Some fd) /\
          let data := from_clfd_fun_data fd in
          (type_of_fundef fd = Tfunction data.(dargs) data.(dret) data.(dcc)) /\
            (cp' = comp_of fd) /\
            (Genv.type_of_call ge cp cp' = Genv.CrossCompartmentCall) /\
            (Forall not_ptr (list_eventval_to_list_val ge vs)) /\
            (Genv.allowed_cross_call ge cp (Vptr b Ptrofs.zero)) /\
            exists some_sig_args some_vals,
              (eventval_list_match ge vs some_sig_args some_vals) /\
                (data.(dargs) = (list_typ_to_typelist some_sig_args)).

    Definition wf_st_call_start (cp cp': compartment) (id: ident) (vs: list eventval) e (f: Clight.function) :=
      (e ! id = None) /\ (Forall (wf_eventval_env e) vs) /\ (cp = comp_of f).

    Definition wf_st_call_internal (ge: genv) (vs: list eventval) (f1: Clight.function) m e1 m1 :=
      function_entry1 ge f1 (list_eventval_to_list_val ge vs) m e1 empty_le m1.

    Definition wf_st_call_external (ge: genv) (vs: list eventval) k m sname sargs svr ef m1 :=
      let sev := Event_syscall sname sargs svr in
      exists vres, (external_call ef ge (call_comp k) (list_eventval_to_list_val ge vs) m (sev :: nil) vres m1).

    Definition wf_sem_return {F V} (ge: Genv.t F V) (cp cp': compartment) (rv: eventval) :=
      (Genv.type_of_call ge cp' cp = Genv.CrossCompartmentCall) /\
        (not_ptr (eventval_to_val ge rv)) /\
        exists some_sig_ret some_val,
          (eventval_match ge rv some_sig_ret some_val).

    Definition wf_st_return (ge: genv) (cp cp': compartment) (rv: eventval) e (f: Clight.function) (k: cont) (m: mem) f' k' e' m' :=
      (wf_eventval_env e rv) /\
        (cp = comp_of f) /\
        (forall some_sig_ret some_val, (eventval_match ge rv some_sig_ret some_val) -> (fn_return f = typ_to_type some_sig_ret)) /\
        (call_cont k = Kcall None f' e' empty_le k') /\
        (cp' = comp_of f') /\
        (Mem.free_list m (blocks_of_env ge e) (comp_of f) = Some m').


    Inductive wf_inv_cl (ge: genv) : Clight.function -> cont -> env -> mem -> trace -> Prop :=
    | wf_inv_vload
        f k e m t
        ch id ofs v
        (SEM: wf_sem_vload ge ch id ofs v)
        (ST: wf_st_vload ch id ofs v e)
        (IND: wf_inv_cl ge f k e m t)
      :
      wf_inv_cl ge f k e m (Event_vload ch id ofs v :: t)
    | wf_inv_vstore
        f k e m t
        ch id ofs v
        (SEM: wf_sem_vstore ge ch id ofs v)
        (ST: wf_st_vstore ch id ofs v e)
        (IND: wf_inv_cl ge f k e m t)
      :
      wf_inv_cl ge f k e m (Event_vstore ch id ofs v :: t)
    | wf_inv_annot
        f k e m t
        str vs
        (SEM: wf_sem_annot ge str vs)
        (ST: wf_st_annot str vs e)
        (IND: wf_inv_cl ge f k e m t)
      :
      wf_inv_cl ge f k e m (Event_annot str vs :: t)

    | wf_inv_call_internal
        f k e m t
        cp cp' id vs
        fd
        (SEM: wf_sem_call_start_cl ge cp cp' id vs fd)
        (ST: wf_st_call_start cp cp' id vs e f)
        f1 e1 m1
        (ISINT: fd = Internal f1)
        (INT: wf_st_call_internal ge vs f1 m e1 m1)
        (IND: wf_inv_cl ge f1 (Kcall None f e empty_le k) e1 m1 t)
      :
      wf_inv_cl ge f k e m (Event_call cp cp' id vs :: t)
    | wf_inv_return
        f k e m t
        cp cp' rv
        (SEM: wf_sem_return ge cp cp' rv)
        f' k' e' m'
        (ST: wf_st_return ge cp cp' rv e f k m f' k' e' m')
        (IND: wf_inv_cl ge f' k' e' m' t)
      :
      wf_inv_cl ge f k e m (Event_return cp cp' rv :: t).


    Definition wf_st_call_external (ge: genv) (vs: list eventval) k m sname sargs svr ef m1 :=
      let sev := Event_syscall sname sargs svr in
      exists vres, (external_call ef ge (call_comp k) (list_eventval_to_list_val ge vs) m (sev :: nil) vres m1).




    .

    (* TODO *)
    (* we need a more precise invariant for the proof, e.g. counters, mem_inj *)



(** Events.v **)
(* (** External calls must commute with memory injections, *)
(*   in the following sense. *) *)
(*   ec_mem_inject: *)
(*     forall ge1 ge2 c vargs m1 t vres m2 f m1' vargs', *)
(*     symbols_inject f ge1 ge2 -> *)
(*     sem ge1 c vargs m1 t vres m2 -> *)
(*     Mem.inject f m1 m1' -> *)
(*     Val.inject_list f vargs vargs' -> *)
(*     exists f', exists vres', exists m2', *)
(*        sem ge2 c vargs' m1' t vres' m2' *)
(*     /\ Val.inject f' vres vres' *)
(*     /\ Mem.inject f' m2 m2' *)
(*     /\ Mem.unchanged_on (loc_unmapped f) m1 m2 *)
(*     /\ Mem.unchanged_on (loc_out_of_reach f m1) m1' m2' *)
(*     /\ inject_incr f f' *)
(*     /\ inject_separated f f' m1 m1'; *)

    (* Lemma code_of_event_step_call_external *)
    (*       p m *)
    (*       ge *)
    (*       (GE: ge = globalenv p) *)
    (*       (* bt should ensure them *) *)
    (*       fd k args ef targs tres cconv *)
    (*       (EXTERNAL: fd = External ef targs tres cconv) *)
    (*       (* asm should ensure them *) *)
    (*       sev *)
    (*       vres m1 *)
    (*       (SEM: external_call ef ge (call_comp k) args m (sev :: nil) vres m1) *)
    (*       (* handle during proving *) *)
    (*       sname sargs svr *)
    (*       (SYSEV: sev = Event_syscall sname sargs svr) *)
    (*   : *)
    (*     Star (Clight.semantics1 p) *)
    (*          (Callstate fd args k m) *)
    (*          (sev :: nil) *)
    (*          (Returnstate vres k m1 (rettype_of_type tres) (comp_of ef)). *)

  End WELLFORMED.


  Section PROJ.
    (** Projection of the trace according to compartments **)

    Definition comp_of_event (e: event): option (compartment * compartment) :=
      match e with
      | Event_call cp cp' id vs => Some (cp, cp')
      | Event_return cp' cp v => Some (cp, cp')
      | _ => None
      end.

    (* Instance has_comp_event: has_comp event := *)

    Definition comp_proj_trace (cp: compartment) (t: trace): compartment * trace :=
      fold_right
        (fun ev '(cp_now, sub) => match comp_of_event ev with
                               | Some (cp_curr, cp_next) => (cp_next, if (Pos.eqb cp_curr cp) then (ev :: sub) else sub)
                               | None => (cp_now, if (Pos.eqb cp_now cp) then (ev :: sub) else sub)
                               end)
        (default_compartment, nil) t.

    Definition comp_subtrace (cp: compartment) (t: trace) :=
      snd (comp_proj_trace cp t).

    Definition code_of_subtrace cp t :=
      code_of_trace cp (comp_subtrace cp t).

    Definition codes_of_subtraces (cps: list compartment) t : PTree.t statement :=
      PTree_Properties.of_list (map (fun cp => (cp, code_of_subtrace cp t)) cps).

    Definition get_cps_from_policy (p: Policy.t): list compartment :=
      map fst (PTree.elements p.(Policy.policy_export)).

  End PROJ.


  (* TODO *)
  (* Axiom backtranslation: Asm.program -> split -> trace -> Clight.program * Clight.program. *)
  (* Axiom backtranslation_correct: *)
  (*   forall pol s t p C, *)
  (*     backtranslation pol s t = (p, C) -> *)
  (*     clight_compatible s p C /\ *)
  (*     exists W, link p C = Some W /\ *)
  (*            clight_program_has_initial_trace W t. *)

  (* Definition clight_has_side (s: split) (lr: side) (p: Clight.program) := *)
  (*   List.Forall (fun '(id, gd) => *)
  (*                  match gd with *)
  (*                  | Gfun (Ctypes.Internal f) => s (comp_of f) = lr *)
  (*                  | _ => True *)
  (*                  end) *)
  (*               (Ctypes.prog_defs p). *)

  (* Definition clight_compatible (s: split) (p p': Clight.program) := *)
  (*   clight_has_side s Left p /\ clight_has_side s Right p'. *)

  (* Definition clight_program_has_initial_trace (p: Clight.program) (t: trace): Prop := *)
  (*   forall beh, program_behaves (Clight.semantics1 p) beh -> behavior_prefix t beh. *)

  (* Axiom backtranslation_pol: forall pol s t, *)
  (*     Ctypes.prog_pol (fst (backtranslation pol s t)) = pol /\ *)
  (*     Ctypes.prog_pol (snd (backtranslation pol s t)) = pol. *)

  (* Clight.program = Ctypes.program Clight.function *)

  (* old CCS version *)
  Lemma comp_subtrace_app (C: Component.id) (t1 t2: trace) :
    comp_subtrace C (t1 ++ t2) = comp_subtrace C t1 ++ comp_subtrace C t2.
  Proof. apply: filter_cat. Qed.

  Definition procedure_of_trace C P t :=
    expr_of_trace C P (comp_subtrace C t).

  Definition procedures_of_trace (t: trace) : NMap (NMap expr) :=
    mapim (fun C Ciface =>
             let procs :=
                 if C == Component.main then
                   Procedure.main |: Component.export Ciface
                 else Component.export Ciface in
               mkfmapf (fun P => procedure_of_trace C P t) procs)
          intf.

  Definition valid_procedure C P :=
    C = Component.main /\ P = Procedure.main
    \/ exported_procedure intf C P.

  Lemma find_procedures_of_trace_exp (t: trace) C P :
    exported_procedure intf C P ->
    find_procedure (procedures_of_trace t) C P
    = Some (procedure_of_trace C P t).
  Proof.
    intros [CI [C_CI CI_P]].
    unfold find_procedure, procedures_of_trace.
    rewrite mapimE C_CI /= mkfmapfE.
    case: eqP=> _; last by rewrite CI_P.
    by rewrite in_fsetU1 CI_P orbT.
  Qed.

  Lemma find_procedures_of_trace_main (t: trace) :
    find_procedure (procedures_of_trace t) Component.main Procedure.main
    = Some (procedure_of_trace Component.main Procedure.main t).
  Proof.
    rewrite /find_procedure /procedures_of_trace.
    rewrite mapimE eqxx.
    case: (intf Component.main) (has_main)=> [Cint|] //= _.
    by rewrite mkfmapfE in_fsetU1 eqxx.
  Qed.

  Lemma find_procedures_of_trace (t: trace) C P :
    valid_procedure C P ->
    find_procedure (procedures_of_trace t) C P
    = Some (procedure_of_trace C P t).
  Proof.
    by move=> [[-> ->]|?];
    [apply: find_procedures_of_trace_main|apply: find_procedures_of_trace_exp].
  Qed.

  Definition program_of_trace (t: trace) : program :=
    {| prog_interface  := intf;
       prog_procedures := procedures_of_trace t;
       prog_buffers    := mapm (fun _ => inr [Int 0]) intf |}.

  (* old CCS version *)
  

  Section WithTrace.

    Variable cp: compartment.
    Variable t: trace.
    (* Hypothesis t_cp: forall e \in t, comp_of e = cp. *)
    (* Hypothesis t_small_enoug: length t <= 2^60. *)

    Definition statement_of_trace: statement :=
      switch (map (statement_of_event cp) t) Sskip.




  End WithTrace.

End Backtranslation.

  (* Axiom backtranslation: Policy.t -> split -> trace -> Clight.program * Clight.program. *)
  (* Axiom backtranslation_correct: *)
  (*   forall pol s t p C, *)
  (*     backtranslation pol s t = (p, C) -> *)
  (*     clight_compatible s p C /\ *)
  (*     exists W, link p C = Some W /\ *)
  (*            clight_program_has_initial_trace W t. *)

  (* Axiom backtranslation_compiles: *)
  (*   forall pol s t p C, *)
  (*     backtranslation pol s t = (p, C) -> *)
  (*     exists p_compiled C_compiled, *)
  (*       transf_clight_program p = OK p_compiled /\ *)
  (*         transf_clight_program C = OK C_compiled. *)

  (* Axiom backtranslation_pol: forall pol s t, *)
  (*     Ctypes.prog_pol (fst (backtranslation pol s t)) = pol /\ *)
  (*     Ctypes.prog_pol (snd (backtranslation pol s t)) = pol. *)
