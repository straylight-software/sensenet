/*
 * dice-ffi: C FFI bindings for DICE incremental computation engine
 *
 * Provides a C ABI for Haskell FFI integration with sensenet.
 *
 * Design principles:
 * 1. Opaque handles - all Rust types are hidden behind pointers
 * 2. Embedded Tokio runtime - async complexity hidden from Haskell
 * 3. Build-specific keys - concrete ActionKey type, not generic Key trait
 * 4. Callback-based compute - Haskell provides compute functions
 *
 * Usage flow:
 * 1. dice_runtime_new() - create Tokio runtime
 * 2. dice_engine_new() - create DICE engine
 * 3. dice_register_key_type() - register key types with compute callbacks
 * 4. dice_updater_new() + dice_inject() - inject file/config values
 * 5. dice_commit() - get transaction
 * 6. dice_compute() - request computation
 * 7. dice_*_free() - cleanup
 */

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::hash::Hash;
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock};

use allocative::Allocative;
use async_trait::async_trait;
use dice::{
  DetectCycles, Dice, DiceComputations, DiceTransaction, DiceTransactionUpdater, InjectedKey, Key,
};
use dice_futures::cancellation::CancellationContext;
use dupe::Dupe;
use sha2::{Digest, Sha256};
use tokio::runtime::Runtime;

// ═══════════════════════════════════════════════════════════════════════════
// Opaque Handle Types
// ═══════════════════════════════════════════════════════════════════════════

/// Tokio runtime handle - manages async execution
#[repr(C)]
pub struct RuntimeHandle {
  runtime: Runtime,
}

/// DICE engine handle
#[repr(C)]
pub struct DiceHandle {
  engine: Arc<Dice>,
}

/// Transaction updater handle (for injecting values)
#[repr(C)]
pub struct UpdaterHandle {
  updater: Option<DiceTransactionUpdater>,
}

/// Transaction handle (for computing values)
#[repr(C)]
pub struct TransactionHandle {
  transaction: DiceTransaction,
}

/// Computation result handle (returned from compute)
#[repr(C)]
pub struct ResultHandle {
  value: Option<ActionResult>,
  error: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════════
// Build-Specific Key Types
// ═══════════════════════════════════════════════════════════════════════════

/// Content-addressed action key (hash of inputs + command)
#[derive(Clone, Debug, PartialEq, Eq, Hash, Allocative)]
pub struct ActionKey(String);

impl std::fmt::Display for ActionKey {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    write!(f, "ActionKey({})", &self.0[..8.min(self.0.len())])
  }
}

/// Result of an action computation
#[derive(Clone, Debug, Allocative)]
pub struct ActionResult {
  /// Output paths produced by this action
  pub outputs: Vec<String>,
  /// Content hash of outputs (for cache validation)
  pub output_hash: String,
  /// Exit code (0 = success)
  pub exit_code: i32,
  /// Stderr/stdout if any
  pub log: String,
}

impl Dupe for ActionResult {}

/// Source file key (path -> content hash)
#[derive(Clone, Debug, PartialEq, Eq, Hash, Allocative)]
pub struct SourceKey(String);

impl std::fmt::Display for SourceKey {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    write!(f, "Source({})", self.0)
  }
}

/// Source file value (content hash)
#[derive(Clone, Debug, Allocative)]
pub struct SourceValue {
  pub hash: String,
  pub size: u64,
}

impl Dupe for SourceValue {}

// ═══════════════════════════════════════════════════════════════════════════
// Callback Function Types
// ═══════════════════════════════════════════════════════════════════════════

/// Callback signature for computing an action
///
/// Called by DICE when an ActionKey needs to be computed.
/// The callback receives:
/// - key: the action key (content hash)
/// - key_len: length of key string
/// - deps_json: JSON array of dependency results
/// - deps_len: length of deps JSON
/// - user_data: opaque pointer passed at registration
///
/// Returns a pointer to a C string containing JSON result, or null on error.
/// The returned string must be freed by the caller using dice_free_string().
pub type ComputeActionFn = extern "C" fn(
  key: *const c_char,
  key_len: usize,
  deps_json: *const c_char,
  deps_len: usize,
  user_data: *mut c_void,
) -> *mut c_char;

/// Wrapper for *mut c_void that is Send+Sync
/// Safety: The caller guarantees the pointer is safe to send across threads
#[derive(Clone, Copy)]
struct SendSyncPtr(*mut c_void);
unsafe impl Send for SendSyncPtr {}
unsafe impl Sync for SendSyncPtr {}

