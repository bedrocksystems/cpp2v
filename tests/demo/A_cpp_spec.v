Require Import Coq.ZArith.BinInt.
Require Import Coq.Strings.String.

Local Open Scope string_scope.

From ChargeCore.Logics Require Import
     ILogic BILogic ILEmbed Later.

From Cpp Require Import Auto.

From Demo Require Import A_hpp_spec.


Definition A_cpp_spec (resolve : _) :=
      (|> ti_cglob' (resolve:=resolve) A__bar A__bar_spec) -*
          ti_cglob' (resolve:=resolve) A__foo A__foo_spec.