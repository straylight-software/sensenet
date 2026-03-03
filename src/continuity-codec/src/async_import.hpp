// Continuity.Codec.Dhall - Async Import Resolution via libevring
// Batched io_uring file I/O and HTTP/3 for <10ms evaluation
//
// Strategy:
//   1. Collect all import paths (local + HTTP)
//   2. Batch fetch HTTP imports via curl_multi (HTTP/3)
//   3. Load local files via sync I/O (fast for local SSDs)
//   4. Parse all files
//   5. Repeat until no new imports
//   6. Value caching avoids re-evaluation
//
// straylight.software · 2026

#pragma once

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <format>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>

#include "straylight/evring/evring.h"
#include "straylight/evring/ring.h"

#include "dhall.hpp"
#include "http_fetch.hpp"
#include "parser.hpp"

#ifdef ENABLE_HTTP2
#  include "http2_fetcher.hpp"
#endif

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// ASYNC IMPORT RESOLVER
// ═══════════════════════════════════════════════════════════════════════════════

class AsyncImportResolver {
  Arena& arena_;
  Interner& interner_;
  std::unique_ptr<evring::ring> ring_;
  HttpFetcher http_fetcher_;
#ifdef ENABLE_HTTP2
  Http2Fetcher http2_fetcher_;
#endif

  // Cache: URL or absolute path -> parsed & resolved AST
  std::unordered_map<std::string, ExprPtr> cache_;

  // Value cache: URL or absolute path -> evaluated value (for avoiding re-evaluation)
  std::unordered_map<std::string, ValuePtr> value_cache_;

  // File content cache: URL or absolute path -> file contents
  std::unordered_map<std::string, std::string> content_cache_;

  // Currently resolving (for cycle detection)
  std::unordered_set<std::string> resolving_;

  // Failed imports (don't retry)
  std::unordered_set<std::string> failed_;

  // Expressions whose imports have been collected (avoid re-traversing)
  std::unordered_set<std::string> collected_;

  // Statx buffers (reusable)
  std::vector<struct statx> statx_buffers_;

  // Read buffers (per-file)
  struct FileBuffer {
    std::string path;
    int fd{-1};
    std::size_t size{0};
    std::vector<char> data;
  };
  std::vector<FileBuffer> file_buffers_;

public:
  AsyncImportResolver(Arena& arena, Interner& interner)
      : arena_(arena),
        interner_(interner),
        ring_(evring::make_io_uring_ring(1024, evring::ring_flags::single_issuer)) {}

  /// Resolve all imports in an expression
  ExprPtr resolve(ExprPtr expr, const std::filesystem::path& base_dir);

  /// Get cache stats
  std::size_t cache_size() const { return cache_.size(); }

  /// Evaluate an import with value caching
  /// If the import has been evaluated before, returns cached value directly
  ValuePtr eval_import(const std::string& abs_path, Evaluator& eval);

  /// Get value cache stats
  std::size_t value_cache_size() const { return value_cache_.size(); }

private:
  /// Collect all import paths from an expression (non-recursive)
  void collect_imports(ExprPtr expr, const std::filesystem::path& base_dir,
                       std::vector<std::string>& out_paths);

  /// Batch load files using io_uring (for future HTTP/3 imports)
  void batch_load_async(const std::vector<std::string>& paths);

  /// Load a single local file synchronously
  ExprPtr load_file_sync(const std::string& abs_path);

  /// Load a single HTTP URL
  ExprPtr load_http(const std::string& url, std::string_view expected_hash);

  /// Resolve imports in an expression (recursive)
  ExprPtr resolve_expr(ExprPtr expr, const std::filesystem::path& base_dir);

  /// Resolve relative URL paths
  std::string resolve_http_path(const std::string& base_url, std::string_view relative_path);

  /// Collect HTTP imports from an expression (for wave-based resolution)
  void collect_http_imports(ExprPtr expr, const std::filesystem::path& base_dir,
                            std::vector<std::string>& out_urls);

public:
  /// Wave-based HTTP resolution: fetch all imports in parallel batches (curl -Z)
  void resolve_http_waves(const std::string& root_url);

  /// Wave-based HTTP/2 resolution using evring native HTTP/2 stack
  void resolve_http_waves_h2(const std::string& root_url);
};

// ═══════════════════════════════════════════════════════════════════════════════
// IMPLEMENTATION
// ═══════════════════════════════════════════════════════════════════════════════