/// Global registry of compute callbacks
static COMPUTE_CALLBACKS: OnceLock<Mutex<HashMap<String, (ComputeActionFn, SendSyncPtr)>>> =
  OnceLock::new();

fn get_callbacks() -> &'static Mutex<HashMap<String, (ComputeActionFn, SendSyncPtr)>> {
  COMPUTE_CALLBACKS.get_or_init(|| Mutex::new(HashMap::new()))
}

// ═══════════════════════════════════════════════════════════════════════════
// Key Trait Implementations
// ═══════════════════════════════════════════════════════════════════════════

#[async_trait]
impl Key for ActionKey {
  type Value = Arc<ActionResult>;

  async fn compute(
    &self,
    _ctx: &mut DiceComputations,
    _cancellations: &CancellationContext,
  ) -> Self::Value {
    // Look up registered callback
    let callbacks = get_callbacks().lock().unwrap();

    // For now, use a default "action" type
    // In the future, we could have multiple action types
    if let Some((callback, user_data)) = callbacks.get("action") {
      // Prepare key as C string
      let key_cstr = CString::new(self.0.as_str()).unwrap();

      // TODO: Gather dependencies and serialize to JSON
      // For now, pass empty deps
      let deps_json = CString::new("[]").unwrap();

      // Call the Haskell callback
      let result_ptr = callback(
        key_cstr.as_ptr(),
        self.0.len(),
        deps_json.as_ptr(),
        2, // "[]".len()
        user_data.0,
      );

      if !result_ptr.is_null() {
        // Parse result JSON
        let result_cstr = unsafe { CStr::from_ptr(result_ptr) };
        let result_str = result_cstr.to_string_lossy();

        // Simple parsing - expect JSON like:
        // {"outputs": ["path1", "path2"], "output_hash": "abc123", "exit_code": 0, "log": ""}
        // For now, return a dummy result
        let result = ActionResult {
          outputs: vec![format!("output-{}", &self.0[..8.min(self.0.len())])],
          output_hash: self.0.clone(),
          exit_code: 0,
          log: result_str.to_string(),
        };

        // Free the result string
        unsafe { libc::free(result_ptr as *mut c_void) };

        return Arc::new(result);
      }
    }

    // No callback registered or callback failed - return error result
    Arc::new(ActionResult {
      outputs: vec![],
      output_hash: String::new(),
      exit_code: 1,
      log: "No compute callback registered".to_string(),
    })
  }

  fn equality(x: &Self::Value, y: &Self::Value) -> bool {
    x.output_hash == y.output_hash && x.exit_code == y.exit_code
  }
}

#[async_trait]
impl InjectedKey for SourceKey {
  type Value = Arc<SourceValue>;

