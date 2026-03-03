// Continuity.Codec.Dhall - C++23 NbE Evaluator
// Generated from Lean4 specification via Pretty.lean
// Target: <10ms for sensenet's 12K LOC configs
//
// straylight.software · 2026

#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include <absl/container/flat_hash_map.h>

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// ARENA ALLOCATOR
// ═══════════════════════════════════════════════════════════════════════════════

class Arena {
  struct Block {
    static constexpr std::size_t SIZE = 1024 * 1024; // 1MB
    alignas(64) std::byte data[SIZE];
    std::size_t used = 0;
  };

  std::vector<std::unique_ptr<Block>> blocks_;
  Block* current_ = nullptr;

public:
  Arena() {
    blocks_.push_back(std::make_unique<Block>());
    current_ = blocks_.back().get();
  }

  template <typename T, typename... Args>
  T* alloc(Args&&... args) {
    constexpr std::size_t align = alignof(T);
    constexpr std::size_t size = sizeof(T);

    std::size_t offset = (current_->used + align - 1) & ~(align - 1);
    if (offset + size > Block::SIZE) {
      blocks_.push_back(std::make_unique<Block>());
      current_ = blocks_.back().get();
      offset = 0;
    }

    void* ptr = current_->data + offset;
    current_->used = offset + size;
    return new (ptr) T(std::forward<Args>(args)...);
  }

  template <typename T>
  std::span<T> alloc_array(std::size_t n) {
    constexpr std::size_t align = alignof(T);
    std::size_t size = sizeof(T) * n;

    std::size_t offset = (current_->used + align - 1) & ~(align - 1);
    if (offset + size > Block::SIZE) {
      blocks_.push_back(std::make_unique<Block>());
      current_ = blocks_.back().get();
      offset = 0;
    }

    T* ptr = reinterpret_cast<T*>(current_->data + offset);
    current_->used = offset + size;
    for (std::size_t i = 0; i < n; ++i)
      new (ptr + i) T();
    return {ptr, n};
  }

  void reset() {
    for (auto& b : blocks_)
      b->used = 0;
    current_ = blocks_.front().get();
  }
};

// ═══════════════════════════════════════════════════════════════════════════════
// INTERNED NAMES
// ═══════════════════════════════════════════════════════════════════════════════

struct Name {
  std::uint32_t id;
  std::uint32_t hash;

  bool operator==(const Name& o) const { return id == o.id; }
  bool operator<(const Name& o) const { return id < o.id; }
};

class Interner {
  // flat_hash_map with heterogeneous lookup for string_view queries
  absl::flat_hash_map<std::string, std::uint32_t> lookup_;
  std::vector<std::string_view> by_id_; // points into lookup_ keys (stable after insert)

public:
  Name intern(std::string_view s) {
    if (auto it = lookup_.find(s); it != lookup_.end()) {
      return {it->second, hash(s)};
    }
    std::uint32_t id = static_cast<std::uint32_t>(by_id_.size());
    auto [it, _] = lookup_.emplace(std::string(s), id);
    by_id_.push_back(it->first); // string_view into map's key (stable)
    return {id, hash(s)};
  }

  std::string_view get(Name n) const { return by_id_[n.id]; }

private:
  static std::uint32_t hash(std::string_view s) {
    std::uint32_t h = 0x811c9dc5;
    for (char c : s)
      h = (h ^ static_cast<std::uint8_t>(c)) * 0x01000193;
    return h;
  }
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONSTANTS & BUILTINS
// ═══════════════════════════════════════════════════════════════════════════════

enum class Const : std::uint8_t { Type, Kind, Sort };

enum class Builtin : std::uint8_t {
  Natural,
  NaturalFold,
  NaturalBuild,
  NaturalIsZero,
  NaturalEven,
  NaturalOdd,
  NaturalToInteger,
  NaturalShow,
  NaturalSubtract,
  Integer,
  IntegerClamp,
  IntegerNegate,
  IntegerShow,
  IntegerToDouble,
  Double,
  DoubleShow,
  Text,
  TextShow,
  TextReplace,
  List,
  ListBuild,
  ListFold,
  ListLength,
  ListHead,
  ListLast,
  ListIndexed,
  ListReverse,
  Optional,
  None,
  Some,
  Bool,
};

// ═══════════════════════════════════════════════════════════════════════════════
// LITERALS
// ═══════════════════════════════════════════════════════════════════════════════

struct Lit {
  enum class Kind : std::uint8_t { Bool, Nat, Int, Double, Text };
  Kind kind;
  union {
    bool b;
    std::uint64_t n;
    std::int64_t i;
    double d;
    struct {
      const char* data;
      std::size_t len;
    } text;
  };