inline void AsyncImportResolver::collect_imports(ExprPtr expr,
                                                 const std::filesystem::path& base_dir,
                                                 std::vector<std::string>& out_paths) {
  if (!expr)
    return;

  switch (expr->kind) {
    case Expr::Kind::Import: {
      std::string_view path_sv(expr->import.path, expr->import.path_len);
      std::filesystem::path import_path(path_sv);
      std::filesystem::path resolved =
          import_path.is_relative() ? base_dir / import_path : import_path;
      auto abs_path = std::filesystem::weakly_canonical(resolved).string();

      // Skip already cached, in-progress, or failed imports
      if (cache_.find(abs_path) == cache_.end() && resolving_.find(abs_path) == resolving_.end() &&
          failed_.find(abs_path) == failed_.end()) {
        out_paths.push_back(abs_path);
        resolving_.insert(abs_path);
      }
      break;
    }

    case Expr::Kind::Lam:
      collect_imports(expr->lam.type, base_dir, out_paths);
      collect_imports(expr->lam.body, base_dir, out_paths);
      break;

    case Expr::Kind::Pi:
      collect_imports(expr->pi.domain, base_dir, out_paths);
      collect_imports(expr->pi.codomain, base_dir, out_paths);
      break;

    case Expr::Kind::App:
      collect_imports(expr->app.func, base_dir, out_paths);
      collect_imports(expr->app.arg, base_dir, out_paths);
      break;

    case Expr::Kind::Let:
      if (expr->let.type)
        collect_imports(expr->let.type, base_dir, out_paths);
      collect_imports(expr->let.value, base_dir, out_paths);
      collect_imports(expr->let.body, base_dir, out_paths);
      break;

    case Expr::Kind::BoolAnd:
    case Expr::Kind::BoolOr:
    case Expr::Kind::BoolEq:
    case Expr::Kind::NatPlus:
    case Expr::Kind::NatTimes:
    case Expr::Kind::TextAppend:
    case Expr::Kind::Prefer:
      collect_imports(expr->binop.lhs, base_dir, out_paths);
      collect_imports(expr->binop.rhs, base_dir, out_paths);
      break;

    case Expr::Kind::BoolIf:
      collect_imports(expr->if_.cond, base_dir, out_paths);
      collect_imports(expr->if_.then_, base_dir, out_paths);
      collect_imports(expr->if_.else_, base_dir, out_paths);
      break;

    case Expr::Kind::List:
      if (expr->list.type)
        collect_imports(expr->list.type, base_dir, out_paths);
      for (std::size_t i = 0; i < expr->list.count; ++i) {
        collect_imports(expr->list.elems[i], base_dir, out_paths);
      }
      break;

    case Expr::Kind::RecordLit:
    case Expr::Kind::Record:
      for (const auto& entry : *expr->fields) {
        collect_imports(entry.value, base_dir, out_paths);
      }
      break;

    case Expr::Kind::Field:
      collect_imports(expr->field.record, base_dir, out_paths);
      break;

    case Expr::Kind::Annot:
      collect_imports(expr->annot.expr, base_dir, out_paths);
      collect_imports(expr->annot.type, base_dir, out_paths);
      break;

    default:
      break;
  }
}

inline void AsyncImportResolver::batch_load_async(const std::vector<std::string>& paths) {
  if (paths.empty())
    return;

  const std::size_t n = paths.size();

  // For local files, sync I/O is faster than io_uring overhead.
  // When we add HTTP/3 imports, we'll use io_uring for those.
  // For now, use simple sync reads to match the sync resolver's performance.

  file_buffers_.resize(n);

  for (std::size_t i = 0; i < n; ++i) {
    file_buffers_[i].path = paths[i];
    file_buffers_[i].fd = -1;
    file_buffers_[i].size = 0;
    file_buffers_[i].data.clear();

    // Simple sync read
    std::ifstream file(paths[i], std::ios::ate | std::ios::binary);
    if (!file) {
      continue; // Failed, data stays empty
    }

    auto size = file.tellg();
    if (size <= 0) {
      continue;
    }

    file.seekg(0);
    file_buffers_[i].data.resize(static_cast<std::size_t>(size));
    file.read(file_buffers_[i].data.data(), size);
    file_buffers_[i].size = static_cast<std::size_t>(size);
  }

  // Phase 5: Parse all files and add to cache (or mark as failed)
  for (std::size_t i = 0; i < n; ++i) {
    // Clear from resolving set
    resolving_.erase(file_buffers_[i].path);

    if (file_buffers_[i].data.empty()) {
      // Failed to read - mark as failed so we don't retry
      failed_.insert(file_buffers_[i].path);
      continue;
    }

    std::string_view source(file_buffers_[i].data.data(), file_buffers_[i].data.size());

    try {
      Parser parser(source, arena_, interner_);
      auto result = parser.parse();

      if (!result) {
        failed_.insert(file_buffers_[i].path);
        continue; // Parse failed, mark as failed but continue
      }

      cache_[file_buffers_[i].path] = *result;

      // Keep content in cache for potential re-parse
      content_cache_[file_buffers_[i].path] =
          std::string(file_buffers_[i].data.begin(), file_buffers_[i].data.end());

    } catch (const std::exception& e) {
      failed_.insert(file_buffers_[i].path);
    }
  }
}