  fn equality(x: &Self::Value, y: &Self::Value) -> bool {
    x.hash == y.hash
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime Management
// ═══════════════════════════════════════════════════════════════════════════

/// Create a new Tokio runtime for DICE async operations
#[no_mangle]
pub extern "C" fn dice_runtime_new() -> *mut RuntimeHandle {
  match Runtime::new() {
    Ok(runtime) => Box::into_raw(Box::new(RuntimeHandle { runtime })),
    Err(_) => ptr::null_mut(),
  }
}

/// Free a Tokio runtime
#[no_mangle]
pub extern "C" fn dice_runtime_free(handle: *mut RuntimeHandle) {
  if !handle.is_null() {
    unsafe { drop(Box::from_raw(handle)) };
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DICE Engine Management
// ═══════════════════════════════════════════════════════════════════════════

/// Create a new DICE engine
#[no_mangle]
pub extern "C" fn dice_engine_new() -> *mut DiceHandle {
  let builder = Dice::builder();
  let engine = builder.build(DetectCycles::Disabled);
  Box::into_raw(Box::new(DiceHandle { engine }))
}

/// Free a DICE engine
#[no_mangle]
pub extern "C" fn dice_engine_free(handle: *mut DiceHandle) {
  if !handle.is_null() {
    unsafe { drop(Box::from_raw(handle)) };
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Callback Registration
// ═══════════════════════════════════════════════════════════════════════════

/// Register a compute callback for action keys
///
/// key_type: Name of the key type (e.g., "action")
/// callback: Function to call when computing values
/// user_data: Opaque pointer passed to callback
#[no_mangle]
pub extern "C" fn dice_register_compute(
  key_type: *const c_char,
  key_type_len: usize,
  callback: ComputeActionFn,
  user_data: *mut c_void,
) -> i32 {
  if key_type.is_null() {
    return -1;
  }

  let key_type_str = unsafe {
    let bytes = slice::from_raw_parts(key_type as *const u8, key_type_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  let mut callbacks = get_callbacks().lock().unwrap();
  callbacks.insert(key_type_str, (callback, SendSyncPtr(user_data)));
  0
}

// ═══════════════════════════════════════════════════════════════════════════
// Transaction Management
// ═══════════════════════════════════════════════════════════════════════════

/// Create a new transaction updater (for injecting values)
#[no_mangle]
pub extern "C" fn dice_updater_new(dice: *mut DiceHandle) -> *mut UpdaterHandle {
  if dice.is_null() {
    return ptr::null_mut();
  }

  let dice = unsafe { &*dice };
  let updater = dice.engine.updater();
  Box::into_raw(Box::new(UpdaterHandle {
    updater: Some(updater),
  }))
}

/// Inject a source file value (path -> hash)
#[no_mangle]
pub extern "C" fn dice_inject_source(
  updater: *mut UpdaterHandle,
  path: *const c_char,
  path_len: usize,
  hash: *const c_char,
  hash_len: usize,
  size: u64,
) -> i32 {
  if updater.is_null() || path.is_null() || hash.is_null() {
    return -1;
  }

  let updater = unsafe { &mut *updater };
  let Some(ref mut upd) = updater.updater else {
    return -1;
  };

  let path_str = unsafe {
    let bytes = slice::from_raw_parts(path as *const u8, path_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  let hash_str = unsafe {
    let bytes = slice::from_raw_parts(hash as *const u8, hash_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  let key = SourceKey(path_str);
  let value = Arc::new(SourceValue {
    hash: hash_str,
    size,
  });

  match upd.changed_to(vec![(key, value)]) {
    Ok(()) => 0,
    Err(_) => -1,
  }
}

/// Commit the updater and get a transaction (blocking)
#[no_mangle]
pub extern "C" fn dice_commit(
  runtime: *mut RuntimeHandle,
  updater: *mut UpdaterHandle,
) -> *mut TransactionHandle {
  if runtime.is_null() || updater.is_null() {
    return ptr::null_mut();
  }

  let runtime = unsafe { &*runtime };
  let updater = unsafe { &mut *updater };

  let Some(upd) = updater.updater.take() else {
    return ptr::null_mut();
  };

  let transaction = runtime.runtime.block_on(upd.commit());
  Box::into_raw(Box::new(TransactionHandle { transaction }))
}

/// Free an updater handle
#[no_mangle]
pub extern "C" fn dice_updater_free(handle: *mut UpdaterHandle) {
  if !handle.is_null() {
    unsafe { drop(Box::from_raw(handle)) };
  }
}

/// Free a transaction handle
#[no_mangle]
pub extern "C" fn dice_transaction_free(handle: *mut TransactionHandle) {
  if !handle.is_null() {
    unsafe { drop(Box::from_raw(handle)) };
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Computation
// ═══════════════════════════════════════════════════════════════════════════

/// Compute an action key (blocking)
///
/// Returns a ResultHandle that must be freed with dice_result_free()
#[no_mangle]
pub extern "C" fn dice_compute_action(
  runtime: *mut RuntimeHandle,
  transaction: *mut TransactionHandle,
  key: *const c_char,
  key_len: usize,
) -> *mut ResultHandle {
  if runtime.is_null() || transaction.is_null() || key.is_null() {
    return Box::into_raw(Box::new(ResultHandle {
      value: None,
      error: Some("Null pointer argument".to_string()),
    }));
  }

  let runtime = unsafe { &*runtime };
  let transaction = unsafe { &mut *transaction };

  let key_str = unsafe {
    let bytes = slice::from_raw_parts(key as *const u8, key_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  let action_key = ActionKey(key_str);

  // Block on the async computation
  let result = runtime
    .runtime
    .block_on(async { transaction.transaction.compute(&action_key).await });

  match result {
    Ok(value) => Box::into_raw(Box::new(ResultHandle {
      value: Some((*value).clone()),
      error: None,
    })),
    Err(e) => Box::into_raw(Box::new(ResultHandle {
      value: None,
      error: Some(format!("{:?}", e)),
    })),
  }
}

/// Check if computation succeeded
#[no_mangle]
pub extern "C" fn dice_result_ok(handle: *mut ResultHandle) -> i32 {
  if handle.is_null() {
    return 0;
  }
  let handle = unsafe { &*handle };
  if handle.value.is_some() && handle.error.is_none() {
    1
  } else {
    0
  }
}

/// Get exit code from result (0 on success)
#[no_mangle]
pub extern "C" fn dice_result_exit_code(handle: *mut ResultHandle) -> i32 {
  if handle.is_null() {
    return -1;
  }
  let handle = unsafe { &*handle };
  handle.value.as_ref().map_or(-1, |v| v.exit_code)
}

/// Get number of outputs from result
#[no_mangle]
pub extern "C" fn dice_result_output_count(handle: *mut ResultHandle) -> usize {
  if handle.is_null() {
    return 0;
  }
  let handle = unsafe { &*handle };
  handle.value.as_ref().map_or(0, |v| v.outputs.len())
}

/// Get output path at index (returns null if out of bounds)
/// Caller must NOT free the returned string - it's owned by the result
#[no_mangle]
pub extern "C" fn dice_result_output_at(
  handle: *mut ResultHandle,
  index: usize,
  out_len: *mut usize,
) -> *const c_char {
  if handle.is_null() {
    return ptr::null();
  }
  let handle = unsafe { &*handle };
  match &handle.value {
    Some(v) if index < v.outputs.len() => {
      let output = &v.outputs[index];
      if !out_len.is_null() {
        unsafe { *out_len = output.len() };
      }
      output.as_ptr() as *const c_char
    }
    _ => ptr::null(),
  }
}

/// Get error message (returns null if no error)
/// Caller must NOT free the returned string - it's owned by the result
#[no_mangle]
pub extern "C" fn dice_result_error(
  handle: *mut ResultHandle,
  out_len: *mut usize,
) -> *const c_char {
  if handle.is_null() {
    return ptr::null();
  }
  let handle = unsafe { &*handle };
  match &handle.error {
    Some(e) => {
      if !out_len.is_null() {
        unsafe { *out_len = e.len() };
      }
      e.as_ptr() as *const c_char
    }
    None => ptr::null(),
  }
}

/// Free a result handle
#[no_mangle]
pub extern "C" fn dice_result_free(handle: *mut ResultHandle) {
  if !handle.is_null() {
    unsafe { drop(Box::from_raw(handle)) };
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Utility Functions
// ═══════════════════════════════════════════════════════════════════════════

/// Compute SHA256 hash of data
/// Returns a hex-encoded string that must be freed with dice_free_string()
#[no_mangle]
pub extern "C" fn dice_hash_sha256(data: *const u8, data_len: usize) -> *mut c_char {
  if data.is_null() {
    return ptr::null_mut();
  }

  let bytes = unsafe { slice::from_raw_parts(data, data_len) };
  let hash = Sha256::digest(bytes);
  let hex = hex::encode(hash);

  match CString::new(hex) {
    Ok(cstr) => cstr.into_raw(),
    Err(_) => ptr::null_mut(),
  }
}

/// Free a string allocated by this library
#[no_mangle]
pub extern "C" fn dice_free_string(s: *mut c_char) {
  if !s.is_null() {
    unsafe { drop(CString::from_raw(s)) };
  }
}

/// Get version string
#[no_mangle]
pub extern "C" fn dice_version() -> *const c_char {
  static VERSION: &[u8] = b"0.1.0\0";
  VERSION.as_ptr() as *const c_char
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn test_hash() {
    let data = b"hello world";
    let hash_ptr = dice_hash_sha256(data.as_ptr(), data.len());
    assert!(!hash_ptr.is_null());

    let hash_str = unsafe { CStr::from_ptr(hash_ptr) };
    assert_eq!(
      hash_str.to_str().unwrap(),
      "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );

    dice_free_string(hash_ptr);
  }

  #[test]
  fn test_runtime_lifecycle() {
    let rt = dice_runtime_new();
    assert!(!rt.is_null());
    dice_runtime_free(rt);
  }

  #[test]
  fn test_engine_lifecycle() {
    let engine = dice_engine_new();
    assert!(!engine.is_null());
    dice_engine_free(engine);
  }
}
