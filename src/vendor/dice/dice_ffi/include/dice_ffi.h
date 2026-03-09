#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct Arc_Dice Arc_Dice;

typedef struct Option_ActionResult Option_ActionResult;

typedef struct Option_DiceTransactionUpdater Option_DiceTransactionUpdater;

typedef struct Option_String Option_String;

/**
 * Tokio runtime handle - manages async execution
 */
typedef struct RuntimeHandle {
  Runtime runtime;
} RuntimeHandle;

/**
 * DICE engine handle
 */
typedef struct DiceHandle {
  struct Arc_Dice engine;
} DiceHandle;

/**
 * Callback signature for computing an action
 *
 * Called by DICE when an ActionKey needs to be computed.
 * The callback receives:
 * - key: the action key (content hash)
 * - key_len: length of key string
 * - deps_json: JSON array of dependency results
 * - deps_len: length of deps JSON
 * - user_data: opaque pointer passed at registration
 *
 * Returns a pointer to a C string containing JSON result, or null on error.
 * The returned string must be freed by the caller using dice_free_string().
 */
typedef char *(*ComputeActionFn)(const char *key,
                                 uintptr_t key_len,
                                 const char *deps_json,
                                 uintptr_t deps_len,
                                 void *user_data);

/**
 * Transaction updater handle (for injecting values)
 */
typedef struct UpdaterHandle {
  struct Option_DiceTransactionUpdater updater;
} UpdaterHandle;

/**
 * Transaction handle (for computing values)
 */
typedef struct TransactionHandle {
  DiceTransaction transaction;
} TransactionHandle;

/**
 * Computation result handle (returned from compute)
 */
typedef struct ResultHandle {
  struct Option_ActionResult value;
  struct Option_String error;
} ResultHandle;

/**
 * Create a new Tokio runtime for DICE async operations
 */
struct RuntimeHandle *dice_runtime_new(void);

/**
 * Free a Tokio runtime
 */
void dice_runtime_free(struct RuntimeHandle *handle);

/**
 * Create a new DICE engine
 */
struct DiceHandle *dice_engine_new(void);

/**
 * Free a DICE engine
 */
void dice_engine_free(struct DiceHandle *handle);

/**
 * Register a compute callback for action keys (legacy API)
 *
 * key_type: Name of the key type (e.g., "action")
 * callback: Function to call when computing values
 * user_data: Opaque pointer passed to callback
 */
int32_t dice_register_compute(const char *key_type,
                              uintptr_t key_type_len,
                              ComputeActionFn callback,
                              void *user_data);

/**
 * Register a target with its dependencies
 *
 * This is the primary API for dependency-aware builds. When the target is computed:
 * 1. DICE computes all dependencies first (via ctx.compute())
 * 2. Dep outputs are serialized to JSON
 * 3. Haskell callback receives resolved dep outputs
 *
 * Parameters:
 * - name: Target name (e.g., "mylib")
 * - name_len: Length of name
 * - deps_json: JSON array of dep names, e.g., '["dep1", "dep2"]'
 * - deps_json_len: Length of deps JSON
 * - callback: Function to call when deps are resolved
 * - user_data: Opaque pointer passed to callback
 *
 * Returns 0 on success, -1 on error
 */
int32_t dice_register_target(const char *name,
                             uintptr_t name_len,
                             const char *deps_json,
                             uintptr_t deps_json_len,
                             ComputeActionFn callback,
                             void *user_data);

/**
 * Clear all registered targets (useful for tests/resets)
 */
void dice_clear_targets(void);

/**
 * Create a new transaction updater (for injecting values)
 */
struct UpdaterHandle *dice_updater_new(struct DiceHandle *dice);

/**
 * Inject a source file value (path -> hash)
 */
int32_t dice_inject_source(struct UpdaterHandle *updater,
                           const char *path,
                           uintptr_t path_len,
                           const char *hash,
                           uintptr_t hash_len,
                           uint64_t size);

/**
 * Commit the updater and get a transaction (blocking)
 */
struct TransactionHandle *dice_commit(struct RuntimeHandle *runtime, struct UpdaterHandle *updater);

/**
 * Free an updater handle
 */
void dice_updater_free(struct UpdaterHandle *handle);

/**
 * Free a transaction handle
 */
void dice_transaction_free(struct TransactionHandle *handle);

/**
 * Compute an action key (blocking)
 *
 * Returns a ResultHandle that must be freed with dice_result_free()
 */
struct ResultHandle *dice_compute_action(struct RuntimeHandle *runtime,
                                         struct TransactionHandle *transaction,
                                         const char *key,
                                         uintptr_t key_len);

/**
 * Check if computation succeeded
 */
int32_t dice_result_ok(struct ResultHandle *handle);

/**
 * Get exit code from result (0 on success)
 */
int32_t dice_result_exit_code(struct ResultHandle *handle);

/**
 * Get number of outputs from result
 */
uintptr_t dice_result_output_count(struct ResultHandle *handle);

/**
 * Get output path at index (returns null if out of bounds)
 * Caller must NOT free the returned string - it's owned by the result
 */
const char *dice_result_output_at(struct ResultHandle *handle, uintptr_t index, uintptr_t *out_len);

/**
 * Get error message (returns null if no error)
 * Caller must NOT free the returned string - it's owned by the result
 */
const char *dice_result_error(struct ResultHandle *handle, uintptr_t *out_len);

/**
 * Free a result handle
 */
void dice_result_free(struct ResultHandle *handle);

/**
 * Compute SHA256 hash of data
 * Returns a hex-encoded string that must be freed with dice_free_string()
 */
char *dice_hash_sha256(const uint8_t *data, uintptr_t data_len);

/**
 * Free a string allocated by this library
 */
void dice_free_string(char *s);

/**
 * Get version string
 */
const char *dice_version(void);