  static Lit Bool(bool v) {
    Lit l;
    l.kind = Kind::Bool;
    l.b = v;
    return l;
  }
  static Lit Nat(std::uint64_t v) {
    Lit l;
    l.kind = Kind::Nat;
    l.n = v;
    return l;
  }
  static Lit Int(std::int64_t v) {
    Lit l;
    l.kind = Kind::Int;
    l.i = v;
    return l;
  }
  static Lit Double(double v) {
    Lit l;
    l.kind = Kind::Double;
    l.d = v;
    return l;
  }
  static Lit Text(const char* s, std::size_t len) {
    Lit l;
    l.kind = Kind::Text;
    l.text = {s, len};
    return l;
  }
};
// ═══════════════════════════════════════════════════════════════════════════════
// FIELDS (flat_hash_map for O(1) lookup, cache-friendly iteration)
// ═══════════════════════════════════════════════════════════════════════════════

template <typename T>
class Fields {
public:
  struct Entry {
    Name name;
    T value;
  };

private:
  // flat_hash_map: open addressing, cache-friendly, ~2x faster than std::unordered_map
  absl::flat_hash_map<std::uint32_t, Entry> map_;

public:
  Fields() = default;

  void reserve(std::size_t n) { map_.reserve(n); }

  void insert(Name n, T v) { map_.insert_or_assign(n.id, Entry{n, std::move(v)}); }

  // For bulk loading when we know keys are unique
  void push_back_unchecked(Name n, T v) { map_.emplace(n.id, Entry{n, std::move(v)}); }

  T* lookup(Name n) {
    auto it = map_.find(n.id);
    return it != map_.end() ? &it->second.value : nullptr;
  }

  const T* lookup(Name n) const {
    auto it = map_.find(n.id);
    return it != map_.end() ? &it->second.value : nullptr;
  }

  std::size_t size() const { return map_.size(); }

  // Iterator that exposes Entry references
  struct Iterator {
    using inner_t = typename absl::flat_hash_map<std::uint32_t, Entry>::const_iterator;
    inner_t it;
    const Entry& operator*() const { return it->second; }
    Iterator& operator++() {
      ++it;
      return *this;
    }
    bool operator!=(const Iterator& o) const { return it != o.it; }
  };
  Iterator begin() const { return {map_.begin()}; }
  Iterator end() const { return {map_.end()}; }

  // O(m) right-biased merge when a can be moved, O(n+m) otherwise
  // Takes a by value to enable move semantics
  static Fields merge_prefer(Fields a, const Fields& b) {
    a.map_.reserve(a.size() + b.size());
    for (const auto& [id, entry] : b.map_) {
      a.map_.insert_or_assign(id, entry); // b overwrites
    }
    return a; // NRVO or move
  }
};

// ═══════════════════════════════════════════════════════════════════════════════
// EXPRESSION AST
// ═══════════════════════════════════════════════════════════════════════════════

struct Expr;
using ExprPtr = Expr*;

struct Expr {
  enum class Kind : std::uint8_t {
    Const,
    Var,
    Builtin,
    Lam,
    Pi,
    App,
    Let,
    Lit,
    BoolAnd,
    BoolOr,
    BoolEq, // == (equality comparison)
    BoolIf,
    NatPlus,
    NatTimes,
    TextAppend, // ++ operator for text concatenation
    List,
    RecordLit,
    Record,
    Field,
    Prefer,
    Annot,
    Import, // Local file import (./path.dhall, ../path.dhall)
  };

