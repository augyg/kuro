let
  pkgs = import <nixpkgs> {};
  
in
  { name = "k";
    someBs = pkgs.haskellPackages.ghc;
      
  }
