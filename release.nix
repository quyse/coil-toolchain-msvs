{ pkgs ? import <nixpkgs> {}
, toolchain
}:
let
  msvs = import ./. {
    inherit pkgs toolchain;
  };
in {
  touch = {
    inherit (msvs) vs16BuildToolsCppDisk vs15BuildToolsCppDisk vs16CommunityCppDisk vs15CommunityCppDisk;
  };
}