  Kind kind;

  union {
    Const const_val;
    std::uint32_t var_idx;
    Builtin builtin;
    Lit lit;
    struct {
      Name name;
      ExprPtr type;
      ExprPtr body;
    } lam;
    struct {
      Name name;
      ExprPtr domain;
      ExprPtr codomain;
    } pi;
    struct {
      ExprPtr func;
      ExprPtr arg;
    } app;
    struct {
      Name name;
      ExprPtr type;
      ExprPtr value;
      ExprPtr body;
    } let;
    struct {
      ExprPtr lhs;
      ExprPtr rhs;
    } binop;
    struct {
      ExprPtr cond;
      ExprPtr then_;
      ExprPtr else_;
    } if_;
    struct {
      ExprPtr type;
      ExprPtr* elems;
      std::size_t count;
    } list;
    Fields<ExprPtr>* fields;
    struct {
      ExprPtr record;
      Name name;
    } field;
    struct {
      ExprPtr expr;
      ExprPtr type;
    } annot;
    struct {
      const char* path; // Original path string (arena-allocated)
      std::size_t path_len;
      const char* abs_path; // Resolved absolute path (set during import resolution)
      std::size_t abs_path_len;
      const char* hash;     // SHA256 hash (optional, for integrity checking)
      std::size_t hash_len; // 64 hex chars for sha256 (0 if no hash)
      bool is_http;         // true for https:// URLs
    } import;
  };
};

// ═══════════════════════════════════════════════════════════════════════════════
// VALUES (WHNF)
// ═══════════════════════════════════════════════════════════════════════════════

struct Value;
using ValuePtr = Value*;

struct Env {
  std::vector<ValuePtr> values;

  Env extend(ValuePtr v) const {
    Env e = *this;
    e.values.push_back(v);
    return e;
  }

  ValuePtr lookup(std::uint32_t idx) const {
    if (idx >= values.size())
      return nullptr;
    return values[values.size() - 1 - idx];
  }

  std::size_t size() const { return values.size(); }
};

struct Closure {
  Name name;
  Env env;
  ExprPtr body;
};

struct Value {
  enum class Kind : std::uint8_t {
    Const,
    Var,
    Lam,
    Pi,
    App,
    Builtin,
    Lit,
    List,
    RecordLit,
    Record,
    Field,
    Prefer,
  };

  Kind kind;

  union {
    Const const_val;
    std::int32_t var_level; // de Bruijn level
    Closure* closure;
    struct {
      ValuePtr domain;
      Closure* codomain;
    } pi;
    struct {
      ValuePtr func;
      ValuePtr arg;
    } app;
    struct {
      Builtin b;
      std::vector<ValuePtr>* args;
    } builtin;
    Lit lit;
    struct {
      ValuePtr type;
      std::vector<ValuePtr>* elems;
    } list;
    Fields<ValuePtr>* fields;
    struct {
      ValuePtr record;
      Name name;
    } field;
    struct {
      ValuePtr lhs;
      ValuePtr rhs;
    } prefer;
  };
};

// ═══════════════════════════════════════════════════════════════════════════════
// EVALUATOR
// ═══════════════════════════════════════════════════════════════════════════════

// Forward declare import callback type
class Evaluator;
using ImportCallback = std::function<ValuePtr(Evaluator&, std::string_view abs_path)>;

class Evaluator {
  Arena& arena_;
  Interner& interner_;
  ImportCallback import_cb_;

public:
  Evaluator(Arena& arena, Interner& interner) : arena_(arena), interner_(interner) {}

  /// Set import callback for value caching
  void set_import_callback(ImportCallback cb) { import_cb_ = std::move(cb); }

  ValuePtr eval(const Env& env, ExprPtr e);
  ExprPtr quote(int level, ValuePtr v);
  ExprPtr normalize(ExprPtr e) { return quote(0, eval({}, e)); }

private:
  ValuePtr apply(ValuePtr f, ValuePtr x);
  ValuePtr evalField(ValuePtr r, Name n);
  ValuePtr evalPrefer(ValuePtr a, ValuePtr b);
  ValuePtr tryBuiltin(Builtin b, std::span<ValuePtr> args);

