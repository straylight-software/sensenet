//! C FFI bindings for Meta's superconsole TUI library
//!
//! This provides a C ABI wrapper around superconsole for use from Haskell FFI.
//! The design follows the DICE FFI pattern: Rust lib -> C ABI staticlib -> Haskell FFI

use libc::{c_char, size_t};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use superconsole::{Component, Dimensions, DrawMode, Line, Lines, Span, SuperConsole};

// ═══════════════════════════════════════════════════════════════════════════
// Opaque Handle Types
// ═══════════════════════════════════════════════════════════════════════════

/// Opaque handle to SuperConsole
pub struct SuperConsoleHandle {
  console: SuperConsole,
}

/// Opaque handle to Lines buffer
pub struct LinesHandle {
  lines: Lines,
}

/// Component wrapper that can hold different component types
pub enum ComponentHandle {
  Echo(Lines),
  Blank,
  BuildProgress(Arc<Mutex<BuildProgressState>>),
  Vertical(Vec<ComponentHandle>),
  Horizontal(Vec<ComponentHandle>),
  Padded {
    inner: Box<ComponentHandle>,
    top: u32,
    right: u32,
    bottom: u32,
    left: u32,
  },
  Bordered(Box<ComponentHandle>),
  Spinner {
    frames: Vec<String>,
    tick: u64,
  },
}

/// State for build progress component
pub struct BuildProgressState {
  pub total: u32,
  pub completed: u32,
  pub running: u32,
  pub cached: u32,
  pub actions: HashMap<u64, ActionState>,
}

pub struct ActionState {
  pub name: String,
  pub elapsed_ms: u64,
}

