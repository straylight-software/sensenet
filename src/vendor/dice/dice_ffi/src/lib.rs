/*
 * dice-ffi: C FFI bindings for DICE incremental computation engine
 *
 * Provides a C ABI for Haskell FFI integration with sensenet.
 *
 * Design principles:
 * 1. Opaque handles - all Rust types are hidden behind pointers
 * 2. Embedded Tokio runtime - async complexity hidden from Haskell
 * 3. Build-specific keys - concrete TargetKey type with dependency tracking
 * 4. Callback-based compute - Haskell provides compute functions
 *
 * Usage flow:
 * 1. dice_runtime_new() - create Tokio runtime
 * 2. dice_engine_new() - create DICE engine
 * 3. dice_register_target() - register targets with deps and callbacks
 * 4. dice_updater_new() + dice_inject() - inject file/config values
 * 5. dice_commit() - get transaction
 * 6. dice_compute() - request computation (deps auto-resolved)
 * 7. dice_*_free() - cleanup
 *
 * Dependency Resolution:
 * - Targets are registered with their dependency names via dice_register_target()
 * - When computing a target, DICE calls ctx.compute() on each dep first
 * - Dep outputs are serialized to JSON and passed to the Haskell callback
 * - Haskell receives resolved dep outputs, not raw dep keys
 */

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::hash::Hash;
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock};

use futures::FutureExt;

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

/// Target key - a named build target that may depend on other targets
#[derive(Clone, Debug, PartialEq, Eq, Hash, Allocative)]
pub struct TargetKey(String);

impl std::fmt::Display for TargetKey {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    write!(f, "Target({})", &self.0)
  }
}

/// Result of a target build
#[derive(Clone, Debug, Allocative)]
pub struct TargetResult {
  /// Output paths produced by this target
  pub outputs: Vec<String>,
  /// Content hash of outputs (for cache validation)
  pub output_hash: String,
  /// Exit code (0 = success)
  pub exit_code: i32,
  /// Stderr/stdout if any
  pub log: String,
  /// Build profile: wall clock time in milliseconds
  pub time_ms: u64,
  /// Build profile: peak resident set size in bytes
  pub peak_memory_bytes: u64,
}

impl Dupe for TargetResult {}

// Keep ActionKey as alias for backwards compatibility
pub type ActionKey = TargetKey;
pub type ActionResult = TargetResult;

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

/// Registered target info - deps and callback
#[derive(Clone)]
struct TargetInfo {
  /// Names of targets this target depends on
  deps: Vec<String>,
  /// Callback to execute when deps are resolved
  callback: ComputeActionFn,
  /// User data for callback
  user_data: SendSyncPtr,
}

/// Global registry of targets with their dependencies
static TARGET_REGISTRY: OnceLock<Mutex<HashMap<String, TargetInfo>>> = OnceLock::new();

fn get_target_registry() -> &'static Mutex<HashMap<String, TargetInfo>> {
  TARGET_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Global registry of compute callbacks (legacy - for simple actions without deps)
static COMPUTE_CALLBACKS: OnceLock<Mutex<HashMap<String, (ComputeActionFn, SendSyncPtr)>>> =
  OnceLock::new();

fn get_callbacks() -> &'static Mutex<HashMap<String, (ComputeActionFn, SendSyncPtr)>> {
  COMPUTE_CALLBACKS.get_or_init(|| Mutex::new(HashMap::new()))
}

// ═══════════════════════════════════════════════════════════════════════════
// Key Trait Implementations
// ═══════════════════════════════════════════════════════════════════════════

#[async_trait]
impl Key for TargetKey {
  type Value = Arc<TargetResult>;