inline ExprPtr AsyncImportResolver::load_file_sync(const std::string& abs_path) {
  // Check cache first
  if (auto it = cache_.find(abs_path); it != cache_.end()) {
    return it->second;
  }

  // Check if already failed
  if (failed_.count(abs_path)) {
    throw std::runtime_error(std::format("Cannot open file: {}", abs_path));
  }

  // Cycle detection
  if (resolving_.count(abs_path)) {
    throw std::runtime_error(std::format("Import cycle detected: {}", abs_path));
  }
  resolving_.insert(abs_path);

  // Read file
  std::ifstream file(abs_path, std::ios::ate | std::ios::binary);
  if (!file) {
    resolving_.erase(abs_path);
    failed_.insert(abs_path);
    throw std::runtime_error(std::format("Cannot open file: {}", abs_path));
  }

  auto size = file.tellg();
  file.seekg(0);
  std::string content(static_cast<std::size_t>(size), '\0');
  file.read(content.data(), size);

  // Parse
  Parser parser(content, arena_, interner_);
  auto result = parser.parse();

  if (!result) {
    resolving_.erase(abs_path);
    failed_.insert(abs_path);
    throw std::runtime_error(
        std::format("Parse error in {}: {}", abs_path, result.error().message));
  }

  // Resolve imports recursively
  std::filesystem::path p(abs_path);
  auto* resolved = resolve_expr(*result, p.parent_path());

  resolving_.erase(abs_path);
  cache_[abs_path] = resolved;
  content_cache_[abs_path] = std::move(content);

  return resolved;
}