  // Allocation helpers
  template <typename T, typename... Args>
  T* alloc(Args&&... args) {
    return arena_.alloc<T>(std::forward<Args>(args)...);
  }

  ValuePtr mkConst(Const c) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Const;
    v->const_val = c;
    return v;
  }
  ValuePtr mkVar(int level) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Var;
    v->var_level = level;
    return v;
  }
  ValuePtr mkLit(Lit l) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Lit;
    v->lit = l;
    return v;
  }
  ValuePtr mkLam(Closure* c) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Lam;
    v->closure = c;
    return v;
  }
  ValuePtr mkApp(ValuePtr f, ValuePtr x) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::App;
    v->app = {f, x};
    return v;
  }
  ValuePtr mkBuiltin(Builtin b, std::vector<ValuePtr>* args) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Builtin;
    v->builtin = {b, args};
    return v;
  }
  ValuePtr mkRecordLit(Fields<ValuePtr>* fs) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::RecordLit;
    v->fields = fs;
    return v;
  }
  ValuePtr mkField(ValuePtr r, Name n) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Field;
    v->field = {r, n};
    return v;
  }
  ValuePtr mkPrefer(ValuePtr a, ValuePtr b) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::Prefer;
    v->prefer = {a, b};
    return v;
  }
  ValuePtr mkList(ValuePtr t, std::vector<ValuePtr>* es) {
    auto* v = alloc<Value>();
    v->kind = Value::Kind::List;
    v->list = {t, es};
    return v;
  }

  ExprPtr mkExprConst(Const c) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Const;
    e->const_val = c;
    return e;
  }
  ExprPtr mkExprVar(std::uint32_t i) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Var;
    e->var_idx = i;
    return e;
  }
  ExprPtr mkExprLit(Lit l) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Lit;
    e->lit = l;
    return e;
  }
  ExprPtr mkExprBuiltin(Builtin b) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Builtin;
    e->builtin = b;
    return e;
  }
  ExprPtr mkExprApp(ExprPtr f, ExprPtr x) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::App;
    e->app = {f, x};
    return e;
  }
  ExprPtr mkExprLam(Name n, ExprPtr t, ExprPtr b) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Lam;
    e->lam = {n, t, b};
    return e;
  }
  ExprPtr mkExprRecordLit(Fields<ExprPtr>* fs) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::RecordLit;
    e->fields = fs;
    return e;
  }
  ExprPtr mkExprField(ExprPtr r, Name n) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Field;
    e->field = {r, n};
    return e;
  }
  ExprPtr mkExprPrefer(ExprPtr a, ExprPtr b) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::Prefer;
    e->binop = {a, b};
    return e;
  }
  ExprPtr mkExprList(ExprPtr t, ExprPtr* es, std::size_t n) {
    auto* e = alloc<Expr>();
    e->kind = Expr::Kind::List;
    e->list = {t, es, n};
    return e;
  }
};

// ═══════════════════════════════════════════════════════════════════════════════
// INLINE IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════════

