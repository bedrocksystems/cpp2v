(*
 * Copyright (C) BedRock Systems Inc. 2020
 *
 * SPDX-License-Identifier: LGPL-2.1 WITH BedRock Exception for use over network, see repository root for details.
 *)
From iris.algebra Require Import excl gmap.
From iris.algebra.lib Require Import frac_auth.
From iris.bi Require Import monpred.
From iris.bi.lib Require Import fractional.
From iris.base_logic.lib Require Export iprop.
From iris.base_logic.lib Require Import fancy_updates own.
From iris.base_logic.lib Require Import cancelable_invariants.
From iris.proofmode Require Import tactics.
From iris_string_ident Require Import ltac2_string_ident.

From bedrock.lang.prelude Require Import base avl bytestring.
Require Import bedrock.lang.prelude.base.

From bedrock.lang.cpp Require Import ast.
From bedrock.lang.cpp.semantics Require Import values sub_module.
From bedrock.lang.cpp.logic Require Import pred.

Implicit Types (σ : genv).
Module canonical_tu.
  Definition im_to_gmap {V} (m : IM.t V) : gmap BS.t V :=
    list_to_map (map_to_list m).
  Definition symbol_table_canon : Set := gmap BS.t ObjValue.
  Definition type_table_canon : Set := gmap BS.t GlobDecl.

  Instance symbol_table_canon_eq_dec : EqDecision symbol_table_canon.
  Proof. solve_decision. Qed.
  Instance type_table_canon_eq_dec : EqDecision type_table_canon.
  Proof. solve_decision. Qed.

  Record translation_unit_canon : Set := Build_translation_unit_canon
  { symbols    : symbol_table_canon
  ; globals    : type_table_canon
  ; byte_order : endian
  }.
  Instance translation_unit_canon_eq_dec : EqDecision translation_unit_canon.
  Proof. solve_decision. Qed.

  Instance symbol_canon_lookup : Lookup obj_name ObjValue translation_unit_canon :=
    fun k m => m.(symbols) !! k.

  Record genv_canon : Set := Build_genv_canon
  { genv_tu : translation_unit_canon
    (* ^ the [translation_unit] *)
  ; pointer_size_bitsize : bitsize
    (* ^ the size of a pointer *)
  }.
  Instance genv_canon_eq_dec : EqDecision genv_canon.
  Proof. solve_decision. Qed.

  Definition tu_to_canon (tu : translation_unit) : translation_unit_canon :=
    let (s, g, bo) := tu in Build_translation_unit_canon (im_to_gmap s) (im_to_gmap g) bo.
  Local Definition genv_to_canon (σ : genv) : genv_canon :=
    let (tu, sz) := σ in Build_genv_canon (tu_to_canon tu) sz.
End canonical_tu.

Definition null_alloc_id : alloc_id := MkAllocId 0.
Definition invalid_alloc_id : alloc_id := MkAllocId 1.

(** Compute the actual raw offsets in Z. *)
Section eval_offset_seg.
  Context (σ : genv).
  Definition o_field_off (f : field) : option Z := offset_of σ f.(f_type) f.(f_name).
  Definition o_sub_off ty z : option Z := Z.mul z <$> (Z.of_N <$> size_of σ ty).
  Definition o_base_off derived base : option Z := parent_offset σ derived base.
  Definition o_derived_off base derived : option Z := Z.opp <$> parent_offset σ derived base.
End eval_offset_seg.

(*
Utility function, used to emulate [global_ptr] without a linker.
This is a really bad model and it'd fail a bunch of sanity checks.

Caveat: a model this to model [global_ptr] isn't correct, beyond proving
[global_ptr]'s isn't contradictory.
This model would fail proving that [global_ptr] is injective, that objects
are disjoint, or that
[global_ptr tu1 "staticR" |-> anyR T 1%Qp  ... ∗
  global_ptr tu2 "staticR" |-> anyR T 1%Qp  ...] actually holds at startup.
*)
Local Definition global_ptr_encode_ov (o : obj_name) (obj : option ObjValue) :
    option (alloc_id * vaddr) :=
  match obj with
  | Some _ => let p := Npos (encode o) in Some (MkAllocId p, p)
  | None => None
  end.

