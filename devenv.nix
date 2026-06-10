{ pkgs, inputs, ... }:

{
  # https://devenv.sh/packages/
  packages = [
    # clan CLI (from the clan-core flake input in devenv.yaml) — drives
    # `clan machines list/update`, `clan vars generate`, etc.
    inputs.clan-core.packages.${pkgs.stdenv.system}.clan-cli
    pkgs.git
    pkgs.nixfmt-rfc-style
    # Drive the cluster from the Mac (kubeconfig: ~/.kube/config -> atlas).
    pkgs.kubectl
    pkgs.kubernetes-helm
    pkgs.k9s
  ];

  # https://devenv.sh/basics/
  enterShell = ''
    echo "kin devenv — clan CLI ready (try: clan machines list)"
  '';

  git-hooks.hooks = {
    shellcheck.enable = true;
    nixfmt.enable = true;
  };
}
