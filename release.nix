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
    inherit (root)
      vs17BuildToolsCppDisk
      vs16BuildToolsCppDisk
      vs15BuildToolsCppDisk
      # vs17CommunityCppDisk # does not work yet
      vs16CommunityCppDisk
      vs15CommunityCppDisk
    ;
  };
}
