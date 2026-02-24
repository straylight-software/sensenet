// FFI for fetching the Lean file
// Returns an Aff-compatible thunk
export const fetchLeanFile = () => (onError, onSuccess) => {
  fetch("/assets/VillaStraylight.lean")
    .then((response) => response.text())
    .then((text) => onSuccess(text))
    .catch((e) => onSuccess("-- Error loading file: " + e.message));

  // Return canceler (no-op)
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};