Module Import address_sums.
  Definition offset_vaddr : Z -> vaddr -> option vaddr := λ z pa,
    let sum : Z := (Z.of_N pa + z)%Z in
    guard (0 ≤ sum)%Z; Some (Z.to_N sum).

  Lemma offset_vaddr_eq z pa :
    let sum := (Z.of_N pa + z)%Z in
    (0 ≤ sum)%Z ->
    offset_vaddr z pa = Some (Z.to_N sum).
  Proof. rewrite /offset_vaddr/= => /= Hle. rewrite option_guard_True //. Qed.

  Lemma offset_vaddr_eq' {z pa} :
    offset_vaddr z pa <> None ->
    offset_vaddr z pa = Some (Z.to_N (Z.of_N pa + z)).
  Proof. rewrite /offset_vaddr/= => /=. case_option_guard; naive_solver. Qed.

  Lemma offset_vaddr_0 pa :
    offset_vaddr 0 pa = Some pa.
  Proof. rewrite offset_vaddr_eq Z.add_0_r ?N2Z.id //. lia. Qed.

  Lemma offset_vaddr_combine {pa o o'} :
    offset_vaddr o pa <> None ->
    offset_vaddr o pa ≫= offset_vaddr o' = offset_vaddr (o + o') pa.
  Proof.
    rewrite /offset_vaddr => Hval.
    by case_option_guard; rewrite /= Z.add_assoc ?Z2N.id.
  Qed.
End address_sums.

(* Very incomplete set of monadic liftings, currently unexported. *)
Definition liftA2 `{MRet M, MBind M} `(f : A → B → C) : M A → M B → M C :=
  λ mx my,
    x ← mx; y ← my; mret (f x y).

Definition bindM2 `{MBind M} `(f : A → B → M C) : M A → M B → M C :=
  λ mx my,
    x ← mx; y ← my; f x y.

(*
A slightly better model might be something like the following, but we don't
bother defining this [Countable] instance. And this is not a great model
anyway. *)

(*
Declare Instance ObjValue_countable: Countable ObjValue.
Definition global_ptr (tu : translation_unit) (o : obj_name) : ptr :=
  let obj : option ObjValue := tu !! o in
  let p := Npos (encode obj) in (mkptr p p).
*)