  async fn compute(
    &self,
    ctx: &mut DiceComputations,
    _cancellations: &CancellationContext,
  ) -> Self::Value {
    // First, check if this target is registered with deps
    let target_info = {
      let registry = get_target_registry().lock().unwrap();
      registry.get(&self.0).cloned()
    };

    if let Some(info) = target_info {
      // This target has registered deps - compute them in PARALLEL using DICE's compute_join
      let dep_names: Vec<String> = info.deps.clone();

      // Use DICE's compute_join for proper parallel computation
      let dep_results_raw: Vec<(String, Result<Arc<TargetResult>, _>)> = ctx
        .compute_join(dep_names, |dice_ctx, dep_name| {
          async move {
            let dep_key = TargetKey(dep_name.clone());
            let result = dice_ctx.compute(&dep_key).await;
            (dep_name, result)
          }
          .boxed()
        })
        .await;

      // Collect results, failing fast on any error
      let mut dep_results: Vec<(String, Vec<String>)> = Vec::new();
      for (dep_name, result) in dep_results_raw {
        match result {
          Ok(dep_result) => {
            dep_results.push((dep_name, dep_result.outputs.clone()));
          }
          Err(e) => {
            // Dep computation failed
            return Arc::new(TargetResult {
              outputs: vec![],
              output_hash: String::new(),
              exit_code: 1,
              log: format!("Dependency '{}' failed: {:?}", dep_name, e),
              time_ms: 0,
              peak_memory_bytes: 0,
            });
          }
        }
      }

      // Serialize dep results to JSON for Haskell
      // Format: [{"name": "dep1", "outputs": ["path1", "path2"]}, ...]
      let deps_json = serialize_dep_results(&dep_results);
      let deps_cstr = CString::new(deps_json.as_str()).unwrap();
      let key_cstr = CString::new(self.0.as_str()).unwrap();

      // Call the Haskell callback with resolved deps
      let result_ptr = (info.callback)(
        key_cstr.as_ptr(),
        self.0.len(),
        deps_cstr.as_ptr(),
        deps_json.len(),
        info.user_data.0,
      );

      return parse_callback_result(result_ptr, &self.0);
    }

    // Fall back to legacy callback system (for backwards compatibility)
    let callbacks = get_callbacks().lock().unwrap();

    if let Some((callback, user_data)) = callbacks.get("action") {
      // Prepare key as C string
      let key_cstr = CString::new(self.0.as_str()).unwrap();
      let deps_json = CString::new("[]").unwrap();

      // Call the Haskell callback
      let result_ptr = callback(
        key_cstr.as_ptr(),
        self.0.len(),
        deps_json.as_ptr(),
        2, // "[]".len()
        user_data.0,
      );

      return parse_callback_result(result_ptr, &self.0);
    }

    // No callback registered or callback failed - return error result
    Arc::new(TargetResult {
      outputs: vec![],
      output_hash: String::new(),
      exit_code: 1,
      log: format!("No compute callback registered for target '{}'", self.0),
      time_ms: 0,
      peak_memory_bytes: 0,
    })
  }

  fn equality(x: &Self::Value, y: &Self::Value) -> bool {
    x.output_hash == y.output_hash && x.exit_code == y.exit_code
  }
}

/// Serialize dependency results to JSON
fn serialize_dep_results(deps: &[(String, Vec<String>)]) -> String {
  // Manual JSON serialization (avoiding serde dependency)
  let entries: Vec<String> = deps
    .iter()
    .map(|(name, outputs)| {
      let outputs_json: Vec<String> = outputs
        .iter()
        .map(|o| format!("\"{}\"", escape_json(o)))
        .collect();
      format!(
        "{{\"name\":\"{}\",\"outputs\":[{}]}}",
        escape_json(name),
        outputs_json.join(",")
      )
    })
    .collect();
  format!("[{}]", entries.join(","))
}

/// Escape special characters for JSON strings
fn escape_json(s: &str) -> String {
  s.replace('\\', "\\\\")
    .replace('"', "\\\"")
    .replace('\n', "\\n")
    .replace('\r', "\\r")
    .replace('\t', "\\t")
}

/// Parse callback result into TargetResult
fn parse_callback_result(result_ptr: *mut c_char, key_name: &str) -> Arc<TargetResult> {
  if !result_ptr.is_null() {
    // Parse result JSON
    let result_cstr = unsafe { CStr::from_ptr(result_ptr) };
    let result_str = result_cstr.to_string_lossy();

    // Parse JSON result: {"outputs": [...], "output_hash": "...", "exit_code": N, "log": "..."}
    let result = parse_result_json(&result_str, key_name);

    // Free the result string
    unsafe { libc::free(result_ptr as *mut c_void) };

    return Arc::new(result);
  }

  Arc::new(TargetResult {
    outputs: vec![],
    output_hash: String::new(),
    exit_code: 1,
    log: format!("Callback returned null for target '{}'", key_name),
    time_ms: 0,
    peak_memory_bytes: 0,
  })
}