inline ValuePtr Evaluator::eval(const Env& env, ExprPtr e) {
  switch (e->kind) {
    case Expr::Kind::Const:
      return mkConst(e->const_val);

    case Expr::Kind::Var:
      if (auto* v = env.lookup(e->var_idx))
        return v;
      return mkVar(static_cast<int>(env.size()) - 1 - static_cast<int>(e->var_idx));

    case Expr::Kind::Builtin:
      return mkBuiltin(e->builtin, alloc<std::vector<ValuePtr>>());

    case Expr::Kind::Lam: {
      auto* c = alloc<Closure>();
      c->name = e->lam.name;
      c->env = env;
      c->body = e->lam.body;
      return mkLam(c);
    }

    case Expr::Kind::Pi: {
      auto* dom = eval(env, e->pi.domain);
      auto* c = alloc<Closure>();
      c->name = e->pi.name;
      c->env = env;
      c->body = e->pi.codomain;
      auto* v = alloc<Value>();
      v->kind = Value::Kind::Pi;
      v->pi = {dom, c};
      return v;
    }

    case Expr::Kind::App: {
      auto* f = eval(env, e->app.func);
      auto* x = eval(env, e->app.arg);
      return apply(f, x);
    }

    case Expr::Kind::Let: {
      auto* v = eval(env, e->let.value);
      return eval(env.extend(v), e->let.body);
    }

    case Expr::Kind::Lit:
      return mkLit(e->lit);

    case Expr::Kind::BoolAnd: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Bool && !a->lit.b)
        return a;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Bool && !b->lit.b)
        return b;
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Bool && a->lit.b)
        return b;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Bool && b->lit.b)
        return a;
      return mkApp(mkApp(mkBuiltin(Builtin::Bool, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::BoolOr: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Bool && a->lit.b)
        return a;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Bool && b->lit.b)
        return b;
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Bool && !a->lit.b)
        return b;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Bool && !b->lit.b)
        return a;
      return mkApp(mkApp(mkBuiltin(Builtin::Bool, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::BoolEq: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      // Bool equality
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Bool &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Bool) {
        return mkLit(Lit::Bool(a->lit.b == b->lit.b));
      }
      // Natural equality
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Nat &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Nat) {
        return mkLit(Lit::Bool(a->lit.n == b->lit.n));
      }
      // Integer equality
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Int &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Int) {
        return mkLit(Lit::Bool(a->lit.i == b->lit.i));
      }
      // Double equality (note: Dhall uses bitwise equality for doubles)
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Double &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Double) {
        return mkLit(Lit::Bool(a->lit.d == b->lit.d));
      }
      // Text equality
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Text &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Text) {
        bool eq = (a->lit.text.len == b->lit.text.len) &&
                  (std::memcmp(a->lit.text.data, b->lit.text.data, a->lit.text.len) == 0);
        return mkLit(Lit::Bool(eq));
      }
      // Otherwise stuck
      return mkApp(mkApp(mkBuiltin(Builtin::Bool, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::BoolIf: {
      auto* c = eval(env, e->if_.cond);
      if (c->kind == Value::Kind::Lit && c->lit.kind == Lit::Kind::Bool) {
        return eval(env, c->lit.b ? e->if_.then_ : e->if_.else_);
      }
      auto* t = eval(env, e->if_.then_);
      auto* f = eval(env, e->if_.else_);
      return mkApp(mkApp(mkApp(mkBuiltin(Builtin::Bool, alloc<std::vector<ValuePtr>>()), c), t), f);
    }

    case Expr::Kind::NatPlus: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Nat && a->lit.n == 0)
        return b;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Nat && b->lit.n == 0)
        return a;
      if (a->kind == Value::Kind::Lit && b->kind == Value::Kind::Lit &&
          a->lit.kind == Lit::Kind::Nat && b->lit.kind == Lit::Kind::Nat) {
        return mkLit(Lit::Nat(a->lit.n + b->lit.n));
      }
      return mkApp(mkApp(mkBuiltin(Builtin::Natural, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::NatTimes: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Nat && a->lit.n == 0)
        return a;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Nat && b->lit.n == 0)
        return b;
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Nat && a->lit.n == 1)
        return b;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Nat && b->lit.n == 1)
        return a;
      if (a->kind == Value::Kind::Lit && b->kind == Value::Kind::Lit &&
          a->lit.kind == Lit::Kind::Nat && b->lit.kind == Lit::Kind::Nat) {
        return mkLit(Lit::Nat(a->lit.n * b->lit.n));
      }
      return mkApp(mkApp(mkBuiltin(Builtin::Natural, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::TextAppend: {
      auto* a = eval(env, e->binop.lhs);
      auto* b = eval(env, e->binop.rhs);
      // If both are text literals, concatenate them
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Text &&
          b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Text) {
        // Concatenate the strings
        std::size_t len_a = a->lit.text.len;
        std::size_t len_b = b->lit.text.len;
        char* data = reinterpret_cast<char*>(arena_.alloc_array<char>(len_a + len_b + 1).data());
        std::copy(a->lit.text.data, a->lit.text.data + len_a, data);
        std::copy(b->lit.text.data, b->lit.text.data + len_b, data + len_a);
        data[len_a + len_b] = '\0';
        return mkLit(Lit::Text(data, len_a + len_b));
      }
      // If either is empty string, return the other
      if (a->kind == Value::Kind::Lit && a->lit.kind == Lit::Kind::Text && a->lit.text.len == 0)
        return b;
      if (b->kind == Value::Kind::Lit && b->lit.kind == Lit::Kind::Text && b->lit.text.len == 0)
        return a;
      // Otherwise create a stuck TextAppend application
      return mkApp(mkApp(mkBuiltin(Builtin::Text, alloc<std::vector<ValuePtr>>()), a), b);
    }

    case Expr::Kind::List: {
      ValuePtr t = e->list.type ? eval(env, e->list.type) : nullptr;
      auto* es = alloc<std::vector<ValuePtr>>();
      es->reserve(e->list.count);
      for (std::size_t i = 0; i < e->list.count; ++i) {
        es->push_back(eval(env, e->list.elems[i]));
      }
      return mkList(t, es);
    }

    case Expr::Kind::RecordLit: {
      auto* fs = alloc<Fields<ValuePtr>>();
      fs->reserve(e->fields->size());
      for (const auto& entry : *e->fields) {
        fs->push_back_unchecked(entry.name, eval(env, entry.value));
      }
      return mkRecordLit(fs);
    }

    case Expr::Kind::Record: {
      auto* fs = alloc<Fields<ValuePtr>>();
      fs->reserve(e->fields->size());
      for (const auto& entry : *e->fields) {
        fs->push_back_unchecked(entry.name, eval(env, entry.value));
      }
      auto* v = alloc<Value>();
      v->kind = Value::Kind::Record;
      v->fields = fs;
      return v;
    }

    case Expr::Kind::Field:
      return evalField(eval(env, e->field.record), e->field.name);

    case Expr::Kind::Prefer:
      return evalPrefer(eval(env, e->binop.lhs), eval(env, e->binop.rhs));

    case Expr::Kind::Annot:
      return eval(env, e->annot.expr);

    case Expr::Kind::Import: {
      // Import nodes should have abs_path set by import resolver
      if (!e->import.abs_path || !import_cb_) {
        throw std::runtime_error("Import not resolved or no import callback set");
      }
      std::string_view abs_path(e->import.abs_path, e->import.abs_path_len);
      return import_cb_(*this, abs_path);
    }
  }

  return mkConst(Const::Type); // unreachable
}

