# Beelink EQ13 hardware tier. Composes onto cluster-node — the flake sets
# `baseEq13 = baseCommon ++ [ eq13-node ]`, so EQ13 boxes get the cluster-node
# baseline plus the shared EQ13 hardware profile and the /dev/sda disko layout.
{ kin, ... }:
with kin;
{
  imports = [
    ../../hardware/beelink-eq13
    ../../storage/disko-eq13
  ];

  kin.hardware.beelink-eq13 = enabled;
}