/// Parse JSON result from callback (minimal parser)
fn parse_result_json(json: &str, key_name: &str) -> TargetResult {
  // Very simple JSON parsing - look for key fields
  // This avoids pulling in serde_json dependency

  let exit_code = extract_json_int(json, "exit_code").unwrap_or(0);
  let output_hash =
    extract_json_string(json, "output_hash").unwrap_or_else(|| key_name.to_string());
  let log = extract_json_string(json, "log").unwrap_or_default();
  let outputs = extract_json_string_array(json, "outputs").unwrap_or_default();
  let time_ms = extract_json_u64(json, "time_ms").unwrap_or(0);
  let peak_memory_bytes = extract_json_u64(json, "peak_memory_bytes").unwrap_or(0);

  TargetResult {
    outputs,
    output_hash,
    exit_code,
    log,
    time_ms,
    peak_memory_bytes,
  }
}

/// Extract an integer value from JSON
fn extract_json_int(json: &str, key: &str) -> Option<i32> {
  let pattern = format!("\"{}\":", key);
  let start = json.find(&pattern)?;
  let after_key = &json[start + pattern.len()..];
  let trimmed = after_key.trim_start();

  // Find end of number
  let end = trimmed.find(|c: char| !c.is_ascii_digit() && c != '-')?;
  trimmed[..end].parse().ok()
}

/// Extract a u64 value from JSON
fn extract_json_u64(json: &str, key: &str) -> Option<u64> {
  let pattern = format!("\"{}\":", key);
  let start = json.find(&pattern)?;
  let after_key = &json[start + pattern.len()..];
  let trimmed = after_key.trim_start();

  // Find end of number
  let end = trimmed.find(|c: char| !c.is_ascii_digit())?;
  trimmed[..end].parse().ok()
}

/// Extract a string value from JSON
fn extract_json_string(json: &str, key: &str) -> Option<String> {
  let pattern = format!("\"{}\":\"", key);
  let start = json.find(&pattern)?;
  let after_key = &json[start + pattern.len()..];

  // Find end quote (handling escapes)
  let mut chars = after_key.chars().peekable();
  let mut result = String::new();
  while let Some(c) = chars.next() {
    if c == '"' {
      break;
    } else if c == '\\' {
      if let Some(&escaped) = chars.peek() {
        chars.next();
        match escaped {
          'n' => result.push('\n'),
          'r' => result.push('\r'),
          't' => result.push('\t'),
          '"' => result.push('"'),
          '\\' => result.push('\\'),
          _ => {
            result.push('\\');
            result.push(escaped);
          }
        }
      }
    } else {
      result.push(c);
    }
  }
  Some(result)
}

