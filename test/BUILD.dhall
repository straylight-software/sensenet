--| sensenet test suite
--
-- "Everyone." - Norman Stansfield

let P = ../dhall/prelude/package.dhall

let testSrcs =
      [ "Main.hs"
      , "Test/SenseNet/Adversarial.hs"
      , "Test/SenseNet/Bootstrap.hs"
      , "Test/SenseNet/Build.hs"
      , "Test/SenseNet/Crashers.hs"
      , "Test/SenseNet/DICE.hs"
      , "Test/SenseNet/DhallNixIntegration.hs"
      , "Test/SenseNet/DhallTorture.hs"
      , "Test/SenseNet/Filesystem.hs"
      , "Test/SenseNet/Integration.hs"
      , "Test/SenseNet/Nightmare.hs"
      , "Test/SenseNet/Psychotic.hs"
      , "Test/SenseNet/Savage.hs"
      , "Test/SenseNet/Security.hs"
      , "Test/SenseNet/TUI.hs"
      ]

let sensenetTest =
      (   P.haskellBinary "sensenet-test" testSrcs
        //  { packages =
                [ "base"
                , "aeson"
                , "async"
                , "bytestring"
                , "containers"
                , "crypton"
                , "deepseq"
                , "directory"
                , "filepath"
                , "memory"
                , "process"
                , "random"
                , "tasty"
                , "tasty-hunit"
                , "tasty-quickcheck"
                , "temporary"
                , "text"
                , "time"
                , "unix"
                ]
            , language_extensions =
                [ "LambdaCase"
                , "OverloadedStrings"
                , "OverloadedRecordDot"
                , "RecordWildCards"
                , "ScopedTypeVariables"
                , "ImportQualifiedPost"
                ]
            , ghc_options = [ "-O2", "-threaded", "-rtsopts", "-with-rtsopts=-N", "-Wno-x-partial" ]
            , deps = [ P.local "//src/sensenet:sensenet-lib" ]
            }
      )

in  { targets = [ P.rule.haskellBinary sensenetTest ] }
