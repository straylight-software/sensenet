// Continuity.Codec.Dhall - Parser
// LL(k) with precedence climbing
// Target: <2ms for sensenet's 12K LOC
//
// straylight.software · 2026

#pragma once

#include <expected>
#include <string>
#include <string_view>

#include "dhall.hpp"
#include "lexer.hpp"

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// PARSE ERROR
// ═══════════════════════════════════════════════════════════════════════════════

struct ParseError {
  std::string message;
  std::uint32_t offset;
  std::uint32_t line;
  std::uint32_t col;
};

// ═══════════════════════════════════════════════════════════════════════════════
// PARSER
// ═══════════════════════════════════════════════════════════════════════════════

class Parser {
  Lexer lexer_;
  std::string_view src_;
  Arena& arena_;
  Interner& interner_;

  Token current_;
  Token lookahead_[3]; // LL(4)
  int la_count_ = 0;

public:
  Parser(std::string_view source, Arena& arena, Interner& interner)
      : lexer_(source), src_(source), arena_(arena), interner_(interner) {
    advance(); // Load first token
  }

  std::expected<ExprPtr, ParseError> parse();

private:
  // Token management
  void advance();
  Token peek(int n = 0);
  bool match(TokenKind k);
  bool check(TokenKind k);
  std::expected<void, ParseError> expect(TokenKind k, const char* msg);

  // Error helper
  ParseError error(const char* msg);

  // Expression parsers (precedence climbing)
  ExprPtr parse_expression();
  ExprPtr parse_annotated();
  ExprPtr parse_operator(int min_prec);
  ExprPtr parse_application();
  ExprPtr parse_import();
  ExprPtr parse_selector();
  ExprPtr parse_primitive();

  // Specific constructs
  ExprPtr parse_lambda();
  ExprPtr parse_forall();
  ExprPtr parse_if();
  ExprPtr parse_let();
  ExprPtr parse_merge();
  ExprPtr parse_assert();
  ExprPtr parse_record();
  ExprPtr parse_union();
  ExprPtr parse_list();
  ExprPtr parse_text();

  // Operator precedence
  static int get_precedence(TokenKind k);
  static bool is_right_assoc(TokenKind k);

  // Allocation helpers
  template <typename T, typename... Args>
  T* alloc(Args&&... args) {
    return arena_.alloc<T>(std::forward<Args>(args)...);
  }

  ExprPtr mkConst(Const c);
  ExprPtr mkVar(std::uint32_t idx);
  ExprPtr mkBuiltin(Builtin b);
  ExprPtr mkLit(Lit l);
  ExprPtr mkLam(Name n, ExprPtr type, ExprPtr body);
  ExprPtr mkPi(Name n, ExprPtr domain, ExprPtr codomain);
  ExprPtr mkApp(ExprPtr f, ExprPtr x);
  ExprPtr mkLet(Name n, ExprPtr type, ExprPtr value, ExprPtr body);
  ExprPtr mkBinop(Expr::Kind kind, ExprPtr lhs, ExprPtr rhs);
  ExprPtr mkIf(ExprPtr cond, ExprPtr then_, ExprPtr else_);
  ExprPtr mkList(ExprPtr type, std::vector<ExprPtr>& elems);
  ExprPtr mkRecordLit(Fields<ExprPtr>* fields);
  ExprPtr mkRecord(Fields<ExprPtr>* fields);
  ExprPtr mkField(ExprPtr record, Name name);
  ExprPtr mkAnnot(ExprPtr expr, ExprPtr type);
  ExprPtr mkImport(std::string_view path, std::string_view hash = {}, bool is_http = false);
};

// ═══════════════════════════════════════════════════════════════════════════════
// INLINE IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════════

inline void Parser::advance() {
  if (la_count_ > 0) {
    current_ = lookahead_[0];
    for (int i = 0; i < la_count_ - 1; ++i) {
      lookahead_[i] = lookahead_[i + 1];
    }
    --la_count_;
  } else {
    current_ = lexer_.next();
  }
}

inline Token Parser::peek(int n) {
  if (n == 0)
    return current_;

  // Fill lookahead buffer as needed
  while (la_count_ < n) {
    lookahead_[la_count_++] = lexer_.next();
  }
  return lookahead_[n - 1];
}

inline bool Parser::match(TokenKind k) {
  if (current_.kind == k) {
    advance();
    return true;
  }
  return false;
}

inline bool Parser::check(TokenKind k) {
  return current_.kind == k;
}

inline std::expected<void, ParseError> Parser::expect(TokenKind k, const char* msg) {
  if (!match(k)) {
    return std::unexpected(error(msg));
  }
  return {};
}

inline ParseError Parser::error(const char* msg) {
  return {msg, current_.offset, lexer_.line(), lexer_.col()};
}

