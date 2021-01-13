{ pkgs
, toolchain
}:
let
  root = import ./. {
    inherit pkgs toolchain;
  };
in {
  inherit root;
  touch = {
    inherit (root) vs16BuildToolsCppDisk vs15BuildToolsCppDisk vs16CommunityCppDisk vs15CommunityCppDisk;
  };
}
