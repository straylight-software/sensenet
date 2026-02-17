/*
 * C bindings for superconsole
 *
 * This provides a C ABI wrapper around Meta's superconsole library
 * for use from Haskell FFI.
 *
 * The design follows the slide/tokenizers pattern:
 *   Rust lib -> C ABI staticlib -> Haskell FFI
 */
#ifndef SUPERCONSOLE_C_H
#define SUPERCONSOLE_C_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════════════
 * Opaque Handles
 * ═══════════════════════════════════════════════════════════════════════════ */

/* Opaque handle to a SuperConsole instance */
typedef struct SuperConsoleHandle* superconsole_t;

/* Opaque handle to Lines (content buffer) */
typedef struct LinesHandle* lines_t;

/* Opaque handle to a Component */
typedef struct ComponentHandle* component_t;

/* ═══════════════════════════════════════════════════════════════════════════
 * SuperConsole Construction / Destruction
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Check if the terminal is compatible with superconsole
 *
 * @return 1 if compatible, 0 if not
 */
int32_t superconsole_compatible(void);

/**
 * Create a new SuperConsole
 *
 * @return SuperConsole handle, or NULL if terminal incompatible
 */
superconsole_t superconsole_new(void);

/**
 * Create a new SuperConsole, forcing creation even if terminal seems incompatible
 *
 * @param fallback_width Width to use if terminal size unavailable
 * @param fallback_height Height to use if terminal size unavailable
 * @return SuperConsole handle
 */
superconsole_t superconsole_forced_new(uint32_t fallback_width, uint32_t fallback_height);

/**
 * Free a SuperConsole
 *
 * @param sc SuperConsole handle (may be NULL)
 */
void superconsole_free(superconsole_t sc);

/* ═══════════════════════════════════════════════════════════════════════════
 * Rendering
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Render the console with the given component
 *
 * @param sc SuperConsole handle
 * @param component Component to render
 * @return 0 on success, -1 on error
 */
int32_t superconsole_render(superconsole_t sc, component_t component);

/**
 * Finalize the console (final render before cleanup)
 *
 * @param sc SuperConsole handle (consumed - do not use after)
 * @param component Component to render
 * @return 0 on success, -1 on error
 */
int32_t superconsole_finalize(superconsole_t sc, component_t component);

/**
 * Clear the canvas area
 *
 * @param sc SuperConsole handle
 * @return 0 on success, -1 on error
 */
int32_t superconsole_clear(superconsole_t sc);

/* ═══════════════════════════════════════════════════════════════════════════
 * Emitting Output
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Queue lines to be emitted above the canvas on next render
 *
 * @param sc SuperConsole handle
 * @param lines Lines to emit (ownership transferred)
 */
void superconsole_emit(superconsole_t sc, lines_t lines);

/**
 * Emit a single line of text
 *
 * @param sc SuperConsole handle
 * @param text UTF-8 text
 * @param text_len Length of text in bytes
 */
void superconsole_emit_str(superconsole_t sc, const char* text, size_t text_len);

/* ═══════════════════════════════════════════════════════════════════════════
 * Lines Construction
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Create an empty Lines buffer
 *
 * @return Lines handle
 */
lines_t lines_new(void);

/**
 * Free a Lines buffer
 *
 * @param lines Lines handle (may be NULL)
 */
void lines_free(lines_t lines);

/**
 * Add a plain text line
 *
 * @param lines Lines handle
 * @param text UTF-8 text
 * @param text_len Length of text in bytes
 * @return 0 on success, -1 on error
 */
int32_t lines_push_str(lines_t lines, const char* text, size_t text_len);

/**
 * Add a styled text line
 *
 * @param lines Lines handle
 * @param text UTF-8 text
 * @param text_len Length of text in bytes
 * @param fg_color Foreground color (ANSI 256-color code, -1 for default)
 * @param bg_color Background color (ANSI 256-color code, -1 for default)
 * @param bold 1 for bold, 0 for normal
 * @return 0 on success, -1 on error
 */
int32_t lines_push_styled(
    lines_t lines,
    const char* text,
    size_t text_len,
    int32_t fg_color,
    int32_t bg_color,
    int32_t bold
);

/**
 * Get number of lines
 *
 * @param lines Lines handle
 * @return Number of lines
 */
size_t lines_len(lines_t lines);

/* ═══════════════════════════════════════════════════════════════════════════
 * Built-in Components
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Create a simple text component (Echo)
 *
 * @param lines Lines to display (ownership transferred)
 * @return Component handle
 */
component_t component_echo(lines_t lines);

/**
 * Create a spinner component
 *
 * @param frames Spinner animation frames (comma-separated UTF-8 strings)
 * @param frames_len Length of frames string
 * @param tick Current animation tick
 * @return Component handle
 */
component_t component_spinner(const char* frames, size_t frames_len, uint64_t tick);

/**
 * Create a blank component (empty space)
 *
 * @return Component handle
 */
component_t component_blank(void);

/**
 * Free a component
 *
 * @param component Component handle (may be NULL)
 */
void component_free(component_t component);

/* ═══════════════════════════════════════════════════════════════════════════
 * Component Composition
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Stack components vertically
 *
 * @param components Array of component handles
 * @param count Number of components
 * @return New composite component (original components consumed)
 */
component_t component_vertical(component_t* components, size_t count);

/**
 * Stack components horizontally
 *
 * @param components Array of component handles
 * @param count Number of components
 * @return New composite component (original components consumed)
 */
component_t component_horizontal(component_t* components, size_t count);

/**
 * Add padding to a component
 *
 * @param component Component to pad (consumed)
 * @param top Top padding
 * @param right Right padding
 * @param bottom Bottom padding
 * @param left Left padding
 * @return New padded component
 */
component_t component_padded(
    component_t component,
    uint32_t top,
    uint32_t right,
    uint32_t bottom,
    uint32_t left
);

/**
 * Add border to a component
 *
 * @param component Component to border (consumed)
 * @return New bordered component
 */
component_t component_bordered(component_t component);

/* ═══════════════════════════════════════════════════════════════════════════
 * Build Progress Component (Armitage-specific)
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * This is a specialized component for displaying build progress,
 * similar to Buck2's superconsole output.
 */

/**
 * Create a build progress component
 *
 * @return Component handle for build progress tracking
 */
component_t component_build_progress(void);

/**
 * Update build progress state
 *
 * @param component Build progress component
 * @param total Total number of actions
 * @param completed Number of completed actions
 * @param running Number of currently running actions
 * @param cached Number of cache hits
 */
void build_progress_update(
    component_t component,
    uint32_t total,
    uint32_t completed,
    uint32_t running,
    uint32_t cached
);

/**
 * Add an action to the running list
 *
 * @param component Build progress component
 * @param id Action identifier
 * @param name Action display name
 * @param name_len Length of name
 * @param elapsed_ms Elapsed time in milliseconds
 */
void build_progress_add_action(
    component_t component,
    uint64_t id,
    const char* name,
    size_t name_len,
    uint64_t elapsed_ms
);

/**
 * Remove an action from the running list
 *
 * @param component Build progress component
 * @param id Action identifier to remove
 */
void build_progress_remove_action(component_t component, uint64_t id);

/**
 * Clear all running actions
 *
 * @param component Build progress component
 */
void build_progress_clear_actions(component_t component);

#ifdef __cplusplus
}
#endif

#endif /* SUPERCONSOLE_C_H */