(**
A simple consistency proof for [PTRS]; this one is inspired by Cerberus's
model of pointer provenance, and resembles CompCert's model.

Compared to our "real" consistency proof [PTRS_IMPL], this proof is easier to
extend, but it's unclear how to extend it to support [VALID_PTR_AXIOMS].
*)
Module SIMPLE_PTRS_IMPL : PTRS.
  Import address_sums.

  Definition ptr' : Set := alloc_id * option vaddr.
  Definition ptr : Set := option ptr'.

  Declare Scope ptr_scope.
  Bind Scope ptr_scope with ptr.
  Delimit Scope ptr_scope with ptr.

  Definition ptr_alloc_id : ptr -> option alloc_id := fmap fst.
  Definition ptr_vaddr : ptr -> option vaddr := mbind snd.

  Definition invalid_ptr : ptr := None.
  Definition mkptr a n : ptr := Some (a, Some n).
  Definition nullptr : ptr := mkptr null_alloc_id 0.

  Instance ptr_eq_dec : EqDecision ptr := _.
  Instance ptr_countable : Countable ptr := _.
  Definition ptr_eq_dec' := ptr_eq_dec.

  (* lift [offset_vaddr] over the [alloc_id * _] monad. *)
  Definition offset_ptr' : Z -> ptr' -> ptr :=
    λ z p,
    (* This use of projections in intentional, to get better reduction behavior *)
    let aid := fst p in let pa := snd p in
    Some (aid, pa ≫= offset_vaddr z).
  Arguments offset_ptr' _ !_ /.

  Lemma offset_ptr_combine' p o o' :
    ptr_vaddr (offset_ptr' o p) <> None ->
    offset_ptr' o p ≫= offset_ptr' o' = offset_ptr' (o + o') p.
  Proof.
    case: p => [a [p|]] //= Hval.
    by rewrite (offset_vaddr_combine Hval).
  Qed.

  Definition offset_ptr__ : Z -> ptr -> ptr :=
    λ z p, p ≫= offset_ptr' z.
  Notation offset_ptr_ := offset_ptr__.

  Lemma offset_ptr_0__ p : offset_ptr_ 0 p = p.
  Proof. case: p => [[a [p|//]]|//] /=. by rewrite offset_vaddr_0. Qed.

  Lemma offset_ptr_combine {p o o'} :
    offset_ptr_ o p <> invalid_ptr ->
    offset_ptr_ o' (offset_ptr_ o p) = offset_ptr_ (o + o') p.
  Proof. case: p => // p. exact: offset_ptr_combine'. Qed.

  (* This list is reversed.
  The list of offsets in [[p; o_1; ...; o_n]] is represented as [[o_n; ... o_1]].
  This way, we can cons new offsets to the head, and consume them at the tail. *)
  Definition offset := list (option Z).
  Declare Scope offset_scope.
  Bind Scope offset_scope with offset.
  Delimit Scope offset_scope with offset.

  Local Instance offset_eq_dec : EqDecision offset := _.
  Instance offset_countable : Countable offset := _.

  Definition mkOffset : Z -> offset := λ z, [Some z].
  Definition o_id : offset := [].
  Definition o_dot : offset → offset → offset := flip (++).
  Notation "o1 .., o2" := (o_dot o1 o2) : offset_scope.

  Definition _offset_ptr_single : option Z -> ptr -> ptr :=
    λ oz p, z ← oz; offset_ptr_ z p.
  Definition _offset_ptr : ptr -> offset -> ptr :=
    foldr _offset_ptr_single.
  Notation "p .., o" := (_offset_ptr p o) : ptr_scope.

  Instance dot_id : RightId (=) o_id o_dot := _.
  Instance id_dot : LeftId (=) o_id o_dot := _.
  Instance dot_assoc : Assoc (=) o_dot := _.

  Lemma offset_ptr_dot p o1 o2 :
    (p .., (o1 .., o2) = p .., o1 .., o2)%ptr.
  Proof. apply foldr_app. Qed.

  Local Lemma ptr_alloc_id_offset_single {p oz} :
    let p' := _offset_ptr_single oz p in
    is_Some (ptr_alloc_id p') -> ptr_alloc_id p' = ptr_alloc_id p.
  Proof.
    rewrite /_offset_ptr_single /offset_ptr_ /offset_ptr'.
    (* XXX messy? good enough? *)
    have ? := @is_Some_None alloc_id.
    case: oz p => [z|//] [[aid' va]|] Hsome //=; simplify_option_eq.
    destruct fmap eqn:? => //; simplify_option_eq.
    naive_solver.
  Qed.

  Lemma ptr_alloc_id_offset {p o} :
    let p' := (p .., o)%ptr in
    is_Some (ptr_alloc_id p') -> ptr_alloc_id p' = ptr_alloc_id p.
  Proof.
    elim: o p => /= [//|o os IHo] p Hs.
    rewrite -(IHo p) //. { exact: ptr_alloc_id_offset_single. }
    by rewrite -(ptr_alloc_id_offset_single (oz := o)).
  Qed.

  Definition opt_to_off oo : offset := [oo].
  Definition o_field σ f : offset := opt_to_off (o_field_off σ f).
  Definition o_sub σ ty z : offset := opt_to_off (o_sub_off σ ty z).
  Definition o_base σ derived base := opt_to_off (o_base_off σ derived base).
  Definition o_derived σ base derived := opt_to_off (o_derived_off σ base derived).

  Lemma offset_ptr_cancel {p} {o1 o2 : Z} o3
    (Hval : offset_ptr_ o1 p ≠ None) (Hsum : (o1 + o2 = o3)%Z) :
    offset_ptr_ o2 (offset_ptr_ o1 p) = (offset_ptr_ o3 p).
  Proof. by rewrite (offset_ptr_combine Hval) Hsum. Qed.

  Lemma offset_ptr_cancel0 (o1 o2 : Z) p
    (Hval : offset_ptr_ o1 p ≠ None) (Hsum : (o1 + o2 = 0)%Z) :
    offset_ptr_ o2 (offset_ptr_ o1 p) = p.
  Proof. by rewrite (offset_ptr_cancel 0 Hval Hsum) offset_ptr_0__. Qed.

  (* Lemma o_cancel_raw {p o1 o2} o3 :
    (z1 → o1 + o2 = o3)%Z →
    (p .., [o1] ≠ None)%ptr →
    (p .., [o1] .., [o2] = p .., [o3])%ptr.
  Proof.
    case: o1 o2 o3 => [o1|//] [o2|//=] [o3|//] Hval.
    rewrite /_offset_ptr_single/=.
    rewrite (offset_ptr_cancel o3) //. *)
    (* rewrite offset_ptr_cancel. *)

  Lemma o_base_derived_raw σ p derived base :
    (p .., o_base σ derived base)%ptr <> invalid_ptr ->
    (p .., o_base σ derived base .., o_derived σ base derived = p)%ptr.
  Proof.
    rewrite /o_base /= /o_base_off /o_derived_off.
    case: parent_offset => [o|] //= Hval.
    apply: offset_ptr_cancel0; by [|lia].
  Qed.

  Lemma o_derived_base_raw σ p derived base :
    (p .., o_derived σ base derived)%ptr <> invalid_ptr ->
    (p .., o_derived σ base derived .., o_base σ derived base = p)%ptr.
  Proof.
    rewrite /o_base /= /o_base_off /o_derived_off.
    case: parent_offset => [o|] //= Hval.
    apply: offset_ptr_cancel0; by [|lia].
  Qed.

  Lemma o_sub_sub_raw σ p ty n1 n2 :
    (p .., o_sub σ ty n1 <> None)%ptr ->
    (p .., o_sub σ ty n1 .., o_sub σ ty n2 = p .., o_sub σ ty (n1 + n2))%ptr.
  Proof.
    rewrite /o_sub /= /o_sub_off.
    case: size_of => [o|] //= Hval.
    apply: offset_ptr_cancel; by [|lia].
  Qed.

  (* Caveat: This model of [global_ptr] isn't correct, beyond proving
  [global_ptr]'s isn't contradictory.
  This model would fail proving that [global_ptr] is injective, that objects
  are disjoint, or that
  [global_ptr tu1 "staticR" |-> anyR T 1%Qp  ... ∗
   global_ptr tu2 "staticR" |-> anyR T 1%Qp  ...] actually holds at startup.
  *)
  Definition global_ptr (tu : translation_unit) (o : obj_name) : ptr :=
    global_ptr_encode_ov o (tu !! o).

  Definition fun_ptr := global_ptr.
  Lemma o_sub_0 σ ty n :
    size_of σ ty = Some n ->
    o_sub σ ty 0 = o_id.
  Proof. rewrite /o_sub /o_sub_off /opt_to_off => -> //=. rewrite Z.mul_0_l. Admitted.

End SIMPLE_PTRS_IMPL.

Module Import merge_elems.
Section merge_elem.
  Context {X} (f : X -> X -> list X).
  Definition merge_elem (x0 : X) (xs : list X) : list X :=
    match xs with
    | x1 :: xs' => f x0 x1 ++ xs'
    | [] => [x0]
    end.
  Lemma merge_elem_nil x0 : merge_elem x0 [] = [x0].
  Proof. done. Qed.
  Lemma merge_elem_cons x0 x1 xs : merge_elem x0 (x1 :: xs) = f x0 x1 ++ xs.
  Proof. done. Qed.

  Definition merge_elems_aux : list X -> list X -> list X := foldr merge_elem.
  Local Arguments merge_elems_aux _ !_ /.
  Definition merge_elems : list X -> list X := merge_elems_aux [].
  Local Arguments merge_elems !_ /.
  Lemma merge_elems_cons x xs :
    merge_elems (x :: xs) = merge_elem x (merge_elems xs).
  Proof. done. Qed.
  Lemma merge_elems_aux_app ys xs1 xs2 :
    merge_elems_aux ys (xs1 ++ xs2) = merge_elems_aux (merge_elems_aux ys xs2) xs1.
  Proof. apply foldr_app. Qed.
  Lemma merge_elems_app xs1 xs2 :
    merge_elems (xs1 ++ xs2) = merge_elems_aux (merge_elems xs2) xs1.
  Proof. apply merge_elems_aux_app. Qed.
End merge_elem.
End merge_elems.

(**
Another (incomplete) consistency proof for [PTRS], based on Krebbers' PhD thesis, and
other formal models of C++ using structured pointers.
This is more complex than [SIMPLE_PTRS_IMPL], but will be necessary to justify [VALID_PTR_AXIOMS].

In both of our models, all valid pointers are pinned, but this is not meant
to be guaranteed.
*)
Module PTRS_IMPL : PTRS.
  Import canonical_tu.

  Inductive raw_offset_seg : Set :=
  | o_field_ (* type-name: *) (f : field)
  | o_sub_ (ty : type) (z : Z)
  | o_base_ (derived base : globname)
  | o_derived_ (base derived : globname)
  (* deprecated *)
  | o_num_ (z : Z)
  | o_invalid.
  Local Instance raw_offset_seg_eq_dec : EqDecision raw_offset_seg.
  Proof. solve_decision. Qed.
  Declare Instance raw_offset_seg_countable : Countable raw_offset_seg.
  Definition offset_seg : Set := raw_offset_seg * Z.
  Local Instance offset_seg_eq_dec : EqDecision offset_seg := _.
  Local Instance offset_seg_countable : Countable offset_seg := _.

  Definition eval_raw_offset_seg σ (ro : raw_offset_seg) : option Z :=
    match ro with
    | o_num_ z => Some z
    | o_field_ f => o_field_off σ f
    | o_sub_ ty z => o_sub_off σ ty z
    | o_base_ derived base => o_base_off σ derived base
    | o_derived_ base derived => o_derived_off σ base derived
    | o_invalid => None
    end.
  Definition mk_offset_seg σ (ro : raw_offset_seg) : offset_seg :=
    match eval_raw_offset_seg σ ro with
    | None => (o_invalid, 0%Z)
    | Some off => (ro, off)
    end.

  (* This list is reversed.
  The list of offsets in [[p; o_1; ...; o_n]] is represented as [[o_n; ... o_1]].
  This way, we can cons new offsets to the head, and consume them at the tail. *)
  Definition raw_offset := list offset_seg.
  Local Instance raw_offset_eq_dec : EqDecision offset := _.
  Local Instance raw_offset_countable : Countable raw_offset := _.

  Definition offset_seg_merge (os1 os2 : offset_seg) : list offset_seg :=
    match os1, os2 with
    | (o_sub_ ty1 n1, off1), (o_sub_ ty2 n2, off2) =>
      if decide (ty1 = ty2)
      then [(o_sub_ ty1 (n2 + n1), (off1 + off2)%Z)]
      else [os2; os1]
    | (o_base_ der1 base1, off1), (o_derived_ base2 der2, off2) =>
      if decide (der1 = der2 ∧ base1 = base2)
      then []
      else [os2; os1]
    | (o_num_ z1, off1), (o_num_ z2, off2) =>
      [(o_num_ (z2 + z1), (off1 + off2)%Z)]
    | _, _ => [os2; os1]
    end.

  Definition raw_offset_collapse : raw_offset -> raw_offset :=
    merge_elems (flip offset_seg_merge).
  Arguments raw_offset_collapse !_ /.
  Definition raw_offset_wf (ro : raw_offset) : Prop :=
    raw_offset_collapse ro = ro.
  Instance raw_offset_wf_pi ro : ProofIrrel (raw_offset_wf ro) := _.
  Lemma singleton_raw_offset_wf {os} : raw_offset_wf [os].
  Proof. done. Qed.

  Definition raw_offset_merge (o1 o2 : raw_offset) : raw_offset :=
    raw_offset_collapse (o1 ++ o2).
  Arguments raw_offset_merge !_ _ /.

  Definition offset := {ro : raw_offset | raw_offset_wf ro}.
  Instance offset_eq_dec : EqDecision offset := _.

  Local Definition raw_offset_to_offset (ro : raw_offset) : option offset :=
    match decide (raw_offset_wf ro) with
    | left Hwf => Some (exist _ ro Hwf)
    | right _ => None
    end.
  Instance offset_countable : Countable offset.
  Proof.
    apply (inj_countable proj1_sig raw_offset_to_offset) => -[ro Hwf] /=.
    rewrite /raw_offset_to_offset; case_match => //.
    by rewrite (proof_irrel Hwf).
  Qed.

  Program Definition o_id : offset := [] ↾ _.
  Next Obligation. done. Qed.
  Program Definition mkOffset σ (ro : raw_offset_seg) : offset :=
    [mk_offset_seg σ ro] ↾ singleton_raw_offset_wf.
  Definition o_field σ f : offset :=
    mkOffset σ (o_field_ f).
  Definition o_sub σ ty z : offset :=
    mkOffset σ (o_sub_ ty z).
  Definition o_base σ derived base : offset :=
    mkOffset σ (o_base_ derived base).
  Definition o_derived σ base derived : offset :=
    mkOffset σ (o_derived_ base derived).
  Definition o_num z : offset :=
    [(o_num_ z, z)] ↾ singleton_raw_offset_wf.

  Lemma last_last_equiv {X} d {xs : list X} : default d (stdpp.list.last xs) = List.last xs d.
  Proof. elim: xs => // x1 xs /= <-. by case_match. Qed.

  Class InvolApp {X} (f : list X → list X) :=
    invol_app : ∀ xs1 xs2,
    f (xs1 ++ xs2) = f (f xs1 ++ f xs2).
  Class Involutive {X} (f : X → X) :=
    invol : ∀ x, f (f x) = f x.

  Section merge_elem.
    Context {X} (f : X -> X -> list X).
    Context (Hinv : ∀ x1 x2, merge_elems f (f x1 x2) = f x1 x2).

(*
    Lemma foo xs ys :
      merge_elems (merge_elems ys) = merge_elems ys ->
      merge_elems (merge_elems_aux (merge_elems ys) xs) =
      merge_elems_aux (merge_elems ys) xs.
    Proof.
      move: xs.
      induction ys => //= xs Hys.
      Restart.
      move: ys.
      (* induction xs => //= ys Hys. *)
      rewrite /merge_elems.
      (* induction xs => //= ys Hys.
      rewrite -IHxs // -/merge_elems.
      rewrite -merge_elems_app /=.

      rewrite -/merge_elems in Hys IHxs *.
      rewrite -Hys merge_elems_aux_app -/merge_elems. *)

      induction xs using rev_ind => //= ys Hys.
      rewrite merge_elems_aux_app -/merge_elems.
      rewrite /merge_elems.
      (* rewrite -Hys merge_elems_aux_app -/merge_elems. *)
      *)


    Global Instance: Involutive (merge_elems f).
    Proof.
      unfold Involutive.
      intros xs. induction xs using rev_ind => //.
      rewrite merge_elems_app.
      (* elim => [//|x xs IHxs /=]. *)
      case E: (merge_elems f xs) => [//|y ys /=].
      (* case => [//|x xs /=].
      (* elim E: (merge_elems xs) => [//|y ys IHys /=]. *)
      move E: (merge_elems xs) => ys.
      elim: ys xs E => [//|y ys IHys xs E /=]. *)
    Admitted.


    Lemma foo x xs :
      merge_elems f (merge_elems f (x :: xs)) = merge_elem f x (merge_elems f xs).
    Proof.
      case: xs => //= x' xs.
      rewrite /merge_elem.

      case_match => //.
      rewrite -{2}Hinv.

      case_match => //; simplify_list_eq.
      by destruct xs.
      inversion Heql0.
    Abort.
    (* Lemma involutive_merge_elems : Involutive merge_elems
    with invol_app_merge_elems : InvolApp merge_elems. *)
    Lemma involutive_merge_elems xs : merge_elems f (merge_elems f xs) = merge_elems f xs
    with invol_app_merge_elems xs1 xs2 :
      merge_elems f (xs1 ++ xs2) = merge_elems f (merge_elems f xs1 ++ merge_elems f xs2).
    Proof.
      - elim: xs => [//|x xs IHxs /=].
        rewrite -{2}IHxs.
        case E: (merge_elems f xs) => [//|y ys /=].
        (* Guarded. *)
        rewrite invol_app_merge_elems.
        (* Fail Guarded. *)
        case: ys E => [//|y' ys'] /= E.
        +
        rewrite !app_nil_r.
        case E1: (f x y) => [//|fx fxs] /=.
        rewrite E /= in IHxs.
    Admitted.


    Global Instance: Involutive (merge_elems f).
    Proof.
      elim => [//|x xs IHxs /=].
      case E: (merge_elems f xs) => [//|y ys /=].
      (* case => [//|x xs /=].
      (* elim E: (merge_elems xs) => [//|y ys IHys /=]. *)
      move E: (merge_elems xs) => ys.
      elim: ys xs E => [//|y ys IHys xs E /=]. *)
    Admitted.
    Global Instance: InvolApp (merge_elems f).
    Proof.
      elim => [|x1 xs1 IHxs1] xs2 /=.
      - by rewrite invol.
      -
      case E: (merge_elems f xs1) IHxs1 => [//|x' xs' //=] IHxs1.
      by rewrite IHxs1.
      rewrite IHxs1 -app_assoc. rewrite -merge_elem_cons //.
      rewrite /merge_elems /=.

      (* Search foldr cons.
      Search _ fold_right -Equivalence. *)
    Admitted.
  End merge_elem.
  Local Arguments merge_elems {X} f !_ /.

  Definition offset_seg_append : offset_seg -> raw_offset -> raw_offset :=
    merge_elem (flip offset_seg_merge).

  Lemma offset_seg_merge_inv :
    let f := (flip offset_seg_merge) in
    ∀ x1 x2, raw_offset_collapse (f x1 x2) = f x1 x2.
  Proof.
    move=> /= [o1 off1] [o2 off2].
    destruct o1, o2 => //=; by repeat (case_decide; simpl).
  Qed.
  Lemma foo2 x1 x2 :
    raw_offset_collapse (raw_offset_collapse [x1; x2]) = raw_offset_collapse [x1; x2].
  Proof.
    rewrite /= app_nil_r.
    apply: offset_seg_merge_inv.
  Qed.
  Lemma foo3 x1 x2 x3 :
    raw_offset_collapse (raw_offset_collapse [x1; x2; x3]) = raw_offset_collapse [x1; x2; x3].
  Proof.
    rewrite /= app_nil_r /= /flip.
    move: x1 x2 x3 => [o1 ?] [o2 ?] [o3 ?].
    destruct o1, o2, o3 => //=.
    all: by repeat (case_decide; simpl).
  Qed.
  Instance: Involutive raw_offset_collapse.
  Proof.
    move=> xs.
    rewrite /raw_offset_collapse /merge_elems/=.
    induction xs=> //=.
    (* rewrite foldr_app /=.
    (* move: {2 3}[] => ys. *)
    induction xs using rev_ind => //=.
    rewrite foldr_app /=.
    case: xs => // x1 [//|x2 [//|x3 xs]]; first exact: foo2.
    rewrite /= /raw_offset_collapse /merge_elems /merge_elem /=. etrans. apply: offset_seg_merge_inv. *)
  Abort.

  Local Definition test xs :=
    raw_offset_collapse (raw_offset_collapse xs) = raw_offset_collapse xs.

  Section tests.
    Ltac start := intros; red; simpl.
    Ltac step_true := rewrite ?decide_True //=.
    Ltac step_false := rewrite ?decide_False //=.
    Ltac res_true := start; repeat step_true.
    Ltac res_false := start; repeat step_false.

    Goal test []. Proof. res_true. Qed.
    Goal `{test [(o_sub_ ty n1, o1)] }. Proof. done. Qed.
    Goal `{test [(o_sub_ ty n1, o1); (o_sub_ ty n2, o2)] }.
    Proof. res_true. Qed.

    Goal `{test [(o_sub_ ty n1, o1); (o_sub_ ty n2, o2); (o_field_ f, o3)] }.
    Proof. res_true. Qed.

    Goal `{test [(o_field_ f, o1); (o_sub_ ty n1, o2); (o_sub_ ty n2, o3)] }.
    Proof. res_true. Qed.

    Goal `{ty1 ≠ ty2 → test [(o_sub_ ty1 n1, o1); (o_sub_ ty2 n2, o2); (o_field_ f, o3)] }.
    Proof. res_false. Qed.

    Goal `{ty1 ≠ ty2 → test [(o_sub_ ty1 n1, o1); (o_sub_ ty1 n2, o2); (o_sub_ ty2 n3, o3); (o_field_ f, o4)] }.
    Proof. start. step_false. step_true. step_false. Qed.
  End tests.

(*
  Instance: InvolApp raw_offset_collapse.
  Proof.
    rewrite /raw_offset_collapse.
    elim => [|x1 xs1 IHxs1] xs2 /=.
    - admit.
    - rewrite IHxs1.
    Search foldr nil.
  Admitted. *)

  Instance raw_offset_collapse_involutive : Involutive raw_offset_collapse := _.
  (* Lemma raw_offset_collapse_involutive ro :
    raw_offset_collapse (raw_offset_collapse ro) = raw_offset_collapse ro.
  Proof. apply invol. Qed. *)
(*
    (* elim: ro => // os1 [//|os2 ro] /= IHro. *)
    elim: ro => // os ro /= IHro.
    (* rewrite {1}/raw_offset_collapse {1}/offset_seg_append /=.
    rewrite (_ : offset_seg_append os (raw_offset_collapse ro) = *)
  (* Admitted. *)

    (* (offset_seg_append os (raw_offset_collapse ro)) *)
    rewrite {1}/raw_offset_collapse.
    (* elim: os. *)
  Admitted. *)


  (* This is probably sound, since it allows temporary underflows. *)
  (* Section eval_offset.
    (* From PTR_INTERNAL *)
    Definition eval_raw_offset (σ : genv) (o : raw_offset) : option Z :=
      foldr (liftA2 Z.add) (Some 0%Z) (eval_offset_seg σ <$> o).
    Definition eval_offset (σ : genv) (o : offset) : option Z := eval_raw_offset σ (`o).
  End eval_offset. *)

  Program Definition o_dot : offset → offset → offset :=
    λ o1 o2, (raw_offset_merge (proj1_sig o1) (proj1_sig o2)) ↾ _.
  Next Obligation.
    move=> o1 o2 /=.
    exact: raw_offset_collapse_involutive.
  Qed.
  Inductive root_ptr : Set :=
  | nullptr_
  | global_ptr_ (tu : translation_unit_canon) (o : obj_name)
  | alloc_ptr_ (a : alloc_id) (va : vaddr).

  Local Instance root_ptr_eq_dec : EqDecision root_ptr.
  Proof. solve_decision. Qed.
  Declare Instance root_ptr_countable : Countable root_ptr.

  Local Definition global_ptr_encode_canon
    (tu : translation_unit_canon) (o : obj_name) : option (alloc_id * vaddr) :=
    global_ptr_encode_ov o (tu !! o).

  Definition root_ptr_alloc_id (rp : root_ptr) : option alloc_id :=
    match rp with
    | nullptr_ => Some null_alloc_id
    | global_ptr_ tu o => fst <$> global_ptr_encode_canon tu o
    | alloc_ptr_ aid _ => Some aid
    end.

  Definition root_ptr_vaddr (rp : root_ptr) : option vaddr :=
    match rp with
    | nullptr_ => Some 0%N
    | global_ptr_ tu o => snd <$> global_ptr_encode_canon tu o
    | alloc_ptr_ aid va => Some va
    end.

  Inductive ptr_ : Set :=
  | invalid_ptr_
  | fun_ptr_ (tu : translation_unit_canon) (o : obj_name)
  | offset_ptr (p : root_ptr) (o : offset).
  Definition ptr := ptr_.
  Local Instance ptr_eq_dec : EqDecision ptr.
  Proof. solve_decision. Qed.
  Declare Instance ptr_countable : Countable ptr.

  Definition ptr_alloc_id (p : ptr) : option alloc_id :=
    match p with
    | invalid_ptr_ => None
    | fun_ptr_ tu o => fst <$> global_ptr_encode_canon tu o
    | offset_ptr p o => root_ptr_alloc_id p
    end.

  Definition ptr_vaddr (p : ptr) : option vaddr :=
    match p with
    | invalid_ptr_ => None
    | fun_ptr_ tu o => snd <$> global_ptr_encode_canon tu o
    | offset_ptr p o =>
      foldr
        (λ off ova, ova ≫= offset_vaddr off)
        (root_ptr_vaddr p)
        (snd <$> `o)
    end.

  Definition lift_root_ptr (rp : root_ptr) : ptr := offset_ptr rp o_id.
  Definition invalid_ptr := invalid_ptr_.
  Definition fun_ptr tu o := fun_ptr_ (canonical_tu.tu_to_canon tu) o.

  Definition nullptr := lift_root_ptr nullptr_.
  Definition global_ptr (tu : translation_unit) o :=
    lift_root_ptr (global_ptr_ (canonical_tu.tu_to_canon tu) o).
  Definition alloc_ptr a oid := lift_root_ptr (alloc_ptr_ a oid).

  Instance id_dot : LeftId (=) o_id o_dot.
  Proof. intros o. apply /sig_eq_pi. by case: o. Qed.
  Instance dot_id : RightId (=) o_id o_dot.
  Proof.
    intros o. apply /sig_eq_pi.
    rewrite /= /raw_offset_merge (right_id []).
    by case: o.
  Qed.
  Local Instance dot_assoc : Assoc (=) o_dot.
  Proof.
    intros o1 o2 o3. apply /sig_eq_pi.
    move: o1 o2 o3 => [ro1 /= wf1]
      [ro2 /= wf2] [ro3 /= wf3].
      rewrite /raw_offset_merge.
      rewrite -{1}wf1 -{2}wf3.
      rewrite -!invol_app; f_equiv.
      apply: assoc.
  Qed.

  Local Instance ptr_eq_dec' : EqDecision ptr := ptr_eq_dec.

  (* Instance ptr_equiv : Equiv ptr := (=).
  Instance offset_equiv : Equiv offset := (=).
  Instance ptr_equivalence : Equivalence (≡@{ptr}) := _.
  Instance offset_equivalence : Equivalence (==@{offset}) := _.
  Instance ptr_equiv_dec : RelDecision (≡@{ptr}) := _.
  Instance offset_equiv_dec : RelDecision (==@{offset}) := _. *)

  (* Instance dot_assoc : Assoc (≡) o_dot := _. *)
  (* Instance dot_proper : Proper ((≡) ==> (≡) ==> (≡)) o_dot := _. *)


  Declare Scope ptr_scope.
  Bind Scope ptr_scope with ptr.
  Delimit Scope ptr_scope with ptr.

  Declare Scope offset_scope.
  Bind Scope offset_scope with offset.
  Delimit Scope offset_scope with offset.
  Notation "o1 .., o2" := (o_dot o1 o2) : offset_scope.

  Definition _offset_ptr p o :=
    match p with
    | offset_ptr p' o' => offset_ptr p' (o' .., o)
    | invalid_ptr_ => invalid_ptr_
    | fun_ptr_ _ _ => invalid_ptr_
    end.
  (* Instance offset_ptr_proper : Proper ((≡) ==> (≡) ==> (≡)) _offset_ptr := _. *)
  Notation "p .., o" := (_offset_ptr p o) : ptr_scope.

  Lemma offset_ptr_dot p o1 o2 :
    (p .., (o1 .., o2) = p .., o1 .., o2)%ptr.
  Proof. by destruct p; rewrite //= assoc. Qed.

  Definition offset_ptr__ (z : Z) (p : ptr) : ptr :=
    (* _offset_ptr p [o_num_ z] *)
    if decide (z = 0)%Z
    then p
    else _offset_ptr p (o_num z).
  Notation offset_ptr_ := offset_ptr__.
  Definition offset_ptr_0__ b : offset_ptr_ 0 b = b := reflexivity _.
  Lemma offset_ptr_combine p o o' :
    offset_ptr_ o p <> invalid_ptr ->
    offset_ptr_ o' (offset_ptr_ o p) = offset_ptr_ (o + o') p.
  Proof.
    rewrite /offset_ptr__.
    Arguments _offset_ptr _ !_ /.
    repeat (case_decide; rewrite ->?Z.add_0_r in *; subst => //=).
    - destruct p => //=; admit.
    - destruct p => //=.
  Admitted.

  (* XXX False. *)
  Lemma o_sub_0 σ ty n :
    size_of σ ty = Some n ->
    o_sub σ ty 0 = o_id.
  Proof. rewrite /o_sub/o_id/=. Admitted.

  Lemma ptr_alloc_id_offset {p o} :
    let p' := (p .., o)%ptr in
    is_Some (ptr_alloc_id p') -> ptr_alloc_id p' = ptr_alloc_id p.
  Admitted.
End PTRS_IMPL.
