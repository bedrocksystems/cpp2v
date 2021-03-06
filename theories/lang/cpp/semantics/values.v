(*
 * Copyright (c) 2020 BedRock Systems, Inc.
 * This software is distributed under the terms of the BedRock Open-Source License.
 * See the LICENSE-BedRock file in the repository root for details.
 *)

(** The "operational" style definitions about C++ values. *)
From Coq Require Import Strings.Ascii.
Require Import stdpp.gmap.

From bedrock.lang.prelude Require Import base addr option numbers.

Require Import bedrock.lang.cpp.arith.builtins.
Require Import bedrock.lang.cpp.ast.
From bedrock.lang.cpp.semantics Require Export types sub_module genv ptrs.

Local Close Scope nat_scope.
Local Open Scope Z_scope.
Implicit Types (σ : genv).

Module Type RAW_BYTES.
  (** * Raw bytes
      Raw bytes represent the low-level view of data.
      [raw_byte] abstracts over the internal structure of this low-level view of data.
      E.g. in the [simple_pred] model, [raw_byte] would be instantiated with [runtime_val].

      [raw_int_byte] is a raw byte that is a concrete integer values (i.e. not a
      pointer fragment or poison).
   *)
  Parameter raw_byte : Set.
  Parameter raw_byte_eq_dec : EqDecision raw_byte.
  Existing Instance raw_byte_eq_dec.

  Axiom raw_int_byte : N -> raw_byte.

(* TODO: refine our treatment of `raw_bytes` s.t. we respect
     the size constraints imposed by the physical hardware.

     The following might help but will likely require other
     axioms which reflect boundedness or round-trip properties.


  Parameter of_raw_byte : raw_byte -> N.
  Axiom inj_of_raw_byte : Inj (=) (=) of_raw_byte.
  #[global] Existing Instance inj_of_raw_byte.
*)
End RAW_BYTES.

Module Type VAL_MIXIN (Import P : PTRS) (Import R : RAW_BYTES).

