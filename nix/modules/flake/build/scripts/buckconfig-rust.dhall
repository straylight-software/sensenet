-- buckconfig-rust.dhall
-- Generate [rust] section for .buckconfig.local
--
-- Environment variables:
--   RUSTC, RUSTDOC, CLIPPY_DRIVER, CARGO

let rustc = env:RUSTC as Text
let rustdoc = env:RUSTDOC as Text
let clippy_driver = env:CLIPPY_DRIVER as Text
let cargo = env:CARGO as Text

in ''
[rust]
# Rust toolchain from Nix
rustc = ${rustc}
rustdoc = ${rustdoc}
clippy_driver = ${clippy_driver}
cargo = ${cargo}
''
