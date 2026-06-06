# Baseline config shared by every kin lab node.
# Ported from the snowfall `prototype.lab-node` suite, trimmed to what a
# headless k3s node needs (dev-environment niceties dropped).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Authorized SSH keys (carried over from the snow openssh module).
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFnEsBv5zrOZzeQSymd/WKottg28l0mav/J0m0/Q3E4X aodhan.hayter@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTBSBlivmm4W46rP9m+qHPwumFuepcjP9Jl6iYhcZS5 aodhan.hayter@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL5Gq86apfFdEbHIvTK+n1f7txgRYDakWfTARSzct0om aodhan.hayter@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIX2R0he+RBUTv2EICttBFWGH1o5NRydkg2bJFtFG5/O aodhan.hayter@gmail.com"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBL2eiUV5XxJPf6LaHmwGKNHnUyItlp4y1kt64kVlcsvzlU62Pe9GAsduW1Iv1K/gGCwRPj5wK5jf6derQqbydYM= ssh.id"
  ];
in
{
  # --- nix ---
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "aodhan"
    ];
    auto-optimise-store = true;
    warn-dirty = false;
  };
  nixpkgs.config.allowUnfree = true;

  # --- networking ---
  networking.networkmanager = {
    enable = true;
    dhcp = "internal";
  };
  # Avoids the well-known nixos-rebuild hang on NetworkManager-wait-online.
  systemd.services.NetworkManager-wait-online.enable = false;

  # mDNS so `<host>.local` resolves across the cluster (k3s serverAddr, gluster peers).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
    ipv6 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # --- ssh ---
  # clan deploys over `root@`, so root login is permitted (key-only).
  services.openssh = {
    enable = true;
    ports = [
      22
      2222
    ];
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # --- privileges ---
  # nixos-rebuild remote activation needs sudo; keep wheel passwordless.
  security.sudo.wheelNeedsPassword = false;

  # --- user ---
  users.users.aodhan = {
    isNormalUser = true;
    uid = 1000;
    home = "/home/aodhan";
    group = "users";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.fish;
    initialPassword = "password";
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  programs.fish.enable = true;

  # --- locale / time ---
  time.timeZone = lib.mkDefault "America/New_York";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    kubectl
  ];
}
