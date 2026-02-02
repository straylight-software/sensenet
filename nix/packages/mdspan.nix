# nix/packages/mdspan.nix
#
# Kokkos mdspan reference implementation (header-only)
# https://github.com/kokkos/mdspan
#
# C++23 std::mdspan before it's in libstdc++/libc++.
# Works on both host and device (CUDA).
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
}:

stdenv.mkDerivation rec {
  pname = "mdspan";
  version = "0.6.0";

  src = fetchFromGitHub {
    owner = "kokkos";
    repo = "mdspan";
    rev = "mdspan-${version}";
    hash = "sha256-bwE+NO/n9XsWOp3GjgLHz3s0JR0CzNDernfLHVqU9Z8=";
  };

  nativeBuildInputs = [ cmake ];

  cmakeFlags = [
    "-DMDSPAN_ENABLE_TESTS=OFF"
    "-DMDSPAN_ENABLE_BENCHMARKS=OFF"
  ];

  meta = {
    description = "C++23 std::mdspan reference implementation";
    homepage = "https://github.com/kokkos/mdspan";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