inline ExprPtr AsyncImportResolver::resolve_expr(ExprPtr expr,
                                                 const std::filesystem::path& base_dir) {
  if (!expr)
    return nullptr;

  switch (expr->kind) {
    case Expr::Kind::Import: {
      std::string_view path_sv(expr->import.path, expr->import.path_len);
      std::string_view hash_sv(expr->import.hash ? expr->import.hash : "", expr->import.hash_len);

      std::string key;
      bool is_http = expr->import.is_http;

      // Check if base_dir is an HTTP URL (from an HTTP-fetched parent)
      std::string base_dir_str = base_dir.string();
      bool base_is_http =
          base_dir_str.starts_with("https://") || base_dir_str.starts_with("http://");

      if (is_http) {
        // Explicit HTTP import - key is the full URL
        key = std::string(path_sv);
      } else if (base_is_http) {
        // Relative import inside an HTTP-fetched file
        // Resolve relative to the HTTP base URL
        key = resolve_http_path(base_dir_str, path_sv);
        is_http = true;
      } else {
        // Local import - resolve to absolute path
        std::filesystem::path import_path(path_sv);
        std::filesystem::path resolved =
            import_path.is_relative() ? base_dir / import_path : import_path;
        key = std::filesystem::weakly_canonical(resolved).string();
      }

      // Check if this was a failed import
      if (failed_.find(key) != failed_.end()) {
        throw std::runtime_error(std::format("Cannot open: {}", key));
      }

      // Load and parse if not in cache
      if (cache_.find(key) == cache_.end()) {
        if (is_http) {
          load_http(key, hash_sv);
        } else {
          load_file_sync(key);
        }
      }

      // Return a new Import node with resolved key (URL or path)
      // The evaluator will use value caching to avoid re-evaluation
      char* abs_path_data = arena_.alloc_array<char>(key.size() + 1).data();
      std::copy(key.begin(), key.end(), abs_path_data);
      abs_path_data[key.size()] = '\0';

      // Copy hash if present
      const char* hash_data = nullptr;
      if (!hash_sv.empty()) {
        char* hd = arena_.alloc_array<char>(hash_sv.size() + 1).data();
        std::copy(hash_sv.begin(), hash_sv.end(), hd);
        hd[hash_sv.size()] = '\0';
        hash_data = hd;
      }

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Import;
      e->import.path = expr->import.path;
      e->import.path_len = expr->import.path_len;
      e->import.abs_path = abs_path_data;
      e->import.abs_path_len = key.size();
      e->import.hash = hash_data;
      e->import.hash_len = hash_sv.size();
      e->import.is_http = is_http;
      return e;
    }
    case Expr::Kind::Lam: {
      auto* type = resolve_expr(expr->lam.type, base_dir);
      auto* body = resolve_expr(expr->lam.body, base_dir);
      if (type == expr->lam.type && body == expr->lam.body)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Lam;
      e->lam = {expr->lam.name, type, body};
      return e;
    }

    case Expr::Kind::Pi: {
      auto* domain = resolve_expr(expr->pi.domain, base_dir);
      auto* codomain = resolve_expr(expr->pi.codomain, base_dir);
      if (domain == expr->pi.domain && codomain == expr->pi.codomain)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Pi;
      e->pi = {expr->pi.name, domain, codomain};
      return e;
    }

    case Expr::Kind::App: {
      auto* func = resolve_expr(expr->app.func, base_dir);
      auto* arg = resolve_expr(expr->app.arg, base_dir);
      if (func == expr->app.func && arg == expr->app.arg)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::App;
      e->app = {func, arg};
      return e;
    }

    case Expr::Kind::Let: {
      auto* type = expr->let.type ? resolve_expr(expr->let.type, base_dir) : nullptr;
      auto* value = resolve_expr(expr->let.value, base_dir);
      auto* body = resolve_expr(expr->let.body, base_dir);

      if (type == expr->let.type && value == expr->let.value && body == expr->let.body)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Let;
      e->let = {expr->let.name, type, value, body};
      return e;
    }

    case Expr::Kind::BoolAnd:
    case Expr::Kind::BoolOr:
    case Expr::Kind::BoolEq:
    case Expr::Kind::NatPlus:
    case Expr::Kind::NatTimes:
    case Expr::Kind::TextAppend:
    case Expr::Kind::Prefer: {
      auto* lhs = resolve_expr(expr->binop.lhs, base_dir);
      auto* rhs = resolve_expr(expr->binop.rhs, base_dir);
      if (lhs == expr->binop.lhs && rhs == expr->binop.rhs)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = expr->kind;
      e->binop = {lhs, rhs};
      return e;
    }

    case Expr::Kind::BoolIf: {
      auto* cond = resolve_expr(expr->if_.cond, base_dir);
      auto* then_ = resolve_expr(expr->if_.then_, base_dir);
      auto* else_ = resolve_expr(expr->if_.else_, base_dir);
      if (cond == expr->if_.cond && then_ == expr->if_.then_ && else_ == expr->if_.else_)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::BoolIf;
      e->if_ = {cond, then_, else_};
      return e;
    }

    case Expr::Kind::List: {
      bool changed = false;
      auto span = arena_.alloc_array<ExprPtr>(expr->list.count);
      for (std::size_t i = 0; i < expr->list.count; ++i) {
        span[i] = resolve_expr(expr->list.elems[i], base_dir);
        if (span[i] != expr->list.elems[i])
          changed = true;
      }
      auto* type = expr->list.type ? resolve_expr(expr->list.type, base_dir) : nullptr;
      if (!changed && type == expr->list.type)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::List;
      e->list = {type, span.data(), span.size()};
      return e;
    }

    case Expr::Kind::RecordLit:
    case Expr::Kind::Record: {
      bool changed = false;
      auto* fields = arena_.alloc<Fields<ExprPtr>>();
      fields->reserve(expr->fields->size());
      for (const auto& entry : *expr->fields) {
        auto* resolved = resolve_expr(entry.value, base_dir);
        if (resolved != entry.value)
          changed = true;
        fields->push_back_unchecked(entry.name, resolved);
      }
      if (!changed)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = expr->kind;
      e->fields = fields;
      return e;
    }

    case Expr::Kind::Field: {
      auto* record = resolve_expr(expr->field.record, base_dir);
      if (record == expr->field.record)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Field;
      e->field = {record, expr->field.name};
      return e;
    }

    case Expr::Kind::Annot: {
      auto* ex = resolve_expr(expr->annot.expr, base_dir);
      auto* type = resolve_expr(expr->annot.type, base_dir);
      if (ex == expr->annot.expr && type == expr->annot.type)
        return expr;

      auto* e = arena_.alloc<Expr>();
      e->kind = Expr::Kind::Annot;
      e->annot = {ex, type};
      return e;
    }

    default:
      return expr;
  }
}

