use std::env;
use std::path::PathBuf;

fn main() {
  let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
  let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

  // Generate C header using cbindgen
  let config = cbindgen::Config::from_file("cbindgen.toml").unwrap_or_default();

  cbindgen::Builder::new()
    .with_crate(&crate_dir)
    .with_config(config)
    .with_language(cbindgen::Language::C)
    .generate()
    .expect("Unable to generate C bindings")
    .write_to_file(out_dir.join("dice_ffi.h"));

  // Also write to include directory for easy access
  let include_dir = PathBuf::from(&crate_dir).join("include");
  std::fs::create_dir_all(&include_dir).ok();

  cbindgen::Builder::new()
    .with_crate(&crate_dir)
    .with_config(cbindgen::Config::from_file("cbindgen.toml").unwrap_or_default())
    .with_language(cbindgen::Language::C)
    .generate()
    .expect("Unable to generate C bindings")
    .write_to_file(include_dir.join("dice_ffi.h"));

  println!("cargo:rerun-if-changed=src/lib.rs");
  println!("cargo:rerun-if-changed=cbindgen.toml");
}
