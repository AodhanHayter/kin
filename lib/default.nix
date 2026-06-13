# Snow-style module helpers (mkBoolOpt/enabled/...). Hand-rolled — NOT
# snowfall-lib (which conflicts with clan-core). Injected into every machine
# module via flake.nix `specialArgs.kin`, so modules can author with the
# `with kin; options.kin.<cat>.<name>.enable = mkBoolOpt ...` skeleton.
{ lib }:
let
  inherit (lib) mkOption types;
in
rec {
  # 3-arg option builder: type -> default -> description.
  mkOpt =
    type: default: description:
    mkOption { inherit type default description; };

  # Same, description omitted.
  mkOpt' = type: default: mkOpt type default null;

  # Partially-applied bool option: call site is `mkBoolOpt <default> "<desc>"`.
  mkBoolOpt = mkOpt types.bool;
  mkBoolOpt' = mkOpt' types.bool;

  # Terse RHS sugar for flipping a submodule's enable flag.
  enabled = {
    enable = true;
  };
  disabled = {
    enable = false;
  };
}