// Operator precedence (higher = tighter binding)
// Based on Dhall spec
inline int Parser::get_precedence(TokenKind k) {
  switch (k) {
    case TokenKind::Arrow:
      return 1; // -> (function type, right-assoc)
    case TokenKind::Equivalent:
      return 2; // ===
    case TokenKind::Alternative:
      return 3; // Import fallback ?
    case TokenKind::Or:
      return 4; // ||
    case TokenKind::Plus:
      return 5; // +
    case TokenKind::TextAppend:
      return 6; // ++
    case TokenKind::ListAppend:
      return 7; // #
    case TokenKind::And:
      return 8; // &&
    case TokenKind::Combine:
      return 9; // /backslash
    case TokenKind::Prefer:
      return 10; // //
    case TokenKind::CombineTypes:
      return 11; // //backslash backslash
    case TokenKind::Times:
      return 12; // *
    case TokenKind::NotEqual:
      return 13; // !=
    case TokenKind::DoubleEqual:
      return 13; // == (equality comparison, same precedence as !=)
    // NOTE: Equal (=) is NOT an operator - it's syntax for assignment
    default:
      return 0; // Not an operator
  }
}

inline bool Parser::is_right_assoc(TokenKind k) {
  // In Dhall, most operators are right-associative
  switch (k) {
    case TokenKind::Arrow: // -> is right-assoc
    case TokenKind::Alternative:
      return true;
    default:
      return false;
  }
}

inline ExprPtr Parser::mkConst(Const c) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Const;
  e->const_val = c;
  return e;
}

inline ExprPtr Parser::mkVar(std::uint32_t idx) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Var;
  e->var_idx = idx;
  return e;
}

inline ExprPtr Parser::mkBuiltin(Builtin b) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Builtin;
  e->builtin = b;
  return e;
}

inline ExprPtr Parser::mkLit(Lit l) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Lit;
  e->lit = l;
  return e;
}

inline ExprPtr Parser::mkLam(Name n, ExprPtr type, ExprPtr body) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Lam;
  e->lam = {n, type, body};
  return e;
}

inline ExprPtr Parser::mkPi(Name n, ExprPtr domain, ExprPtr codomain) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Pi;
  e->pi = {n, domain, codomain};
  return e;
}

inline ExprPtr Parser::mkApp(ExprPtr f, ExprPtr x) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::App;
  e->app = {f, x};
  return e;
}

inline ExprPtr Parser::mkLet(Name n, ExprPtr type, ExprPtr value, ExprPtr body) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Let;
  e->let = {n, type, value, body};
  return e;
}

inline ExprPtr Parser::mkBinop(Expr::Kind kind, ExprPtr lhs, ExprPtr rhs) {
  auto* e = alloc<Expr>();
  e->kind = kind;
  e->binop = {lhs, rhs};
  return e;
}

inline ExprPtr Parser::mkIf(ExprPtr cond, ExprPtr then_, ExprPtr else_) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::BoolIf;
  e->if_ = {cond, then_, else_};
  return e;
}

inline ExprPtr Parser::mkList(ExprPtr type, std::vector<ExprPtr>& elems) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::List;
  auto span = arena_.alloc_array<ExprPtr>(elems.size());
  for (std::size_t i = 0; i < elems.size(); ++i) {
    span[i] = elems[i];
  }
  e->list = {type, span.data(), span.size()};
  return e;
}

inline ExprPtr Parser::mkRecordLit(Fields<ExprPtr>* fields) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::RecordLit;
  e->fields = fields;
  return e;
}

inline ExprPtr Parser::mkRecord(Fields<ExprPtr>* fields) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Record;
  e->fields = fields;
  return e;
}

inline ExprPtr Parser::mkField(ExprPtr record, Name name) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Field;
  e->field = {record, name};
  return e;
}

inline ExprPtr Parser::mkAnnot(ExprPtr expr, ExprPtr type) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Annot;
  e->annot = {expr, type};
  return e;
}

inline ExprPtr Parser::mkImport(std::string_view path, std::string_view hash, bool is_http) {
  auto* e = alloc<Expr>();
  e->kind = Expr::Kind::Import;
  // Copy path to arena for stable storage
  char* data = reinterpret_cast<char*>(arena_.alloc_array<char>(path.size() + 1).data());
  std::copy(path.begin(), path.end(), data);
  data[path.size()] = '\0';

  // Copy hash if present
  const char* hash_data = nullptr;
  if (!hash.empty()) {
    char* hd = reinterpret_cast<char*>(arena_.alloc_array<char>(hash.size() + 1).data());
    std::copy(hash.begin(), hash.end(), hd);
    hd[hash.size()] = '\0';
    hash_data = hd;
  }

  e->import = {data, path.size(), nullptr, 0, hash_data, hash.size(), is_http};
  return e;
}

} // namespace continuity::dhall