inline ValuePtr Evaluator::apply(ValuePtr f, ValuePtr x) {
  if (f->kind == Value::Kind::Lam) {
    return eval(f->closure->env.extend(x), f->closure->body);
  }
  if (f->kind == Value::Kind::Builtin) {
    auto* args = alloc<std::vector<ValuePtr>>(*f->builtin.args);
    args->push_back(x);
    return tryBuiltin(f->builtin.b, *args);
  }
  return mkApp(f, x);
}

inline ValuePtr Evaluator::evalField(ValuePtr r, Name n) {
  if (r->kind == Value::Kind::RecordLit) {
    if (auto* v = r->fields->lookup(n))
      return *v;
  }
  return mkField(r, n);
}

inline ValuePtr Evaluator::evalPrefer(ValuePtr a, ValuePtr b) {
  if (a->kind == Value::Kind::RecordLit && b->kind == Value::Kind::RecordLit) {
    auto merged = Fields<ValuePtr>::merge_prefer(std::move(*a->fields), *b->fields);
    auto* fs = alloc<Fields<ValuePtr>>(std::move(merged));
    return mkRecordLit(fs);
  }
  return mkPrefer(a, b);
}

inline ValuePtr Evaluator::tryBuiltin(Builtin b, std::span<ValuePtr> args) {
  switch (b) {
    case Builtin::NaturalIsZero:
      if (args.size() == 1 && args[0]->kind == Value::Kind::Lit &&
          args[0]->lit.kind == Lit::Kind::Nat) {
        return mkLit(Lit::Bool(args[0]->lit.n == 0));
      }
      break;
    case Builtin::ListLength:
      if (args.size() == 2 && args[1]->kind == Value::Kind::List) {
        return mkLit(Lit::Nat(args[1]->list.elems->size()));
      }
      break;
    case Builtin::ListReverse:
      if (args.size() == 2 && args[1]->kind == Value::Kind::List) {
        auto* es = alloc<std::vector<ValuePtr>>(*args[1]->list.elems);
        std::reverse(es->begin(), es->end());
        return mkList(args[1]->list.type, es);
      }
      break;
    case Builtin::ListHead:
      if (args.size() == 2 && args[1]->kind == Value::Kind::List) {
        if (args[1]->list.elems->empty()) {
          return apply(mkBuiltin(Builtin::None, alloc<std::vector<ValuePtr>>()), args[0]);
        }
        return apply(mkBuiltin(Builtin::Some, alloc<std::vector<ValuePtr>>()),
                     args[1]->list.elems->front());
      }
      break;
    default:
      break;
  }
  auto* v = alloc<std::vector<ValuePtr>>(args.begin(), args.end());
  return mkBuiltin(b, v);
}

