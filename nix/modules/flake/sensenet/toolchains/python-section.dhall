-- python-section.dhall
-- Generate [python] section for buckconfig.local

let python = env:PYTHON as Text
let python_include = env:PYTHON_INCLUDE as Text
let pybind11_include = env:PYBIND11_INCLUDE as Text

-- Simply include the value - if empty, buckconfig will handle it

in ''

[python]
# Python toolchain from Nix
interpreter = ${python}/bin/python3
python_include = ${python_include}
pybind11_include = ${pybind11_include}
''
