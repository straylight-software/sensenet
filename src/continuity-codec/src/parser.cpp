// Continuity.Codec.Dhall - Parser Implementation
// straylight.software · 2026

#include "parser.hpp"

#include <charconv>

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN PARSE ENTRY
// ═══════════════════════════════════════════════════════════════════════════════

std::expected<ExprPtr, ParseError> Parser::parse() {
  auto* expr = parse_expression();
  if (!expr) {
    return std::unexpected(error("failed to parse expression"));
  }

  if (!check(TokenKind::Eof)) {
    return std::unexpected(error("unexpected token after expression"));
  }

  return expr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// EXPRESSION
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_expression() {
  // expression = annotated | lambda | forall | let | if | assert | merge

  switch (current_.kind) {
    case TokenKind::Backslash:
    case TokenKind::Forall:
      // Could be lambda or forall - check which
      if (current_.kind == TokenKind::Backslash) {
        return parse_lambda();
      }
      return parse_forall();

    case TokenKind::Let:
      return parse_let();

    case TokenKind::If:
      return parse_if();

    case TokenKind::Assert:
      return parse_assert();

    case TokenKind::Merge:
      return parse_merge();

    default:
      return parse_annotated();
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ANNOTATED
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_annotated() {
  auto* expr = parse_operator(0);
  if (!expr)
    return nullptr;

  // Check for type annotation: expr : type
  if (match(TokenKind::Colon)) {
    auto* type = parse_expression();
    if (!type)
      return nullptr;
    return mkAnnot(expr, type);
  }

  return expr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// OPERATOR (PRECEDENCE CLIMBING)
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_operator(int min_prec) {
  auto* lhs = parse_application();
  if (!lhs)
    return nullptr;

  while (true) {
    int prec = get_precedence(current_.kind);
    if (prec < min_prec || prec == 0)
      break;

    TokenKind op = current_.kind;
    advance();

    // Right-associative: use same precedence; left-assoc: use prec+1
    int next_prec = is_right_assoc(op) ? prec : prec + 1;
    auto* rhs = parse_operator(next_prec);
    if (!rhs)
      return nullptr;

    // Create appropriate binary expression
    switch (op) {
      case TokenKind::Arrow: {
        // A -> B is shorthand for forall (_ : A) -> B
        Name underscore = interner_.intern("_");
        lhs = mkPi(underscore, lhs, rhs);
        break;
      }
      case TokenKind::And:
        lhs = mkBinop(Expr::Kind::BoolAnd, lhs, rhs);
        break;
      case TokenKind::Or:
        lhs = mkBinop(Expr::Kind::BoolOr, lhs, rhs);
        break;
      case TokenKind::Plus:
        lhs = mkBinop(Expr::Kind::NatPlus, lhs, rhs);
        break;
      case TokenKind::Times:
        lhs = mkBinop(Expr::Kind::NatTimes, lhs, rhs);
        break;
      case TokenKind::Prefer:
        lhs = mkBinop(Expr::Kind::Prefer, lhs, rhs);
        break;
      case TokenKind::TextAppend:
        lhs = mkBinop(Expr::Kind::TextAppend, lhs, rhs);
        break;
      case TokenKind::ListAppend:
        lhs = mkBinop(Expr::Kind::Prefer, lhs, rhs); // placeholder
        break;
      case TokenKind::Combine:
        lhs = mkBinop(Expr::Kind::Prefer, lhs, rhs); // /\ same as // for now
        break;
      case TokenKind::CombineTypes:
        lhs = mkBinop(Expr::Kind::Prefer, lhs, rhs); // placeholder
        break;
      case TokenKind::Equivalent:
      case TokenKind::Equal:
        lhs = mkBinop(Expr::Kind::Prefer, lhs, rhs); // placeholder
        break;
      case TokenKind::DoubleEqual:
        lhs = mkBinop(Expr::Kind::BoolEq, lhs, rhs);
        break;
      case TokenKind::NotEqual:
        // a != b is equivalent to !(a == b), but for now just negate the result
        lhs = mkBinop(Expr::Kind::BoolEq, lhs, rhs); // simplified: treat as ==
        break;
      case TokenKind::Alternative:
        // Import alternative - for now just return lhs
        lhs = rhs; // simplified: just take the rhs
        break;
      default:
        // Unknown operator
        break;
    }
  }

  return lhs;
}

// ═══════════════════════════════════════════════════════════════════════════════
// APPLICATION
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_application() {
  auto* func = parse_import();
  if (!func)
    return nullptr;

  // Application is left-associative: f x y = (f x) y
  while (true) {
    // Check if next token can start an argument
    // (basically anything except operators, keywords, and string continuations)
    if (check(TokenKind::Eof) || check(TokenKind::RParen) || check(TokenKind::RBrace) ||
        check(TokenKind::RBracket) || check(TokenKind::RAngle) || check(TokenKind::Comma) ||
        check(TokenKind::Colon) || check(TokenKind::Equal) || check(TokenKind::In) ||
        check(TokenKind::Then) || check(TokenKind::Else) || get_precedence(current_.kind) > 0) {
      break;
    }

    // Special check for TextLit: a continuation token (from string interpolation)
    // is just the text after the interpolation, possibly with closing quote.
    // A new string argument must:
    //   - Start with " AND have either: length >= 2 (some content or closing quote), OR
    //   - Start with '' (multiline)
    // A continuation token doesn't start with an opening quote sequence.
    if (check(TokenKind::TextLit)) {
      std::string_view text = current_.text(src_);
      bool is_new_string = false;
      if (text.size() >= 2 && text[0] == '"') {
        // Double-quoted string: "..." - valid new string if at least 2 chars
        is_new_string = true;
      } else if (text.size() >= 4 && text[0] == '\'' && text[1] == '\'') {
        // Multiline string: ''...'' - valid new string if at least 4 chars
        is_new_string = true;
      }
      if (!is_new_string) {
        // This is a continuation token, not a new string - stop here
        break;
      }
    }

    auto* arg = parse_import();
    if (!arg)
      break;

    func = mkApp(func, arg);
  }

  return func;
}

// ═══════════════════════════════════════════════════════════════════════════════
// IMPORT
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_import() {
  // Handle imports: ./path.dhall, ../path.dhall, env:VAR, https://...
  if (check(TokenKind::LocalPath)) {
    std::string_view path = current_.text(src_);
    advance();

    // Check for sha256 hash token
    std::string_view hash;
    if (check(TokenKind::Hash)) {
      std::string_view hash_tok = current_.text(src_);
      // Token includes "sha256:", skip it
      if (hash_tok.starts_with("sha256:") && hash_tok.size() == 71) {
        hash = hash_tok.substr(7);
      }
      advance();
    }

    return mkImport(path, hash, false);
  }

  if (check(TokenKind::HttpUrl)) {
    std::string_view path = current_.text(src_);
    advance();

    // Check for sha256 hash token
    std::string_view hash;
    if (check(TokenKind::Hash)) {
      std::string_view hash_tok = current_.text(src_);
      if (hash_tok.starts_with("sha256:") && hash_tok.size() == 71) {
        hash = hash_tok.substr(7);
      }
      advance();
    }

    return mkImport(path, hash, true);
  }

  if (check(TokenKind::EnvVar)) {
    std::string_view path = current_.text(src_);
    advance();
    return mkImport(path, {}, false);
  }

  return parse_selector();
}

// ═══════════════════════════════════════════════════════════════════════════════
// SELECTOR (FIELD ACCESS / WITH)
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_selector() {
  auto* expr = parse_primitive();
  if (!expr)
    return nullptr;

  while (true) {
    if (match(TokenKind::Dot)) {
      // Field access: expr.field
      // Field names can be Labels, QuotedLabels, or Builtins (like Text, List, etc.)
      if (!check(TokenKind::Label) && !check(TokenKind::QuotedLabel) &&
          !check(TokenKind::Builtin)) {
        return nullptr; // expected field name
      }
      std::string_view field = current_.text(src_);
      Name name = interner_.intern(field);
      advance();
      expr = mkField(expr, name);
    } else if (match(TokenKind::With)) {
      // With expression: expr with path = value
      // Parse the field path (can be nested like "a.b.c")
      if (!check(TokenKind::Label) && !check(TokenKind::QuotedLabel)) {
        return nullptr;
      }

      // Build nested field updates using Prefer operator
      // expr with a.b = v  =>  expr // { a = (expr.a) // { b = v } }
      std::vector<Name> path;
      while (check(TokenKind::Label) || check(TokenKind::QuotedLabel)) {
        std::string_view field = current_.text(src_);
        path.push_back(interner_.intern(field));
        advance();
        if (!match(TokenKind::Dot))
          break;
      }

      if (!match(TokenKind::Equal)) {
        return nullptr;
      }

      auto* value = parse_import();
      if (!value)
        return nullptr;

      // Build the nested record update from inside out
      // For path [a, b, c] and value v:
      //   expr // { a = (expr.a) // { b = (expr.a.b) // { c = v } } }
      // Simplified: just use Prefer with the innermost field
      auto* update_fields = alloc<Fields<ExprPtr>>();
      update_fields->insert(path.back(), value);
      auto* innermost = mkRecordLit(update_fields);

      // Wrap with outer levels (simplified - full implementation would be recursive)
      for (int i = static_cast<int>(path.size()) - 2; i >= 0; --i) {
        auto* outer_fields = alloc<Fields<ExprPtr>>();
        outer_fields->insert(path[i], innermost);
        innermost = mkRecordLit(outer_fields);
      }

      expr = mkBinop(Expr::Kind::Prefer, expr, innermost);
    } else {
      break;
    }
  }

  return expr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// PRIMITIVE
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_primitive() {
  switch (current_.kind) {
    case TokenKind::LParen: {
      advance();
      auto* expr = parse_expression();
      if (!expr)
        return nullptr;
      if (!match(TokenKind::RParen)) {
        return nullptr; // expected )
      }
      return expr;
    }

    case TokenKind::LBrace:
      return parse_record();

    case TokenKind::LBracket:
      return parse_list();

    case TokenKind::LAngle:
      return parse_union();

    case TokenKind::NaturalLit: {
      std::uint64_t val = current_.natural_val;
      advance();
      return mkLit(Lit::Nat(val));
    }

    case TokenKind::IntegerLit: {
      std::int64_t val = current_.integer_val;
      advance();
      return mkLit(Lit::Int(val));
    }

    case TokenKind::DoubleLit: {
      double val = current_.double_val;
      advance();
      return mkLit(Lit::Double(val));
    }

    case TokenKind::TextLit:
      return parse_text();

    case TokenKind::Builtin: {
      BuiltinName bn = static_cast<BuiltinName>(current_.natural_val);
      advance();

      // Convert lexer's BuiltinName to evaluator's Builtin
      switch (bn) {
        case BuiltinName::Bool:
          return mkBuiltin(Builtin::Bool);
        case BuiltinName::True:
          return mkLit(Lit::Bool(true));
        case BuiltinName::False:
          return mkLit(Lit::Bool(false));
        case BuiltinName::Natural:
          return mkBuiltin(Builtin::Natural);
        case BuiltinName::Natural_fold:
          return mkBuiltin(Builtin::NaturalFold);
        case BuiltinName::Natural_build:
          return mkBuiltin(Builtin::NaturalBuild);
        case BuiltinName::Natural_isZero:
          return mkBuiltin(Builtin::NaturalIsZero);
        case BuiltinName::Natural_even:
          return mkBuiltin(Builtin::NaturalEven);
        case BuiltinName::Natural_odd:
          return mkBuiltin(Builtin::NaturalOdd);
        case BuiltinName::Natural_toInteger:
          return mkBuiltin(Builtin::NaturalToInteger);
        case BuiltinName::Natural_show:
          return mkBuiltin(Builtin::NaturalShow);
        case BuiltinName::Natural_subtract:
          return mkBuiltin(Builtin::NaturalSubtract);
        case BuiltinName::Integer:
          return mkBuiltin(Builtin::Integer);
        case BuiltinName::Integer_clamp:
          return mkBuiltin(Builtin::IntegerClamp);
        case BuiltinName::Integer_negate:
          return mkBuiltin(Builtin::IntegerNegate);
        case BuiltinName::Integer_show:
          return mkBuiltin(Builtin::IntegerShow);
        case BuiltinName::Integer_toDouble:
          return mkBuiltin(Builtin::IntegerToDouble);
        case BuiltinName::Double:
          return mkBuiltin(Builtin::Double);
        case BuiltinName::Double_show:
          return mkBuiltin(Builtin::DoubleShow);
        case BuiltinName::Text:
          return mkBuiltin(Builtin::Text);
        case BuiltinName::Text_show:
          return mkBuiltin(Builtin::TextShow);
        case BuiltinName::Text_replace:
          return mkBuiltin(Builtin::TextReplace);
        case BuiltinName::List:
          return mkBuiltin(Builtin::List);
        case BuiltinName::List_build:
          return mkBuiltin(Builtin::ListBuild);
        case BuiltinName::List_fold:
          return mkBuiltin(Builtin::ListFold);
        case BuiltinName::List_length:
          return mkBuiltin(Builtin::ListLength);
        case BuiltinName::List_head:
          return mkBuiltin(Builtin::ListHead);
        case BuiltinName::List_last:
          return mkBuiltin(Builtin::ListLast);
        case BuiltinName::List_indexed:
          return mkBuiltin(Builtin::ListIndexed);
        case BuiltinName::List_reverse:
          return mkBuiltin(Builtin::ListReverse);
        case BuiltinName::Optional:
          return mkBuiltin(Builtin::Optional);
        case BuiltinName::None:
          return mkBuiltin(Builtin::None);
        case BuiltinName::Some:
          return mkBuiltin(Builtin::Some);
        default:
          return nullptr;
      }
    }

    case TokenKind::Type:
      advance();
      return mkConst(Const::Type);

    case TokenKind::Kind:
      advance();
      return mkConst(Const::Kind);

    case TokenKind::Sort:
      advance();
      return mkConst(Const::Sort);

    case TokenKind::Label:
    case TokenKind::QuotedLabel: {
      std::string_view text = current_.text(src_);
      Name name = interner_.intern(text);
      advance();

      // Check for @n de Bruijn index
      std::uint32_t idx = 0;
      if (match(TokenKind::At)) {
        if (check(TokenKind::NaturalLit)) {
          idx = static_cast<std::uint32_t>(current_.natural_val);
          advance();
        }
      }

      // For now, just use idx=0 (will need scope tracking for proper resolution)
      return mkVar(idx);
    }

    default:
      return nullptr;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LAMBDA
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_lambda() {
  // \ (x : T) -> body
  // λ (x : T) -> body
  advance(); // consume \ or λ

  if (!match(TokenKind::LParen)) {
    return nullptr; // expected (
  }

  if (!check(TokenKind::Label)) {
    return nullptr; // expected parameter name
  }
  std::string_view param_text = current_.text(src_);
  Name param = interner_.intern(param_text);
  advance();

  if (!match(TokenKind::Colon)) {
    return nullptr; // expected :
  }

  auto* type = parse_expression();
  if (!type)
    return nullptr;

  if (!match(TokenKind::RParen)) {
    return nullptr; // expected )
  }

  if (!match(TokenKind::Arrow)) {
    return nullptr; // expected ->
  }

  auto* body = parse_expression();
  if (!body)
    return nullptr;

  return mkLam(param, type, body);
}

// ═══════════════════════════════════════════════════════════════════════════════
// FORALL (PI TYPE)
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_forall() {
  // forall (x : T) -> U
  // ∀ (x : T) -> U
  advance(); // consume forall or ∀

  if (!match(TokenKind::LParen)) {
    return nullptr;
  }

  if (!check(TokenKind::Label)) {
    return nullptr;
  }
  std::string_view param_text = current_.text(src_);
  Name param = interner_.intern(param_text);
  advance();

  if (!match(TokenKind::Colon)) {
    return nullptr;
  }

  auto* domain = parse_expression();
  if (!domain)
    return nullptr;

  if (!match(TokenKind::RParen)) {
    return nullptr;
  }

  if (!match(TokenKind::Arrow)) {
    return nullptr;
  }

  auto* codomain = parse_expression();
  if (!codomain)
    return nullptr;

  return mkPi(param, domain, codomain);
}

// ═══════════════════════════════════════════════════════════════════════════════
// LET
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_let() {
  // let x : T = e in body
  // let x = e in body
  advance(); // consume 'let'

  if (!check(TokenKind::Label)) {
    return nullptr;
  }
  std::string_view name_text = current_.text(src_);
  Name name = interner_.intern(name_text);
  advance();

  ExprPtr type = nullptr;
  if (match(TokenKind::Colon)) {
    type = parse_expression();
    if (!type)
      return nullptr;
  }

  if (!match(TokenKind::Equal)) {
    return nullptr;
  }

  auto* value = parse_expression();
  if (!value)
    return nullptr;

  // Check for chained lets or 'in'
  ExprPtr body;
  if (check(TokenKind::Let)) {
    // Chained let without 'in'
    body = parse_let();
  } else {
    if (!match(TokenKind::In)) {
      return nullptr;
    }
    body = parse_expression();
  }
  if (!body)
    return nullptr;

  return mkLet(name, type, value, body);
}

// ═══════════════════════════════════════════════════════════════════════════════
// IF
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_if() {
  // if cond then t else f
  advance(); // consume 'if'

  auto* cond = parse_expression();
  if (!cond)
    return nullptr;

  if (!match(TokenKind::Then)) {
    return nullptr;
  }

  auto* then_ = parse_expression();
  if (!then_)
    return nullptr;

  if (!match(TokenKind::Else)) {
    return nullptr;
  }

  auto* else_ = parse_expression();
  if (!else_)
    return nullptr;

  return mkIf(cond, then_, else_);
}

// ═══════════════════════════════════════════════════════════════════════════════
// ASSERT
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_assert() {
  // assert : T
  advance(); // consume 'assert'

  if (!match(TokenKind::Colon)) {
    return nullptr;
  }

  auto* type = parse_expression();
  if (!type)
    return nullptr;

  // Assert is basically an annotation that the type is inhabited
  // For now, just return the type
  return type;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MERGE
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_merge() {
  // merge handler union : T
  advance(); // consume 'merge'

  auto* handler = parse_import();
  if (!handler)
    return nullptr;

  auto* union_val = parse_import();
  if (!union_val)
    return nullptr;

  ExprPtr type = nullptr;
  if (match(TokenKind::Colon)) {
    type = parse_expression();
  }

  // Merge is application: handler applied to union
  // Simplified for now
  return mkApp(handler, union_val);
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORD
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_record() {
  // { field = value, ... } or { field : type, ... } (record type)
  advance(); // consume '{'

  auto* fields = alloc<Fields<ExprPtr>>();

  // Empty record: {} or {=}
  if (match(TokenKind::RBrace)) {
    return mkRecordLit(fields);
  }
  if (match(TokenKind::Equal)) {
    // {=} is explicit empty record literal
    if (!match(TokenKind::RBrace)) {
      return nullptr;
    }
    return mkRecordLit(fields);
  }

  // Detect if this is a record literal or record type
  bool is_type = false;

  while (true) {
    // Field names can be Labels, QuotedLabels, Builtins (like None, Some, True, False),
    // or keywords like Type, Kind, Sort when used in field position
    if (!check(TokenKind::Label) && !check(TokenKind::QuotedLabel) && !check(TokenKind::Builtin) &&
        !check(TokenKind::Type) && !check(TokenKind::Kind) && !check(TokenKind::Sort)) {
      return nullptr;
    }

    std::string_view field_text = current_.text(src_);
    Name field_name = interner_.intern(field_text);
    advance();

    if (check(TokenKind::Equal)) {
      // Record literal: field = value
      advance();
      auto* value = parse_expression();
      if (!value)
        return nullptr;
      fields->insert(field_name, value);
    } else if (check(TokenKind::Colon)) {
      // Record type: field : type
      is_type = true;
      advance();
      auto* type = parse_expression();
      if (!type)
        return nullptr;
      fields->insert(field_name, type);
    } else if (check(TokenKind::Comma) || check(TokenKind::RBrace)) {
      // Punning: { field } means { field = field }
      // Create a variable reference with the field name
      auto* value = mkVar(0); // Will need proper scope tracking
      fields->insert(field_name, value);
    } else {
      return nullptr;
    }

    if (match(TokenKind::RBrace)) {
      break;
    }

    if (!match(TokenKind::Comma)) {
      return nullptr;
    }
  }

  return is_type ? mkRecord(fields) : mkRecordLit(fields);
}

// ═══════════════════════════════════════════════════════════════════════════════
// UNION
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_union() {
  // < Constructor : Type | ... >
  advance(); // consume '<'

  auto* fields = alloc<Fields<ExprPtr>>();

  // Empty union
  if (match(TokenKind::RAngle)) {
    return mkRecord(fields); // Union types are represented as record types
  }

  while (true) {
    if (!check(TokenKind::Label)) {
      return nullptr;
    }

    std::string_view ctor_text = current_.text(src_);
    Name ctor_name = interner_.intern(ctor_text);
    advance();

    ExprPtr type = nullptr;
    if (match(TokenKind::Colon)) {
      type = parse_expression();
      if (!type)
        return nullptr;
    } else {
      // Nullary constructor - type is unit
      type = mkRecordLit(alloc<Fields<ExprPtr>>());
    }

    fields->insert(ctor_name, type);

    if (match(TokenKind::RAngle)) {
      break;
    }

    if (!match(TokenKind::Pipe)) {
      return nullptr;
    }
  }

  return mkRecord(fields);
}

// ═══════════════════════════════════════════════════════════════════════════════
// LIST
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_list() {
  // [ elem, ... ] or [] : List T
  advance(); // consume '['

  std::vector<ExprPtr> elems;

  // Empty list
  if (match(TokenKind::RBracket)) {
    ExprPtr type = nullptr;
    if (match(TokenKind::Colon)) {
      type = parse_expression();
    }
    return mkList(type, elems);
  }

  while (true) {
    auto* elem = parse_expression();
    if (!elem)
      return nullptr;
    elems.push_back(elem);

    if (match(TokenKind::RBracket)) {
      break;
    }

    if (!match(TokenKind::Comma)) {
      return nullptr;
    }
  }

  return mkList(nullptr, elems);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEXT
// ═══════════════════════════════════════════════════════════════════════════════

ExprPtr Parser::parse_text() {
  // "text" or ''multiline text'' or "foo${expr}bar"
  std::string_view text = current_.text(src_);
  advance();

  // Detect quote type and strip opening/closing quotes
  char quote_type = '"';
  bool has_opening = false;
  bool has_closing = false;

  if (text.size() >= 1 && text.front() == '"') {
    has_opening = true;
    text = text.substr(1);
  } else if (text.size() >= 2 && text.substr(0, 2) == "''") {
    quote_type = '\'';
    has_opening = true;
    text = text.substr(2);
  }

  if (text.size() >= 1 && text.back() == '"' && quote_type == '"') {
    has_closing = true;
    text = text.substr(0, text.size() - 1);
  } else if (text.size() >= 2 && text.substr(text.size() - 2) == "''" && quote_type == '\'') {
    has_closing = true;
    text = text.substr(0, text.size() - 2);
  }

  // Create the text literal for this chunk
  char* data = reinterpret_cast<char*>(arena_.alloc_array<char>(text.size() + 1).data());
  std::copy(text.begin(), text.end(), data);
  data[text.size()] = '\0';
  ExprPtr result = mkLit(Lit::Text(data, text.size()));

  // If no closing quote, there's an interpolation following
  // Pattern: "prefix${expr}suffix" becomes prefix ++ expr ++ suffix
  // The interpolated expression can be any Dhall expression
  while (!has_closing) {
    // Parse the interpolated expression (can be if-then-else, application, etc.)
    auto* interp_expr = parse_expression();
    if (!interp_expr)
      return nullptr;

    // Concatenate: result ++ interp_expr
    result = mkBinop(Expr::Kind::TextAppend, result, interp_expr);

    // Now we should have the continuation text
    if (!check(TokenKind::TextLit)) {
      return nullptr; // expected continuation
    }

    std::string_view cont_text = current_.text(src_);
    advance();

    // Continuation text from lexer: NO opening quote, but has closing quote if string ends
    // The continuation only has closing quote, never opening
    has_closing = false;
    if (quote_type == '"') {
      // For double-quoted: continuation might be just `"` (closing) or `text"` (text + closing)
      if (cont_text.size() >= 1 && cont_text.back() == '"') {
        has_closing = true;
        cont_text = cont_text.substr(0, cont_text.size() - 1);
      }
    } else {
      // For multiline: continuation ends with ''
      if (cont_text.size() >= 2 && cont_text.substr(cont_text.size() - 2) == "''") {
        has_closing = true;
        cont_text = cont_text.substr(0, cont_text.size() - 2);
      }
    }

    // Only add to result if there's actual text content
    if (cont_text.size() > 0) {
      char* cont_data =
          reinterpret_cast<char*>(arena_.alloc_array<char>(cont_text.size() + 1).data());
      std::copy(cont_text.begin(), cont_text.end(), cont_data);
      cont_data[cont_text.size()] = '\0';
      auto* cont_lit = mkLit(Lit::Text(cont_data, cont_text.size()));
      result = mkBinop(Expr::Kind::TextAppend, result, cont_lit);
    }
  }

  return result;
}

} // namespace continuity::dhall