inline ExprPtr Evaluator::quote(int level, ValuePtr v) {
  switch (v->kind) {
    case Value::Kind::Const:
      return mkExprConst(v->const_val);

    case Value::Kind::Var:
      return mkExprVar(static_cast<std::uint32_t>(level - v->var_level - 1));

    case Value::Kind::Lam: {
      auto* fresh = mkVar(level);
      auto body = eval(v->closure->env.extend(fresh), v->closure->body);
      return mkExprLam(v->closure->name, mkExprConst(Const::Type), quote(level + 1, body));
    }

    case Value::Kind::Pi: {
      auto* fresh = mkVar(level);
      auto cod = eval(v->pi.codomain->env.extend(fresh), v->pi.codomain->body);
      auto* e = alloc<Expr>();
      e->kind = Expr::Kind::Pi;
      e->pi = {v->pi.codomain->name, quote(level, v->pi.domain), quote(level + 1, cod)};
      return e;
    }

    case Value::Kind::App:
      return mkExprApp(quote(level, v->app.func), quote(level, v->app.arg));

    case Value::Kind::Builtin:
      if (v->builtin.args->empty()) {
        return mkExprBuiltin(v->builtin.b);
      } else {
        ExprPtr e = mkExprBuiltin(v->builtin.b);
        for (auto* arg : *v->builtin.args) {
          e = mkExprApp(e, quote(level, arg));
        }
        return e;
      }

    case Value::Kind::Lit:
      return mkExprLit(v->lit);

    case Value::Kind::List: {
      auto span = arena_.alloc_array<ExprPtr>(v->list.elems->size());
      for (std::size_t i = 0; i < v->list.elems->size(); ++i) {
        span[i] = quote(level, (*v->list.elems)[i]);
      }
      return mkExprList(v->list.type ? quote(level, v->list.type) : nullptr, span.data(),
                        span.size());
    }

    case Value::Kind::RecordLit: {
      auto* fs = alloc<Fields<ExprPtr>>();
      fs->reserve(v->fields->size());
      for (const auto& entry : *v->fields) {
        fs->push_back_unchecked(entry.name, quote(level, entry.value));
      }
      return mkExprRecordLit(fs);
    }

    case Value::Kind::Record: {
      auto* fs = alloc<Fields<ExprPtr>>();
      fs->reserve(v->fields->size());
      for (const auto& entry : *v->fields) {
        fs->push_back_unchecked(entry.name, quote(level, entry.value));
      }
      auto* e = alloc<Expr>();
      e->kind = Expr::Kind::Record;
      e->fields = fs;
      return e;
    }

    case Value::Kind::Field:
      return mkExprField(quote(level, v->field.record), v->field.name);

    case Value::Kind::Prefer:
      return mkExprPrefer(quote(level, v->prefer.lhs), quote(level, v->prefer.rhs));
  }

  return mkExprConst(Const::Type);
}

} // namespace continuity::dhall
