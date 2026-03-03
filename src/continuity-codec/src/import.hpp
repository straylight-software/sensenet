// Continuity.Codec.Dhall - Import Resolution
// Content-addressed caching for fast re-evaluation
//
// straylight.software · 2026

#pragma once

#include <filesystem>
#include <format>
#include <fstream>
#include <unordered_map>
#include <unordered_set>

#include "dhall.hpp"
#include "parser.hpp"

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// IMPORT RESOLVER
// ═══════════════════════════════════════════════════════════════════════════════

class ImportResolver {
  Arena& arena_;
  Interner& interner_;

  // Cache: absolute path -> parsed & resolved AST
  std::unordered_map<std::string, ExprPtr> cache_;

  // Currently resolving (for cycle detection)
  std::unordered_set<std::string> resolving_;

public:
  ImportResolver(Arena& arena, Interner& interner) : arena_(arena), interner_(interner) {}

  // Resolve all imports in an expression, returning a fully resolved AST
  ExprPtr resolve(ExprPtr expr, const std::filesystem::path& base_dir);

  // Load and parse a file, resolving its imports
  ExprPtr load_file(const std::filesystem::path& path);

  // Get cache stats
  std::size_t cache_size() const { return cache_.size(); }

private:
  // Read file contents
  std::string read_file(const std::filesystem::path& path);

  // Resolve imports in an expression (recursive)
  ExprPtr resolve_expr(ExprPtr expr, const std::filesystem::path& base_dir);
};

// ═══════════════════════════════════════════════════════════════════════════════
// IMPLEMENTATION
// ═══════════════════════════════════════════════════════════════════════════════

inline std::string ImportResolver::read_file(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::ate | std::ios::binary);
  if (!file) {
    throw std::runtime_error(std::format("Cannot open file: {}", path.string()));
  }
  auto size = file.tellg();
  file.seekg(0);
  std::string content(static_cast<std::size_t>(size), '\0');
  file.read(content.data(), size);
  return content;
}

inline ExprPtr ImportResolver::load_file(const std::filesystem::path& path) {
  auto abs_path = std::filesystem::weakly_canonical(path);
  auto key = abs_path.string();

  // Check cache
  if (auto it = cache_.find(key); it != cache_.end()) {
    return it->second;
  }

  // Cycle detection
  if (resolving_.count(key)) {
    throw std::runtime_error(std::format("Import cycle detected: {}", key));
  }
  resolving_.insert(key);

  // Read and parse
  std::string source = read_file(abs_path);
  Parser parser(source, arena_, interner_);
  auto result = parser.parse();

  if (!result) {
    resolving_.erase(key);
    const auto& err = result.error();
    throw std::runtime_error(
        std::format("Parse error in {}:{}:{}: {}", key, err.line, err.col, err.message));
  }

  // Resolve imports in the parsed expression
  auto* resolved = resolve_expr(*result, abs_path.parent_path());

  resolving_.erase(key);
  cache_[key] = resolved;

  return resolved;
}

inline ExprPtr ImportResolver::resolve(ExprPtr expr, const std::filesystem::path& base_dir) {
  return resolve_expr(expr, base_dir);
}

inline ExprPtr ImportResolver::resolve_expr(ExprPtr expr, const std::filesystem::path& base_dir) {
  if (!expr)
    return nullptr;

  switch (expr->kind) {
    case Expr::Kind::Var: {
      // Check if this is actually an import placeholder
      // (Variables with idx=0 and no binding might be imports)
      // For now, just return as-is
      return expr;
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

      // Check if value is an import (variable placeholder from parser)
      // This is a simplified check - real implementation would track import paths

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

    case Expr::Kind::Import: {
      // Resolve the import path relative to base_dir
      std::string_view path_sv(expr->import.path, expr->import.path_len);
      std::filesystem::path import_path(path_sv);

      // Handle relative paths (./foo.dhall, ../foo.dhall)
      std::filesystem::path resolved_path;
      if (import_path.is_relative()) {
        resolved_path = base_dir / import_path;
      } else {
        resolved_path = import_path;
      }

      // Load and resolve the imported file
      return load_file(resolved_path);
    }

    default:
      return expr;
  }
}

} // namespace continuity::dhall
