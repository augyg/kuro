{ nixpkgs ? import <nixpkgs> {}, compiler ? "default", doBenchmark ? false }:

let

  inherit (nixpkgs) pkgs;
  # cacophony = (pkgs.haskell.lib.doJailbreak (pkgs.haskellPackages.callHackage "cacophony" "0.9.1" {}));
  f = { mkDerivation, aeson, aeson-pretty, ansi-wl-pprint, array
      , async, attoparsec, auto-update, base, base16-bytestring
      , base64-bytestring, binary, bloomfilter, bound, BoundedChan
      , bytestring, Cabal, cereal, cmdargs, containers
      , criterion, crypto-api, cryptonite, data-default, deepseq
      , direct-sqlite, directory, ed25519-donna, ekg, ekg-core, ekg-json
      , enclosed-exceptions, errors, exceptions, extra, fast-logger
      , filepath, ghc-prim, hashable, hspec, http-client, HUnit, lens
      , lens-aeson, lib, lifted-base, lz4, megaparsec, memory
      , monad-control, monad-loops, monad-par, mtl, mtl-compat, network
      , parallel, parsers, prelude-extras, prettyprinter, primitive
      , process, random, safe, safe-exceptions, scientific, semigroups
      , servant, servant-client, servant-client-core, servant-server
      , snap-core, snap-server, sqlite-simple, stm, strict-tuple
      , string-conv, text, thyme, time, transformers, trifecta, unix
      , unordered-containers, utf8-string, vector, vector-space, wai-cors
      , warp, wreq, yaml, zeromq4-haskell, zlib
      }:
      mkDerivation {
        pname = "kuro";
        version = "1.4.0.0";
        src = ./.;
        isLibrary = true;
        isExecutable = true;
        libraryHaskellDepends = [
          aeson aeson-pretty ansi-wl-pprint array async attoparsec
          auto-update base base16-bytestring base64-bytestring binary
          bloomfilter bound BoundedChan bytestring Cabal # cacophony
          cereal
          containers criterion crypto-api cryptonite data-default deepseq
          direct-sqlite directory ed25519-donna ekg ekg-core ekg-json
          enclosed-exceptions errors exceptions extra fast-logger filepath
          ghc-prim hashable hspec http-client lens lens-aeson lifted-base lz4
          megaparsec memory monad-control monad-loops monad-par mtl
          mtl-compat network parallel parsers prelude-extras
          prettyprinter primitive process random safe safe-exceptions
          scientific semigroups servant servant-client servant-client-core
          servant-server snap-core snap-server sqlite-simple stm strict-tuple
          string-conv text thyme time transformers trifecta unix
          unordered-containers utf8-string vector vector-space wai-cors warp
          wreq yaml zeromq4-haskell zlib
        ];
        executableHaskellDepends = [
          aeson base base16-bytestring bytestring cmdargs containers
          crypto-api data-default directory ed25519-donna exceptions extra
          filepath hspec http-client HUnit lens network process safe
          text thyme transformers trifecta unordered-containers wreq yaml
        ];
        testHaskellDepends = [
          aeson async base base16-bytestring bytestring containers crypto-api
          data-default deepseq ed25519-donna errors exceptions extra hspec
          http-client lens mtl process safe safe-exceptions scientific
          text transformers trifecta unordered-containers vector wreq yaml
        ];
        homepage = "https://github.com/buckie/kadena";
        description = "A high performance permissioned blockchain";
        license = lib.licenses.bsd3;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  variant = if doBenchmark then pkgs.haskell.lib.doBenchmark else pkgs.lib.id;

  drv = variant (haskellPackages.callPackage f {});

in

  if pkgs.lib.inNixShell then drv.env else drv