inline ExprPtr AsyncImportResolver::resolve(ExprPtr expr, const std::filesystem::path& base_dir) {
  // For local files, use recursive resolution (same as sync resolver).
  // The io_uring ring is kept available for future HTTP/3 imports where
  // wave-based batching will provide significant speedup.
  //
  // When we add HTTP/3 support:
  // 1. Check if any imports are https:// URLs
  // 2. If so, use wave-based batch_load_async with io_uring + HTTP/3
  // 3. For local files, continue using load_file_sync

  return resolve_expr(expr, base_dir);
}

inline ValuePtr AsyncImportResolver::eval_import(const std::string& abs_path, Evaluator& eval) {
  // Check value cache first - if we've evaluated this import before, return cached value
  if (auto it = value_cache_.find(abs_path); it != value_cache_.end()) {
    return it->second;
  }

  // Get the resolved expression from the AST cache
  auto expr_it = cache_.find(abs_path);
  if (expr_it == cache_.end()) {
    throw std::runtime_error(std::format("Import not in cache: {}", abs_path));
  }

  // Determine base path/URL for relative import resolution
  std::filesystem::path base_dir;
  if (abs_path.starts_with("https://") || abs_path.starts_with("http://")) {
    // For HTTP URLs, use the URL's directory as base
    // This is handled specially in resolve_expr for is_http imports
    base_dir = abs_path.substr(0, abs_path.rfind('/'));
  } else {
    base_dir = std::filesystem::path(abs_path).parent_path();
  }

  // Evaluate with empty environment (imports are evaluated at top level)
  auto* resolved = resolve_expr(expr_it->second, base_dir);

  // Evaluate and cache
  Env env;
  auto* value = eval.eval(env, resolved);
  value_cache_[abs_path] = value;
  return value;
}

inline std::string AsyncImportResolver::resolve_http_path(const std::string& base_url,
                                                          std::string_view relative_path) {
  spdlog::debug("resolve_http_path: base='{}' rel='{}'", base_url, relative_path);

  // Extract scheme://host from base URL
  auto scheme_end = base_url.find("://");
  if (scheme_end == std::string::npos) {
    throw std::runtime_error(std::format("Invalid URL: {}", base_url));
  }
  auto path_start = base_url.find('/', scheme_end + 3);
  if (path_start == std::string::npos) {
    path_start = base_url.size();
  }

  std::string origin = base_url.substr(0, path_start); // https://host
  std::string base_path = (path_start < base_url.size()) ? base_url.substr(path_start) : "/";

  // Use std::filesystem for proper path resolution
  std::filesystem::path base_fs(base_path);
  std::filesystem::path rel_fs(relative_path);

  // Resolve relative to base directory
  std::filesystem::path resolved = (base_fs / rel_fs).lexically_normal();

  auto final_url = origin + resolved.string();
  spdlog::debug("resolve_http_path: final='{}'", final_url);
  return final_url;
}

inline ExprPtr AsyncImportResolver::load_http(const std::string& url,
                                              std::string_view expected_hash) {
  // Check cache first
  if (auto it = cache_.find(url); it != cache_.end()) {
    return it->second;
  }

  // Check if already failed
  if (failed_.count(url)) {
    throw std::runtime_error(std::format("HTTP fetch failed: {}", url));
  }

  // Cycle detection
  if (resolving_.count(url)) {
    throw std::runtime_error(std::format("Import cycle detected: {}", url));
  }
  resolving_.insert(url);

  // Fetch via HTTP
  auto result = http_fetcher_.fetch(url, expected_hash);

  if (!result.success) {
    resolving_.erase(url);
    failed_.insert(url);
    throw std::runtime_error(std::format("HTTP fetch failed: {} - {}", url, result.error));
  }

  // Parse
  Parser parser(result.content, arena_, interner_);
  auto parse_result = parser.parse();

  if (!parse_result) {
    resolving_.erase(url);
    failed_.insert(url);
    throw std::runtime_error(
        std::format("Parse error in {}: {}", url, parse_result.error().message));
  }

  // Determine base URL for relative imports (URL's directory)
  std::string base_url = url.substr(0, url.rfind('/'));

  // Resolve imports recursively
  auto* resolved = resolve_expr(*parse_result, std::filesystem::path(base_url));

  resolving_.erase(url);
  cache_[url] = resolved;
  content_cache_[url] = std::move(result.content);

  return resolved;
}