impl Default for BuildProgressState {
  fn default() -> Self {
    Self {
      total: 0,
      completed: 0,
      running: 0,
      cached: 0,
      actions: HashMap::new(),
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Component Implementation
// ═══════════════════════════════════════════════════════════════════════════

impl Component for ComponentHandle {
  fn draw_unchecked(&self, dimensions: Dimensions, mode: DrawMode) -> anyhow::Result<Lines> {
    match self {
      ComponentHandle::Echo(lines) => Ok(lines.clone()),
      ComponentHandle::Blank => Ok(Lines::new()),
      ComponentHandle::Spinner { frames, tick } => {
        if frames.is_empty() {
          return Ok(Lines::new());
        }
        let idx = (*tick as usize) % frames.len();
        let frame = &frames[idx];
        Ok(Lines(vec![Line::from_iter([Span::new_unstyled(frame)?])]))
      }
      ComponentHandle::BuildProgress(state) => {
        let state = state.lock();
        let mut lines = Vec::new();

        // Header line with progress
        let progress_pct = if state.total > 0 {
          (state.completed as f64 / state.total as f64 * 100.0) as u32
        } else {
          0
        };

        // Progress bar
        let bar_width = dimensions.width.saturating_sub(30).min(40) as usize;
        let filled = (bar_width as f64 * progress_pct as f64 / 100.0) as usize;
        let empty = bar_width.saturating_sub(filled);
        let bar = format!(
          "[{}{}] {}% ({}/{})",
          "█".repeat(filled),
          "░".repeat(empty),
          progress_pct,
          state.completed,
          state.total
        );
        lines.push(Line::from_iter([Span::new_unstyled(&bar)?]));

        // Stats line
        let stats = format!(
          "Running: {} | Cached: {} | Remaining: {}",
          state.running,
          state.cached,
          state.total.saturating_sub(state.completed)
        );
        lines.push(Line::from_iter([Span::new_unstyled(&stats)?]));

        // Active actions (show up to 8)
        let mut sorted_actions: Vec<_> = state.actions.iter().collect();
        sorted_actions.sort_by_key(|(id, _)| *id);

        for (_, action) in sorted_actions.iter().take(8) {
          let elapsed_secs = action.elapsed_ms / 1000;
          let action_line = format!(
            "  ⟳ {} ({}.{}s)",
            action.name,
            elapsed_secs,
            (action.elapsed_ms % 1000) / 100
          );
          lines.push(Line::from_iter([Span::new_unstyled(&action_line)?]));
        }

        if sorted_actions.len() > 8 {
          let more = format!("  ... and {} more", sorted_actions.len() - 8);
          lines.push(Line::from_iter([Span::new_unstyled(&more)?]));
        }

        Ok(Lines(lines))
      }
      ComponentHandle::Vertical(children) => {
        let mut result = Lines::new();
        for child in children {
          let child_lines = child.draw_unchecked(dimensions, mode)?;
          result.0.extend(child_lines.0);
        }
        Ok(result)
      }
      ComponentHandle::Horizontal(children) => {
        // Simple horizontal concatenation - join with spaces
        let mut combined_line = Vec::new();
        for child in children {
          let child_lines = child.draw_unchecked(dimensions, mode)?;
          if let Some(first_line) = child_lines.0.first() {
            combined_line.extend(first_line.iter().cloned());
            combined_line.push(Span::new_unstyled(" ")?);
          }
        }
        if combined_line.is_empty() {
          Ok(Lines::new())
        } else {
          Ok(Lines(vec![Line::from_iter(combined_line)]))
        }
      }
      ComponentHandle::Padded {
        inner,
        top,
        right: _,
        bottom,
        left,
      } => {
        let mut result = Lines::new();

        // Top padding
        for _ in 0..*top {
          result.0.push(Line::default());
        }

        // Inner content with left padding
        let inner_lines = inner.draw_unchecked(dimensions, mode)?;
        let left_pad = " ".repeat(*left as usize);
        for line in inner_lines.0 {
          let mut padded_spans = vec![Span::new_unstyled(&left_pad)?];
          padded_spans.extend(line.into_iter());
          result.0.push(Line::from_iter(padded_spans));
        }

        // Bottom padding
        for _ in 0..*bottom {
          result.0.push(Line::default());
        }

        Ok(result)
      }
      ComponentHandle::Bordered(inner) => {
        let inner_lines = inner.draw_unchecked(dimensions, mode)?;
        let mut result = Lines::new();

        // Calculate max width
        let max_width = inner_lines.0.iter().map(|l| l.len()).max().unwrap_or(0);

        // Top border
        let top_border = format!("┌{}┐", "─".repeat(max_width + 2));
        result
          .0
          .push(Line::from_iter([Span::new_unstyled(&top_border)?]));

        // Content with side borders
        for line in inner_lines.0 {
          let line_len = line.len();
          let padding = max_width.saturating_sub(line_len);
          let mut bordered = vec![Span::new_unstyled("│ ")?];
          bordered.extend(line.into_iter());
          bordered.push(Span::new_unstyled(&format!("{} │", " ".repeat(padding)))?);
          result.0.push(Line::from_iter(bordered));
        }

        // Bottom border
        let bottom_border = format!("└{}┘", "─".repeat(max_width + 2));
        result
          .0
          .push(Line::from_iter([Span::new_unstyled(&bottom_border)?]));

        Ok(result)
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SuperConsole FFI
// ═══════════════════════════════════════════════════════════════════════════

/// Check if terminal is compatible with superconsole
#[no_mangle]
pub extern "C" fn superconsole_compatible() -> i32 {
  if SuperConsole::compatible() { 1 } else { 0 }
}

/// Create a new SuperConsole
#[no_mangle]
pub extern "C" fn superconsole_new() -> *mut SuperConsoleHandle {
  match SuperConsole::new() {
    Some(console) => Box::into_raw(Box::new(SuperConsoleHandle { console })),
    None => std::ptr::null_mut(),
  }
}

/// Create a new SuperConsole with forced dimensions
#[no_mangle]
pub extern "C" fn superconsole_forced_new(
  fallback_width: u32,
  fallback_height: u32,
) -> *mut SuperConsoleHandle {
  let console = SuperConsole::forced_new(Dimensions {
    width: fallback_width as usize,
    height: fallback_height as usize,
  });
  Box::into_raw(Box::new(SuperConsoleHandle { console }))
}

/// Free a SuperConsole
#[no_mangle]
pub extern "C" fn superconsole_free(sc: *mut SuperConsoleHandle) {
  if !sc.is_null() {
    unsafe {
      drop(Box::from_raw(sc));
    }
  }
}

/// Render the console with the given component
#[no_mangle]
pub extern "C" fn superconsole_render(
  sc: *mut SuperConsoleHandle,
  component: *mut ComponentHandle,
) -> i32 {
  if sc.is_null() || component.is_null() {
    return -1;
  }

  unsafe {
    let sc = &mut *sc;
    let component = &*component;

    match sc.console.render(component) {
      Ok(()) => 0,
      Err(_) => -1,
    }
  }
}

/// Finalize the console (consumes it)
#[no_mangle]
pub extern "C" fn superconsole_finalize(
  sc: *mut SuperConsoleHandle,
  component: *mut ComponentHandle,
) -> i32 {
  if sc.is_null() || component.is_null() {
    return -1;
  }

  unsafe {
    let sc = Box::from_raw(sc);
    let component = &*component;

    match sc.console.finalize(component) {
      Ok(()) => 0,
      Err(_) => -1,
    }
  }
}

/// Clear the canvas area
#[no_mangle]
pub extern "C" fn superconsole_clear(sc: *mut SuperConsoleHandle) -> i32 {
  if sc.is_null() {
    return -1;
  }

  unsafe {
    let sc = &mut *sc;
    // SuperConsole doesn't have a direct clear method, but we can render an empty component
    match sc.console.render(&ComponentHandle::Blank) {
      Ok(()) => 0,
      Err(_) => -1,
    }
  }
}

/// Emit lines above the canvas
#[no_mangle]
pub extern "C" fn superconsole_emit(sc: *mut SuperConsoleHandle, lines: *mut LinesHandle) {
  if sc.is_null() || lines.is_null() {
    return;
  }

  unsafe {
    let sc = &mut *sc;
    let lines = Box::from_raw(lines);
    sc.console.emit(lines.lines);
  }
}

/// Emit a single string line
#[no_mangle]
pub extern "C" fn superconsole_emit_str(
  sc: *mut SuperConsoleHandle,
  text: *const c_char,
  text_len: size_t,
) {
  if sc.is_null() || text.is_null() {
    return;
  }

  unsafe {
    let sc = &mut *sc;
    let slice = std::slice::from_raw_parts(text as *const u8, text_len);
    if let Ok(s) = std::str::from_utf8(slice) {
      if let Ok(span) = Span::new_unstyled(s) {
        let line = Line::from_iter([span]);
        sc.console.emit(Lines(vec![line]));
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Lines FFI
// ═══════════════════════════════════════════════════════════════════════════

/// Create an empty Lines buffer
#[no_mangle]
pub extern "C" fn lines_new() -> *mut LinesHandle {
  Box::into_raw(Box::new(LinesHandle {
    lines: Lines::new(),
  }))
}

/// Free a Lines buffer
#[no_mangle]
pub extern "C" fn lines_free(lines: *mut LinesHandle) {
  if !lines.is_null() {
    unsafe {
      drop(Box::from_raw(lines));
    }
  }
}

/// Add a plain text line
#[no_mangle]
pub extern "C" fn lines_push_str(
  lines: *mut LinesHandle,
  text: *const c_char,
  text_len: size_t,
) -> i32 {
  if lines.is_null() || text.is_null() {
    return -1;
  }

  unsafe {
    let lines = &mut *lines;
    let slice = std::slice::from_raw_parts(text as *const u8, text_len);
    if let Ok(s) = std::str::from_utf8(slice) {
      if let Ok(span) = Span::new_unstyled(s) {
        lines.lines.0.push(Line::from_iter([span]));
        return 0;
      }
    }
    -1
  }
}

/// Add a styled text line
#[no_mangle]
pub extern "C" fn lines_push_styled(
  lines: *mut LinesHandle,
  text: *const c_char,
  text_len: size_t,
  fg_color: i32,
  bg_color: i32,
  bold: i32,
) -> i32 {
  if lines.is_null() || text.is_null() {
    return -1;
  }

  unsafe {
    let lines = &mut *lines;
    let slice = std::slice::from_raw_parts(text as *const u8, text_len);
    if let Ok(s) = std::str::from_utf8(slice) {
      use superconsole::style::{Color, StyledContent, Stylize};

      // Build styled content
      let mut styled: StyledContent<String> = s.to_string().stylize();

      // Apply foreground color
      if fg_color >= 0 && fg_color < 256 {
        styled = styled.with(Color::AnsiValue(fg_color as u8));
      }

      // Apply background color
      if bg_color >= 0 && bg_color < 256 {
        styled = styled.on(Color::AnsiValue(bg_color as u8));
      }

      // Apply bold
      if bold != 0 {
        styled = styled.bold();
      }

      let span = Span::new_styled_lossy(styled);
      lines.lines.0.push(Line::from_iter([span]));
      return 0;
    }
    -1
  }
}

/// Get number of lines
#[no_mangle]
pub extern "C" fn lines_len(lines: *mut LinesHandle) -> size_t {
  if lines.is_null() {
    return 0;
  }

  unsafe {
    let lines = &*lines;
    lines.lines.0.len()
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Component FFI
// ═══════════════════════════════════════════════════════════════════════════

/// Create an echo component from lines
#[no_mangle]
pub extern "C" fn component_echo(lines: *mut LinesHandle) -> *mut ComponentHandle {
  if lines.is_null() {
    return std::ptr::null_mut();
  }

  unsafe {
    let lines = Box::from_raw(lines);
    Box::into_raw(Box::new(ComponentHandle::Echo(lines.lines)))
  }
}

/// Create a spinner component
#[no_mangle]
pub extern "C" fn component_spinner(
  frames: *const c_char,
  frames_len: size_t,
  tick: u64,
) -> *mut ComponentHandle {
  if frames.is_null() {
    return std::ptr::null_mut();
  }

  unsafe {
    let slice = std::slice::from_raw_parts(frames as *const u8, frames_len);
    if let Ok(s) = std::str::from_utf8(slice) {
      let frame_vec: Vec<String> = s.split(',').map(|f| f.to_string()).collect();
      return Box::into_raw(Box::new(ComponentHandle::Spinner {
        frames: frame_vec,
        tick,
      }));
    }
    std::ptr::null_mut()
  }
}

/// Create a blank component
#[no_mangle]
pub extern "C" fn component_blank() -> *mut ComponentHandle {
  Box::into_raw(Box::new(ComponentHandle::Blank))
}

/// Free a component
#[no_mangle]
pub extern "C" fn component_free(component: *mut ComponentHandle) {
  if !component.is_null() {
    unsafe {
      drop(Box::from_raw(component));
    }
  }
}

/// Stack components vertically
#[no_mangle]
pub extern "C" fn component_vertical(
  components: *mut *mut ComponentHandle,
  count: size_t,
) -> *mut ComponentHandle {
  if components.is_null() || count == 0 {
    return Box::into_raw(Box::new(ComponentHandle::Blank));
  }

  unsafe {
    let mut children = Vec::with_capacity(count);
    for i in 0..count {
      let comp_ptr = *components.add(i);
      if !comp_ptr.is_null() {
        children.push(*Box::from_raw(comp_ptr));
      }
    }
    Box::into_raw(Box::new(ComponentHandle::Vertical(children)))
  }
}

/// Stack components horizontally
#[no_mangle]
pub extern "C" fn component_horizontal(
  components: *mut *mut ComponentHandle,
  count: size_t,
) -> *mut ComponentHandle {
  if components.is_null() || count == 0 {
    return Box::into_raw(Box::new(ComponentHandle::Blank));
  }

  unsafe {
    let mut children = Vec::with_capacity(count);
    for i in 0..count {
      let comp_ptr = *components.add(i);
      if !comp_ptr.is_null() {
        children.push(*Box::from_raw(comp_ptr));
      }
    }
    Box::into_raw(Box::new(ComponentHandle::Horizontal(children)))
  }
}

/// Add padding to a component
#[no_mangle]
pub extern "C" fn component_padded(
  component: *mut ComponentHandle,
  top: u32,
  right: u32,
  bottom: u32,
  left: u32,
) -> *mut ComponentHandle {
  if component.is_null() {
    return std::ptr::null_mut();
  }

  unsafe {
    let inner = Box::from_raw(component);
    Box::into_raw(Box::new(ComponentHandle::Padded {
      inner,
      top,
      right,
      bottom,
      left,
    }))
  }
}

/// Add border to a component
#[no_mangle]
pub extern "C" fn component_bordered(component: *mut ComponentHandle) -> *mut ComponentHandle {
  if component.is_null() {
    return std::ptr::null_mut();
  }

  unsafe {
    let inner = Box::from_raw(component);
    Box::into_raw(Box::new(ComponentHandle::Bordered(inner)))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Build Progress Component FFI
// ═══════════════════════════════════════════════════════════════════════════

/// Create a build progress component
#[no_mangle]
pub extern "C" fn component_build_progress() -> *mut ComponentHandle {
  Box::into_raw(Box::new(ComponentHandle::BuildProgress(Arc::new(
    Mutex::new(BuildProgressState::default()),
  ))))
}

/// Update build progress state
#[no_mangle]
pub extern "C" fn build_progress_update(
  component: *mut ComponentHandle,
  total: u32,
  completed: u32,
  running: u32,
  cached: u32,
) {
  if component.is_null() {
    return;
  }

  unsafe {
    let component = &*component;
    if let ComponentHandle::BuildProgress(state) = component {
      let mut state = state.lock();
      state.total = total;
      state.completed = completed;
      state.running = running;
      state.cached = cached;
    }
  }
}

/// Add an action to the running list
#[no_mangle]
pub extern "C" fn build_progress_add_action(
  component: *mut ComponentHandle,
  id: u64,
  name: *const c_char,
  name_len: size_t,
  elapsed_ms: u64,
) {
  if component.is_null() || name.is_null() {
    return;
  }

  unsafe {
    let component = &*component;
    if let ComponentHandle::BuildProgress(state) = component {
      let slice = std::slice::from_raw_parts(name as *const u8, name_len);
      if let Ok(name_str) = std::str::from_utf8(slice) {
        let mut state = state.lock();
        state.actions.insert(
          id,
          ActionState {
            name: name_str.to_string(),
            elapsed_ms,
          },
        );
      }
    }
  }
}

/// Remove an action from the running list
#[no_mangle]
pub extern "C" fn build_progress_remove_action(component: *mut ComponentHandle, id: u64) {
  if component.is_null() {
    return;
  }

  unsafe {
    let component = &*component;
    if let ComponentHandle::BuildProgress(state) = component {
      let mut state = state.lock();
      state.actions.remove(&id);
    }
  }
}

/// Clear all running actions
#[no_mangle]
pub extern "C" fn build_progress_clear_actions(component: *mut ComponentHandle) {
  if component.is_null() {
    return;
  }

  unsafe {
    let component = &*component;
    if let ComponentHandle::BuildProgress(state) = component {
      let mut state = state.lock();
      state.actions.clear();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Test helper - not exported via C API
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn test_lines_creation() {
    let lines = lines_new();
    assert!(!lines.is_null());

    let text = "Hello, World!";
    let result = lines_push_str(lines, text.as_ptr() as *const c_char, text.len());
    assert_eq!(result, 0);

    assert_eq!(lines_len(lines), 1);

    lines_free(lines);
  }

  #[test]
  fn test_build_progress() {
    let component = component_build_progress();
    assert!(!component.is_null());

    build_progress_update(component, 10, 3, 2, 1);

    let action_name = "Building foo";
    build_progress_add_action(
      component,
      1,
      action_name.as_ptr() as *const c_char,
      action_name.len(),
      1500,
    );

    component_free(component);
  }
}