/// Extract a string array from JSON
fn extract_json_string_array(json: &str, key: &str) -> Option<Vec<String>> {
  let pattern = format!("\"{}\":[", key);
  let start = json.find(&pattern)?;
  let after_key = &json[start + pattern.len()..];

  // Find end of array
  let end = after_key.find(']')?;
  let array_content = &after_key[..end];

  // Extract strings (simple case - no nested arrays/objects)
  let mut results = Vec::new();
  let mut in_string = false;
  let mut current = String::new();
  let mut escape_next = false;

  for c in array_content.chars() {
    if escape_next {
      current.push(c);
      escape_next = false;
    } else if c == '\\' {
      escape_next = true;
    } else if c == '"' {
      if in_string {
        results.push(current.clone());
        current.clear();
      }
      in_string = !in_string;
    } else if in_string {
      current.push(c);
    }
  }

  Some(results)
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

/// Register a compute callback for action keys (legacy API)
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

/// Register a target with its dependencies
///
/// This is the primary API for dependency-aware builds. When the target is computed:
/// 1. DICE computes all dependencies first (via ctx.compute())
/// 2. Dep outputs are serialized to JSON
/// 3. Haskell callback receives resolved dep outputs
///
/// Parameters:
/// - name: Target name (e.g., "mylib")
/// - name_len: Length of name
/// - deps_json: JSON array of dep names, e.g., '["dep1", "dep2"]'
/// - deps_json_len: Length of deps JSON
/// - callback: Function to call when deps are resolved
/// - user_data: Opaque pointer passed to callback
///
/// Returns 0 on success, -1 on error
#[no_mangle]
pub extern "C" fn dice_register_target(
  name: *const c_char,
  name_len: usize,
  deps_json: *const c_char,
  deps_json_len: usize,
  callback: ComputeActionFn,
  user_data: *mut c_void,
) -> i32 {
  if name.is_null() || deps_json.is_null() {
    return -1;
  }

  let name_str = unsafe {
    let bytes = slice::from_raw_parts(name as *const u8, name_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  let deps_json_str = unsafe {
    let bytes = slice::from_raw_parts(deps_json as *const u8, deps_json_len);
    String::from_utf8_lossy(bytes).into_owned()
  };

  // Parse deps JSON (simple array of strings)
  let deps = parse_string_array(&deps_json_str);

  let info = TargetInfo {
    deps,
    callback,
    user_data: SendSyncPtr(user_data),
  };

  let mut registry = get_target_registry().lock().unwrap();
  registry.insert(name_str, info);
  0
}

/// Parse a JSON array of strings: '["a", "b", "c"]'
fn parse_string_array(json: &str) -> Vec<String> {
  let trimmed = json.trim();
  if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
    return Vec::new();
  }

  let inner = &trimmed[1..trimmed.len() - 1];
  let mut results = Vec::new();
  let mut in_string = false;
  let mut current = String::new();
  let mut escape_next = false;

  for c in inner.chars() {
    if escape_next {
      current.push(c);
      escape_next = false;
    } else if c == '\\' {
      escape_next = true;
    } else if c == '"' {
      if in_string {
        results.push(current.clone());
        current.clear();
      }
      in_string = !in_string;
    } else if in_string {
      current.push(c);
    }
  }

  results
}

/// Clear all registered targets (useful for tests/resets)
#[no_mangle]
pub extern "C" fn dice_clear_targets() {
  let mut registry = get_target_registry().lock().unwrap();
  registry.clear();
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

  let action_key = TargetKey(key_str);

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

/// Get log message from result (build output/errors)
/// Caller must NOT free the returned string - it's owned by the result
#[no_mangle]
pub extern "C" fn dice_result_log(
  handle: *mut ResultHandle,
  out_len: *mut usize,
) -> *const c_char {
  if handle.is_null() {
    return ptr::null();
  }
  let handle = unsafe { &*handle };
  match &handle.value {
    Some(v) if !v.log.is_empty() => {
      if !out_len.is_null() {
        unsafe { *out_len = v.log.len() };
      }
      v.log.as_ptr() as *const c_char
    }
    _ => ptr::null(),
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

  #[test]
  fn test_serialize_dep_results() {
    let deps = vec![
      (
        "proto".to_string(),
        vec![
          "/path/to/proto.o".to_string(),
          "/path/to/proto2.o".to_string(),
        ],
      ),
      ("core".to_string(), vec!["/path/to/core.o".to_string()]),
    ];
    let json = serialize_dep_results(&deps);
    assert!(json.contains("\"name\":\"proto\""));
    assert!(json.contains("\"/path/to/proto.o\""));
    assert!(json.contains("\"name\":\"core\""));
  }

  #[test]
  fn test_parse_result_json() {
    let json = r#"{"outputs":["/out/foo.o","/out/bar.o"],"exit_code":0,"output_hash":"abc123","log":"success"}"#;
    let result = parse_result_json(json, "test");
    assert_eq!(result.outputs, vec!["/out/foo.o", "/out/bar.o"]);
    assert_eq!(result.exit_code, 0);
    assert_eq!(result.output_hash, "abc123");
    assert_eq!(result.log, "success");
  }

  #[test]
  fn test_parse_string_array() {
    let json = r#"["dep1", "dep2", "dep3"]"#;
    let result = parse_string_array(json);
    assert_eq!(result, vec!["dep1", "dep2", "dep3"]);
  }

  #[test]
  fn test_extract_json_string_array() {
    let json = r#"{"outputs":["/path/one.o","/path/two.o"],"exit_code":0}"#;
    let result = extract_json_string_array(json, "outputs");
    assert_eq!(
      result,
      Some(vec!["/path/one.o".to_string(), "/path/two.o".to_string()])
    );
  }
}