// ═══════════════════════════════════════════════════════════════════════════════
// WAVE-BASED HTTP RESOLUTION
// ═══════════════════════════════════════════════════════════════════════════════

/// Collect all HTTP import URLs from an expression (without fetching)
inline void AsyncImportResolver::collect_http_imports(ExprPtr expr,
                                                      const std::filesystem::path& base_dir,
                                                      std::vector<std::string>& out_urls) {
  if (!expr)
    return;

  switch (expr->kind) {
    case Expr::Kind::Import: {
      std::string_view path_sv(expr->import.path, expr->import.path_len);
      bool is_http = expr->import.is_http;

      std::string base_dir_str = base_dir.string();
      bool base_is_http =
          base_dir_str.starts_with("https://") || base_dir_str.starts_with("http://");

      std::string key;
      if (is_http) {
        key = std::string(path_sv);
      } else if (base_is_http) {
        key = resolve_http_path(base_dir_str, path_sv);
      } else {
        return; // Local import, not HTTP
      }

      // Skip already cached or failed
      if (cache_.find(key) == cache_.end() && failed_.find(key) == failed_.end()) {
        out_urls.push_back(key);
      }
      break;
    }

    case Expr::Kind::Lam:
      collect_http_imports(expr->lam.type, base_dir, out_urls);
      collect_http_imports(expr->lam.body, base_dir, out_urls);
      break;

    case Expr::Kind::Pi:
      collect_http_imports(expr->pi.domain, base_dir, out_urls);
      collect_http_imports(expr->pi.codomain, base_dir, out_urls);
      break;

    case Expr::Kind::App:
      collect_http_imports(expr->app.func, base_dir, out_urls);
      collect_http_imports(expr->app.arg, base_dir, out_urls);
      break;

    case Expr::Kind::Let:
      if (expr->let.type)
        collect_http_imports(expr->let.type, base_dir, out_urls);
      collect_http_imports(expr->let.value, base_dir, out_urls);
      collect_http_imports(expr->let.body, base_dir, out_urls);
      break;

    case Expr::Kind::BoolAnd:
    case Expr::Kind::BoolOr:
    case Expr::Kind::BoolEq:
    case Expr::Kind::NatPlus:
    case Expr::Kind::NatTimes:
    case Expr::Kind::TextAppend:
    case Expr::Kind::Prefer:
      collect_http_imports(expr->binop.lhs, base_dir, out_urls);
      collect_http_imports(expr->binop.rhs, base_dir, out_urls);
      break;

    case Expr::Kind::BoolIf:
      collect_http_imports(expr->if_.cond, base_dir, out_urls);
      collect_http_imports(expr->if_.then_, base_dir, out_urls);
      collect_http_imports(expr->if_.else_, base_dir, out_urls);
      break;

    case Expr::Kind::List:
      if (expr->list.type)
        collect_http_imports(expr->list.type, base_dir, out_urls);
      for (std::size_t i = 0; i < expr->list.count; ++i) {
        collect_http_imports(expr->list.elems[i], base_dir, out_urls);
      }
      break;

    case Expr::Kind::RecordLit:
    case Expr::Kind::Record:
      for (const auto& entry : *expr->fields) {
        collect_http_imports(entry.value, base_dir, out_urls);
      }
      break;

    case Expr::Kind::Field:
      collect_http_imports(expr->field.record, base_dir, out_urls);
      break;

    case Expr::Kind::Annot:
      collect_http_imports(expr->annot.expr, base_dir, out_urls);
      collect_http_imports(expr->annot.type, base_dir, out_urls);
      break;

    default:
      break;
  }
}

