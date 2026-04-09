-- buckconfig-python.dhall
-- Generate [python] section for .buckconfig.local
--
-- Environment variables:
--   INTERPRETER, PYTHON_INCLUDE, PYTHON_LIB
--   NANOBIND_INCLUDE, NANOBIND_CMAKE, PYBIND11_INCLUDE

let interpreter = env:INTERPRETER as Text
let python_include = env:PYTHON_INCLUDE as Text
let python_lib = env:PYTHON_LIB as Text
let nanobind_include = env:NANOBIND_INCLUDE ? "" as Text
let nanobind_cmake = env:NANOBIND_CMAKE ? "" as Text
let pybind11_include = env:PYBIND11_INCLUDE ? "" as Text

in ''
[python]
# Python toolchain from Nix
interpreter = ${interpreter}
python_include = ${python_include}
python_lib = ${python_lib}
${if nanobind_include == "" then "" else "nanobind_include = ${nanobind_include}"}
${if nanobind_cmake == "" then "" else "nanobind_cmake = ${nanobind_cmake}"}
${if pybind11_include == "" then "" else "pybind11_include = ${pybind11_include}"}
''