(** * Values
    Primitive abstract C++ runtime values come in two flavors.
    - pointers (also used for references)
    - integers (used for everything else)
    Aggregates are not represented directly, but only by talking about
    primitive subobjects.

    There is also a distinguished undefined element [Vundef] that
    models uninitialized values (https://eel.is/c++draft/basic.indet).
    Operations on [Vundef] are all undefined behavior.
    [Vraw] (a raw byte) represents the low-level bytewise view of data.
    See [logic/layout.v] for more axioms about it.
 *)
Variant val : Set :=
| Vint (_ : Z)
| Vptr (_ : ptr)
| Vraw (_ : raw_byte)
| Vundef
.
#[global] Notation Vref := Vptr (only parsing).

Definition val_dec : forall a b : val, {a = b} + {a <> b}.
Proof. solve_decision. Defined.
#[global] Instance val_eq_dec : EqDecision val := val_dec.
#[global] Instance val_inhabited : Inhabited val := populate (Vint 0).

End VAL_MIXIN.

Module Type RAW_BYTES_VAL
       (Import P : PTRS) (Import R : RAW_BYTES)
       (Import V : VAL_MIXIN P R).
  (** [raw_bytes_of_val σ ty v rs] states that the value [v] of type
      [ty] is represented by the raw bytes in [rs]. What this means
      depends on the type [ty]. *)
  Parameter raw_bytes_of_val : genv -> type -> val -> list raw_byte -> Prop.

  Axiom raw_bytes_of_val_Proper : Proper (genv_leq ==> eq ==> eq ==> eq ==> iff) raw_bytes_of_val.
  #[global] Existing Instance raw_bytes_of_val_Proper.

  Axiom raw_bytes_of_val_unique_encoding : forall σ ty v rs rs',
      raw_bytes_of_val σ ty v rs -> raw_bytes_of_val σ ty v rs' -> rs = rs'.

  Axiom raw_bytes_of_val_int_unique_val : forall σ sz sgn z z' rs,
      raw_bytes_of_val σ (Tint sz sgn) (Vint z) rs ->
      raw_bytes_of_val σ (Tint sz sgn) (Vint z') rs ->
      z = z'.

  Axiom raw_bytes_of_val_sizeof : forall σ ty v rs,
      raw_bytes_of_val σ ty v rs -> size_of σ ty = Some (N.of_nat $ length rs).

  (* TODO Maybe add?
    Axiom raw_bytes_of_val_int : forall σ sz z rs,
        raw_bytes_of_val σ (Tint sz Unsigned) (Vint z) rs <->
        exists l,
          (_Z_from_bytes (genv_byte_order σ) Unsigned l = z) /\
          rs = raw_int_byte <$> l.
  *)

  (** [raw_bytes_of_struct σ cls rss rs] states that the struct
      consisting of fields of the raw bytes [rss] is represented by the
      raw bytes in [rs]. [rs] should agree with [rss] on the offsets of
      the fields. It might be possible to make some assumptions about the
      parts of [rs] that represent padding based on the ABI. *)
  (* TODO (JH): We should probably restrict this interface with some `Axiom`s. *)
  Parameter raw_bytes_of_struct :
    genv -> globname -> gmap ident (list raw_byte) -> list raw_byte -> Prop.
End RAW_BYTES_VAL.

Module Type RAW_BYTES_MIXIN
       (Import P : PTRS) (Import R : RAW_BYTES)
       (Import V : VAL_MIXIN P R)
       (Import RD : RAW_BYTES_VAL P R V).

  Inductive val_related : genv -> type -> val -> val -> Prop :=
  | Veq_refl σ ty v: val_related σ ty v v
  | Vqual σ t ty v1 v2:
      val_related σ ty v1 v2 ->
      val_related σ (Tqualified t ty) v1 v2
  | Vraw_uint8 σ raw z:
      raw_bytes_of_val σ (Tint W8 Unsigned) (Vint z) [raw] ->
      val_related σ (Tint W8 Unsigned) (Vraw raw) (Vint z)
  | Vuint8_raw σ z raw:
      raw_bytes_of_val σ (Tint W8 Unsigned) (Vint z) [raw] ->
      val_related σ (Tint W8 Unsigned) (Vint z) (Vraw raw).

  Lemma val_related_qual :
    forall σ t ty v1 v2,
      val_related σ ty v1 v2 ->
      val_related σ (Tqualified t ty) v1 v2.
  Proof. intros; by constructor. Qed.

  #[global] Instance val_related_reflexive σ ty : Reflexive (val_related σ ty).
  Proof. constructor. Qed.
  #[global] Instance val_related_symmetric σ ty : Symmetric (val_related σ ty).
  Proof.
    rewrite /Symmetric; intros * Hval_related;
      induction Hval_related; subst; by constructor.
  Qed.
  #[global] Instance val_related_transitive σ ty : Transitive (val_related σ ty).
  Proof.
    rewrite /Transitive; intros * Hval_related1;
      induction Hval_related1; intros * Hval_related2.
    - by auto.
    - constructor; apply IHHval_related1;
        inversion Hval_related2; subst;
        by [constructor | auto].
    - inversion Hval_related2; subst.
      + by constructor.
      + pose proof (raw_bytes_of_val_unique_encoding _ _ _ _ _ H H2) as Hraws.
        inversion Hraws; constructor.
    - inversion Hval_related2; subst.
      + by constructor.
      + pose proof (raw_bytes_of_val_int_unique_val _ _ _ _ _ _ H H2); subst.
        by constructor.
  Qed.
  #[global] Instance val_related_Proper : Proper (genv_leq ==> eq ==> eq ==> eq ==> iff) val_related.
  Proof.
    repeat red; intros; subst; split; intros.
    - induction H0; subst.
      + constructor.
      + constructor; auto.
      + setoid_rewrite H in H0; by constructor.
      + setoid_rewrite H in H0; by constructor.
    - induction H0; subst.
      + constructor.
      + constructor; auto.
      + setoid_rewrite <- H in H0; by constructor.
      + setoid_rewrite <- H in H0; by constructor.
  Qed.

  Lemma raw_bytes_of_val_uint_length : forall σ v rs sz sgn,
      raw_bytes_of_val σ (Tint sz sgn) v rs ->
      length rs = bytesNat sz.
  Proof.
    intros * Hraw_bytes_of_val.
    apply raw_bytes_of_val_sizeof in Hraw_bytes_of_val.
    inversion Hraw_bytes_of_val as [Hsz]; clear Hraw_bytes_of_val.
    by apply N_of_nat_inj in Hsz.
  Qed.
End RAW_BYTES_MIXIN.

(* Collect all the axioms. *)
Module Type PTRS_INTF_MINIMAL := PTRS <+ PTRS_DERIVED.
Module Type PTRS_INTF := PTRS_INTF_MINIMAL <+ RAW_BYTES <+ VAL_MIXIN <+ RAW_BYTES_VAL.
Declare Module PTRS_INTF_AXIOM : PTRS_INTF.

(* Plug mixins. *)
Module Type VALUES_FULL_INTF := PTRS_INTF <+ PTRS_MIXIN <+ RAW_BYTES_MIXIN.
Module Export VALUES_FULL_INTF_AXIOM : VALUES_FULL_INTF := PTRS_INTF_AXIOM <+ PTRS_MIXIN <+ RAW_BYTES_MIXIN.

Instance ptr_inhabited : Inhabited ptr := populate nullptr.

(** wrappers for constructing certain values *)
Definition Vchar (a : Ascii.ascii) : val :=
  Vint (Z.of_N (N_of_ascii a)).
Definition Vbool (b : bool) : val :=
  Vint (if b then 1 else 0).
Definition Vnat (b : nat) : val :=
  Vint (Z.of_nat b).
Definition Vn (b : N) : val :=
  Vint (Z.of_N b).
Notation Vz := Vint (only parsing).

(** we use [Vundef] as our value of type [void] *)
Definition Vvoid := Vundef.

Definition is_true (v : val) : option bool :=
  match v with
  | Vint v => Some (negb (Z.eqb v 0))
  | Vptr p => Some match ptr_eq_dec p nullptr with
                  | left _ => false
                  | right _ => true
                  end
  | Vundef | Vraw _ => None
  end.

Theorem is_true_int : forall i,
    is_true (Vint i) = Some (negb (BinIntDef.Z.eqb i 0)).
Proof. reflexivity. Qed.

Lemma Vptr_inj p1 p2 : Vptr p1 = Vptr p2 -> p1 = p2.
Proof. by move=> []. Qed.
Lemma Vint_inj a b : Vint a = Vint b -> a = b.
Proof. by move=> []. Qed.
Lemma Vbool_inj a b : Vbool a = Vbool b -> a = b.
Proof. by move: a b =>[] [] /Vint_inj. Qed.

#[global] Instance Vptr_Inj : Inj (=) (=) Vptr := Vptr_inj.
#[global] Instance Vint_Inj : Inj (=) (=) Vint := Vint_inj.
#[global] Instance Vbool_Inj : Inj (=) (=) Vbool := Vbool_inj.

(** * regions
    to model the stack frame in separation logic, we use a notion of regions
    that are threaded through the semantics.

    we instantiate [region] as a stack of finite maps from variables
    to their addresses.
 *)
Inductive region : Type :=
| Remp (this : option ptr) (_ : type)
| Rbind (_ : localname) (_ : ptr) (_ : region).

(** NOTE anonymous variables are not recorded in the environment.
 *)
Definition Rbind_check (x : ident) (p : ptr) (r : region) : region :=
  if decide (x = ""%bs)
  then r
  else Rbind x p r.

Fixpoint get_location (ρ : region) (b : localname) : option ptr :=
  match ρ with
  | Remp _ _ => None
  | Rbind x p rs =>
    if decide (b = x) then Some p
    else get_location rs b
  end.

Fixpoint get_this (ρ : region) : option ptr :=
  match ρ with
  | Remp this _ => this
  | Rbind _ _ rs => get_this rs
  end.

Fixpoint get_return_type (ρ : region) : type :=
  match ρ with
  | Remp _ ty => ty
  | Rbind _ _ rs => get_return_type rs
  end.

(** typedness of values
    note that only primitives fit into this, there is no [val] representation
    of aggregates, except through [Vptr p] with [p] pointing to the contents.
 *)

(**
[has_type v ty] is an approximation in [Prop] of "[v] is an initialized value
of type [t]." This implies:
- if [ty <> Tvoid], then [v <> Vundef] <--
  ^---- TODO: <https://gitlab.com/bedrocksystems/cpp2v-core/-/issues/319>
- if [ty = Tvoid], then [v = Vundef].
- if [ty = Tnullptr], then [v = Vptr nullptr].
- if [ty = Tint sz sgn], then [v] fits the appropriate bounds (see
  [has_int_type']).
- if [ty] is a type of pointers/aggregates, we only ensure that [v = Vptr p].
  + NOTE: We require that - for a type [Tnamed nm] - the name resolves to some
    [GlobDecl] other than [Gtype] in a given [σ : genv].
- if [ty] is a type of references, we ensure that [v = Vref p] and
  that [p <> nullptr]; [Vref] is an alias for [Vptr]
- if [ty] is a type of arrays, we ensure that [v = Vptr p] and
  that [p <> nullptr].
  *)
Parameter has_type : val -> type -> Prop.

Axiom has_type_pointer : forall v ty,
    has_type v (Tpointer ty) -> exists p, v = Vptr p.
Axiom has_type_nullptr : forall v,
    has_type v Tnullptr -> v = Vptr nullptr.
Axiom has_type_reference : forall v ty,
    has_type v (Treference ty) -> exists p, v = Vref p /\ p <> nullptr.
Axiom has_type_rv_reference : forall v ty,
    has_type v (Trv_reference ty) -> exists p, v = Vref p /\ p <> nullptr.
Axiom has_type_array : forall v ty n,
    has_type v (Tarray ty n) -> exists p, v = Vptr p /\ p <> nullptr.
Axiom has_type_function : forall v cc rty args,
    has_type v (Tfunction (cc:=cc) rty args) -> exists p, v = Vptr p /\ p <> nullptr.

Axiom has_type_void : forall v,
    has_type v Tvoid -> v = Vundef.

Axiom has_nullptr_type : forall ty,
    has_type (Vptr nullptr) (Tpointer ty).

Axiom has_type_bool : forall v,
    has_type v Tbool <-> exists b, v = Vbool b.

Lemma has_bool_type : forall z,
  0 <= z < 2 <-> has_type (Vint z) Tbool.
Proof.
  intros z. rewrite has_type_bool. split=>Hz.
  - destruct (decide (z = 0)); simplify_eq; first by exists false.
    destruct (decide (z = 1)); simplify_eq; first by exists true. lia.
  - unfold Vbool in Hz. destruct Hz as [b Hb].
    destruct b; simplify_eq; lia.
Qed.

(** Note that from [has_type v (Tint sz sgn)] does not follow
  [v = Vint _] since [v] might also be [Vraw _] (for [T_uchar]). *)
Axiom has_int_type' : forall sz sgn v,
    has_type v (Tint sz sgn) <-> (exists z, v = Vint z /\ bound sz sgn z) \/ (exists r, v = Vraw r /\ Tint sz sgn = T_uchar).

Lemma has_int_type : forall sz (sgn : signed) z,
    bound sz sgn z <-> has_type (Vint z) (Tint sz sgn).
Proof. move => *. rewrite has_int_type'. naive_solver. Qed.

Theorem has_char_type : forall sz (sgn : signed) z,
    bound sz sgn z <-> has_type (Vint z) (Tchar sz sgn).
Proof. apply has_int_type. Qed.

Axiom has_type_qual : forall t q x,
    has_type x (drop_qualifiers t) ->
    has_type x (Tqualified q t).

#[global] Hint Resolve has_type_qual : has_type.

Arguments Z.add _ _ : simpl never.
Arguments Z.sub _ _ : simpl never.
Arguments Z.mul _ _ : simpl never.
Arguments Z.pow _ _ : simpl never.
Arguments Z.opp _ : simpl never.
Arguments Z.pow_pos _ _ : simpl never.

Section has_type.
  Lemma has_type_bswap8:
    forall v,
      has_type (Vint (bswap8 v)) (Tint W8 Unsigned).
  Proof. intros *; apply has_int_type; red; generalize (bswap8_bounded v); simpl; lia. Qed.

  Lemma has_type_bswap16:
    forall v,
      has_type (Vint (bswap16 v)) (Tint W16 Unsigned).
  Proof. intros *; apply has_int_type; red; generalize (bswap16_bounded v); simpl; lia. Qed.

  Lemma has_type_bswap32:
    forall v,
      has_type (Vint (bswap32 v)) (Tint W32 Unsigned).
  Proof. intros *; apply has_int_type; red; generalize (bswap32_bounded v); simpl; lia. Qed.

  Lemma has_type_bswap64:
    forall v,
      has_type (Vint (bswap64 v)) (Tint W64 Unsigned).
  Proof. intros *; apply has_int_type; red; generalize (bswap64_bounded v); simpl; lia. Qed.

  Lemma has_type_bswap128:
    forall v,
      has_type (Vint (bswap128 v)) (Tint W128 Unsigned).
  Proof. intros *; apply has_int_type; red; generalize (bswap128_bounded v); simpl; lia. Qed.
End has_type.

Lemma has_type_bswap:
  forall sz v,
    has_type (Vint (bswap sz v)) (Tint sz Unsigned).
Proof.
  intros *; destruct sz;
    eauto using
          has_type_bswap8,
          has_type_bswap16,
          has_type_bswap32,
          has_type_bswap64,
          has_type_bswap128.
Qed.

#[global] Hint Resolve has_type_bswap : has_type.