/// Wave-based HTTP resolution: fetch all imports in parallel batches
inline void AsyncImportResolver::resolve_http_waves(const std::string& root_url) {
  spdlog::info("Wave-based HTTP resolution starting from: {}", root_url);

  auto start = std::chrono::high_resolution_clock::now();
  std::size_t wave = 0;
  std::size_t total_fetched = 0;

  // Fetch root
  std::vector<std::string> pending = {root_url};

  while (!pending.empty()) {
    wave++;
    spdlog::debug("Wave {}: {} URLs to fetch", wave, pending.size());

    // Dedupe
    std::sort(pending.begin(), pending.end());
    pending.erase(std::unique(pending.begin(), pending.end()), pending.end());

    // Remove already cached/failed
    std::erase_if(pending, [this](const std::string& url) {
      return cache_.find(url) != cache_.end() || failed_.find(url) != failed_.end();
    });

    if (pending.empty())
      break;

    // Batch fetch
    auto results = http_fetcher_.fetch_batch(pending);
    total_fetched += pending.size();

    // Parse and collect next wave
    std::vector<std::string> next_wave;

    for (std::size_t i = 0; i < results.size(); ++i) {
      const auto& url = pending[i];
      const auto& result = results[i];

      if (!result.success) {
        spdlog::warn("Failed to fetch {}: {}", url, result.error);
        failed_.insert(url);
        continue;
      }

      // Parse
      Parser parser(result.content, arena_, interner_);
      auto parse_result = parser.parse();

      if (!parse_result) {
        spdlog::warn("Parse error in {}: {}", url, parse_result.error().message);
        failed_.insert(url);
        continue;
      }

      // Cache the parsed AST
      cache_[url] = *parse_result;
      content_cache_[url] = result.content;

      // Collect HTTP imports from this file
      std::string base_url = url.substr(0, url.rfind('/'));
      collect_http_imports(*parse_result, std::filesystem::path(base_url), next_wave);
    }

    pending = std::move(next_wave);
  }

  auto end = std::chrono::high_resolution_clock::now();
  auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

  spdlog::info("Wave resolution complete: {} waves, {} files fetched in {} ms", wave, total_fetched,
               duration_ms);
}

/// Wave-based HTTP/2 resolution using evring native HTTP/2 stack
inline void AsyncImportResolver::resolve_http_waves_h2(const std::string& root_url) {
#ifdef ENABLE_HTTP2
  spdlog::info("Wave-based HTTP/2 resolution (evring) starting from: {}", root_url);

  auto start = std::chrono::high_resolution_clock::now();
  std::size_t wave = 0;
  std::size_t total_fetched = 0;

  // Fetch root
  std::vector<std::string> pending = {root_url};

  while (!pending.empty()) {
    wave++;
    spdlog::debug("Wave {}: {} URLs to fetch", wave, pending.size());

    // Dedupe
    std::sort(pending.begin(), pending.end());
    pending.erase(std::unique(pending.begin(), pending.end()), pending.end());

    // Remove already cached/failed
    std::erase_if(pending, [this](const std::string& url) {
      return cache_.find(url) != cache_.end() || failed_.find(url) != failed_.end();
    });

    if (pending.empty())
      break;

    // Batch fetch using HTTP/2
    auto results = http2_fetcher_.fetch_batch(pending);
    total_fetched += pending.size();

    // Parse and collect next wave
    std::vector<std::string> next_wave;

    for (std::size_t i = 0; i < results.size(); ++i) {
      const auto& url = pending[i];
      const auto& result = results[i];

      if (!result.success) {
        spdlog::warn("Failed to fetch {}: {}", url, result.error);
        failed_.insert(url);
        continue;
      }

      // Parse
      Parser parser(result.content, arena_, interner_);
      auto parse_result = parser.parse();

      if (!parse_result) {
        spdlog::warn("Parse error in {}: {}", url, parse_result.error().message);
        failed_.insert(url);
        continue;
      }

      // Cache the parsed AST
      cache_[url] = *parse_result;
      content_cache_[url] = result.content;

      // Collect HTTP imports from this file
      std::string base_url = url.substr(0, url.rfind('/'));
      collect_http_imports(*parse_result, std::filesystem::path(base_url), next_wave);
    }

    pending = std::move(next_wave);
  }

  auto end = std::chrono::high_resolution_clock::now();
  auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

  spdlog::info("HTTP/2 wave resolution complete: {} waves, {} files fetched in {} ms ({} bytes)",
               wave, total_fetched, duration_ms, http2_fetcher_.bytes_fetched());
#else
  spdlog::warn("HTTP/2 not enabled - falling back to curl -Z");
  resolve_http_waves(root_url);
#endif
}

} // namespace continuity::dhall
