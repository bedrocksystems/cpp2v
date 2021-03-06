(*
 * Copyright (c) 2020 BedRock Systems, Inc.
 * This software is distributed under the terms of the BedRock Open-Source License.
 * See the LICENSE-BedRock file in the repository root for details.
 *)
From iris.bi Require Import bi.
(* This export ensures that [upredI] is registered as a canonical structure everywhere. *)
From iris.base_logic Require Export bi.
From iris.proofmode Require Import classes.
From bedrock.lang.prelude Require Export base gmap.
From bedrock.lang.bi Require Export only_provable derived_laws.

#[global] Instance into_pure_emp PROP : IntoPure (PROP := PROP) emp%I True.
Proof. by rewrite /IntoPure (bi.pure_intro True emp%I). Qed.

#[global] Hint Opaque uPred_emp : typeclass_instances.

(** * Notation for functions in the Iris scope. To upstream,
per https://gitlab.mpi-sws.org/iris/iris/-/issues/320. *)
Notation "'λI' x .. y , t" := (fun x => .. (fun y => t%I) ..)
  (at level 200, x binder, y binder, right associativity,
  only parsing) : function_scope.

(* ASCII variant. *)
Notation "'funI' x .. y => t" := (fun x => .. (fun y => t%I) ..)
  (at level 200, x binder, y binder, right associativity,
  only parsing) : function_scope.

(* ASCII alias for [bi_pure] notation [⌜P⌝]. *)
Global Notation "[! P !]" := (bi_pure P%type%stdpp) (only parsing) : bi_scope.

(* Old, pre-Iris notations *)
Global Notation lentails := (bi_entails) (only parsing).
Global Notation lequiv := (≡) (only parsing).
Global Notation ltrue := (True%I) (only parsing).
Global Notation lfalse := (False%I) (only parsing).
Global Notation land := (bi_and) (only parsing).
Global Notation lor := (bi_or) (only parsing).
Global Notation limpl := (bi_impl) (only parsing).
Global Notation lforall := (bi_forall) (only parsing).
Global Notation lexists := (bi_exist) (only parsing).

Ltac split' := intros; apply (anti_symm (⊢)).

(* Charge notation levels *)
Module ChargeNotation.

  Notation "P |-- Q"  := (P%I ⊢ Q%I) (at level 80, no associativity).
  Notation "P '|-@{' PROP } Q" := (P%I ⊢@{PROP} Q%I)
    (at level 80, no associativity, only parsing).

  Notation "P //\\ Q"   := (P ∧ Q)%I (at level 75, right associativity).
  Notation "P \\// Q"   := (P ∨ Q)%I (at level 76, right associativity).
  Notation "P -->> Q"   := (P → Q)%I (at level 77, right associativity).
  Notation "'Forall' x .. y , p" :=
    (lforall (fun x => .. (lforall (fun y => p)) ..))%I (at level 78, x binder, y binder, right associativity).

  Notation "'Exists' x .. y , p" :=
    (lexists (fun x => .. (lexists (fun y => p)) ..))%I (at level 78, x binder, y binder, right associativity).

  Notation "|--  P" := (⊢ P%I) (at level 85, no associativity).
  Notation "'|-@{' PROP } P" := (⊢@{PROP} P%I)
    (at level 85, no associativity, only parsing).

  Notation "P ** Q" := (P ∗ Q)%I (at level 58, right associativity).
  Notation "P -* Q" := (P -∗ Q)%I (at level 60, right associativity).

  (* Notation "'|>' P" := (▷  P)%I (at level 71). *)
  Notation "|> P" := (▷  P)%I (at level 20, right associativity).

  Notation "P -|- Q"  := (P ⊣⊢ Q) (at level 85, no associativity).
  Notation "P '-|-@{' PROP } Q"  := (P%I ⊣⊢@{PROP} Q%I)
    (at level 85, no associativity, only parsing).

End ChargeNotation.
