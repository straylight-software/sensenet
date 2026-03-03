// Continuity.Codec - LL(k) Dhall Parser Implementation
//
// This implements a predictive LL(k) parser for Dhall following the
// official ABNF grammar as closely as possible.
//
// Key design decisions:
//   - LL(4) lookahead is sufficient for most Dhall constructs
//   - No separate lexer phase - character-level parsing as per grammar notes
//   - Minimal backtracking - only where explicitly required by grammar
//   - Direct recursion for expression precedence
//
// straylight.software - 2026

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <unordered_set>

#include "Codec.hpp"
#include "Utf8.hpp"

namespace continuity::codec {

// ============================================================================
// Keywords and Builtins Tables
// ============================================================================

namespace {

// Keywords that cannot be simple labels
constexpr std::array<std::string_view, 17> KEYWORDS = {
    "if",       "then", "else",  "let",  "in",    "using",  "missing", "assert",          "as",
    "Infinity", "NaN",  "merge", "Some", "toMap", "forall", "with",    "showConstructor",
};

// Builtin identifiers
constexpr std::array<std::string_view, 51> BUILTINS = {
    // Types
    "Bool",
    "Natural",
    "Integer",
    "Double",
    "Text",
    "Bytes",
    "Date",
    "Time",
    "TimeZone",
    "List",
    "Optional",
    "Type",
    "Kind",
    "Sort",
    // Values
    "True",
    "False",
    "None",
    // Natural functions
    "Natural/fold",
    "Natural/build",
    "Natural/isZero",
    "Natural/even",
    "Natural/odd",
    "Natural/toInteger",
    "Natural/show",
    "Natural/subtract",
    // Integer functions
    "Integer/toDouble",
    "Integer/show",
    "Integer/negate",
    "Integer/clamp",
    // Double functions
    "Double/show",
    // List functions
    "List/build",
    "List/fold",
    "List/length",
    "List/head",
    "List/last",
    "List/indexed",
    "List/reverse",
    // Text functions
    "Text/show",
    "Text/replace",
    // Temporal functions
    "Date/show",
    "Time/show",
    "TimeZone/show",
};

auto make_keyword_set() -> std::unordered_set<std::string_view> {
  return {KEYWORDS.begin(), KEYWORDS.end()};
}

auto make_builtin_set() -> std::unordered_set<std::string_view> {
  return {BUILTINS.begin(), BUILTINS.end()};
}

const auto& keyword_set() {
  static const auto set = make_keyword_set();
  return set;
}

const auto& builtin_set() {
  static const auto set = make_builtin_set();
  return set;
}

} // namespace

// ============================================================================
// Parser Implementation
// ============================================================================

Parser::Parser(std::string_view source, std::string filename)
    : source_(source), filename_(std::move(filename)), pos_{1, 1, 0} {}

auto Parser::is_keyword(std::string_view s) const -> bool {
  return keyword_set().contains(s);
}

auto Parser::is_builtin(std::string_view s) const -> bool {
  return builtin_set().contains(s);
}

// ============================================================================
// Lexer Primitives
// ============================================================================

auto Parser::peek(std::size_t ahead) -> char32_t {
  auto remaining = source_.substr(pos_.offset);
  for (std::size_t i = 0; i < ahead; ++i) {
    if (remaining.empty())
      return utf8::END_OF_INPUT;
    auto [_, len] = utf8::decode(remaining);
    remaining.remove_prefix(len);
  }
  if (remaining.empty())
    return utf8::END_OF_INPUT;
  auto [cp, _] = utf8::decode(remaining);
  return cp;
}

auto Parser::advance() -> char32_t {
  if (pos_.offset >= source_.size()) {
    return utf8::END_OF_INPUT;
  }

  auto [cp, len] = utf8::decode(source_.substr(pos_.offset));

  // Update position tracking
  if (cp == '\n') {
    pos_.line++;
    pos_.column = 1;
  } else if (cp == '\r') {
    // Handle \r\n as single newline
    if (pos_.offset + len < source_.size() && source_[pos_.offset + len] == '\n') {
      len++;
    }
    pos_.line++;
    pos_.column = 1;
  } else {
    pos_.column++;
  }

  pos_.offset += len;
  return cp;
}

auto Parser::match(std::string_view s) -> bool {
  if (source_.substr(pos_.offset).starts_with(s)) {
    for (std::size_t i = 0; i < s.size();) {
      auto [_, len] = utf8::decode(s.substr(i));
      advance();
      i += len;
    }
    return true;
  }
  return false;
}

auto Parser::match_keyword(std::string_view kw) -> bool {
  auto remaining = source_.substr(pos_.offset);
  if (!remaining.starts_with(kw))
    return false;

  // Keyword must not be followed by simple-label-next-char
  if (remaining.size() > kw.size()) {
    auto [next, _] = utf8::decode(remaining.substr(kw.size()));
    if (utf8::is_simple_label_next(next))
      return false;
  }

  // Consume the keyword
  for (std::size_t i = 0; i < kw.size();) {
    auto [_, len] = utf8::decode(kw.substr(i));
    advance();
    i += len;
  }
  return true;
}

// ============================================================================
// Whitespace and Comments
// ============================================================================

auto Parser::skip_whitespace() -> void {
  while (true) {
    auto cp = peek();
    if (cp == ' ' || cp == '\t' || cp == '\n' || cp == '\r') {
      advance();
    } else if (cp == '-' && peek(1) == '-') {
      skip_line_comment();
    } else if (cp == '{' && peek(1) == '-') {
      if (!skip_block_comment())
        return;
    } else {
      return;
    }
  }
}

auto Parser::skip_line_comment() -> bool {
  if (!match("--"))
    return false;

  // Consume until end of line
  while (true) {
    auto cp = peek();
    if (cp == utf8::END_OF_INPUT)
      break;
    if (cp == '\n' || cp == '\r') {
      advance();
      break;
    }
    if (!utf8::is_not_end_of_line(cp))
      break;
    advance();
  }
  return true;
}

auto Parser::skip_block_comment() -> bool {
  if (!match("{-"))
    return false;

  std::size_t depth = 1;
  while (depth > 0) {
    auto cp = peek();
    if (cp == utf8::END_OF_INPUT) {
      // Unterminated block comment - could return error
      return false;
    }
    if (cp == '{' && peek(1) == '-') {
      advance();
      advance();
      depth++;
    } else if (cp == '-' && peek(1) == '}') {
      advance();
      advance();
      depth--;
    } else {
      advance();
    }
  }
  return true;
}

// ============================================================================
// Error Handling
// ============================================================================

auto Parser::make_error(std::string_view msg, std::string_view context) -> ParseError {
  return ParseError{
      .position = pos_,
      .message = std::string(msg),
      .context = std::string(context),
  };
}

auto Parser::expect(char32_t c) -> std::expected<void, ParseError> {
  if (peek() != c) {
    char buf[8];
    auto len = utf8::encode(c, buf);
    return std::unexpected(make_error("expected '" + std::string(buf, len) + "'"));
  }
  advance();
  return {};
}

auto Parser::expect(std::string_view s) -> std::expected<void, ParseError> {
  if (!match(s)) {
    return std::unexpected(make_error("expected '" + std::string(s) + "'"));
  }
  return {};
}

auto Parser::current_span() const -> SourceSpan {
  return SourceSpan{pos_, pos_, {}};
}

// ============================================================================
// Label Parsers
// ============================================================================

auto Parser::parse_label() -> std::expected<std::string, ParseError> {
  // label = ("`" quoted-label "`" / simple-label)
  if (peek() == '`') {
    advance(); // consume `
    std::string result;
    while (true) {
      auto cp = peek();
      if (cp == '`') {
        advance();
        return result;
      }
      if (!utf8::is_quoted_label_char(cp)) {
        return std::unexpected(make_error("invalid character in quoted label"));
      }
      char buf[4];
      auto len = utf8::encode(cp, buf);
      result.append(buf, len);
      advance();
    }
  }

  // simple-label
  auto cp = peek();
  if (!utf8::is_simple_label_first(cp)) {
    return std::unexpected(make_error("expected label"));
  }

  std::string result;
  char buf[4];
  auto len = utf8::encode(cp, buf);
  result.append(buf, len);
  advance();

  while (utf8::is_simple_label_next(peek())) {
    cp = peek();
    len = utf8::encode(cp, buf);
    result.append(buf, len);
    advance();
  }

  return result;
}

auto Parser::parse_any_label() -> std::expected<std::string, ParseError> {
  // any-label = label (can be builtin but not keyword)
  auto label = parse_label();
  if (!label)
    return label;

  // Check it's not a keyword
  if (is_keyword(*label)) {
    return std::unexpected(make_error("keyword cannot be used as label: " + *label));
  }

  return label;
}

auto Parser::parse_nonreserved_label() -> std::expected<std::string, ParseError> {
  // nonreserved-label = label (cannot be builtin or keyword)
  auto label = parse_label();
  if (!label)
    return label;

  if (is_keyword(*label) || is_builtin(*label)) {
    return std::unexpected(make_error("reserved identifier: " + *label));
  }

  return label;
}

// ============================================================================
// Literal Parsers
// ============================================================================

auto Parser::parse_natural() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  std::uint64_t value = 0;
  bool has_digits = false;

  // Check for 0b (binary) or 0x (hex) prefix
  if (peek() == '0') {
    auto next = peek(1);
    if (next == 'b' || next == 'B') {
      // Binary literal
      advance();
      advance(); // consume 0b
      while (peek() == '0' || peek() == '1') {
        value = value * 2 + (peek() - '0');
        advance();
        has_digits = true;
      }
      if (!has_digits) {
        return std::unexpected(make_error("expected binary digits after 0b"));
      }
    } else if (next == 'x' || next == 'X') {
      // Hex literal
      advance();
      advance(); // consume 0x
      while (auto v = utf8::hex_value(peek())) {
        value = value * 16 + *v;
        advance();
        has_digits = true;
      }
      if (!has_digits) {
        return std::unexpected(make_error("expected hex digits after 0x"));
      }
    } else {
      // Just 0
      advance();
      value = 0;
      has_digits = true;
    }
  } else if (utf8::is_digit(peek())) {
    // Decimal, no leading zeros allowed
    while (utf8::is_digit(peek())) {
      value = value * 10 + (peek() - '0');
      advance();
      has_digits = true;
    }
  }

  if (!has_digits) {
    return std::unexpected(make_error("expected natural literal"));
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = value;
  return expr;
}

auto Parser::parse_integer() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  bool negative = false;
  if (peek() == '+') {
    advance();
  } else if (peek() == '-') {
    advance();
    negative = true;
  } else {
    return std::unexpected(make_error("expected '+' or '-' for integer"));
  }

  auto nat = parse_natural();
  if (!nat)
    return nat;

  auto value = std::get<std::uint64_t>((*nat)->data);
  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = negative ? -static_cast<std::int64_t>(value) : static_cast<std::int64_t>(value);
  return expr;
}

auto Parser::parse_double() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Check for special values
  if (match_keyword("NaN")) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = std::nan("");
    return expr;
  }

  if (peek() == '-' && match("-Infinity")) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = -std::numeric_limits<double>::infinity();
    return expr;
  }

  if (match_keyword("Infinity")) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = std::numeric_limits<double>::infinity();
    return expr;
  }

  // numeric-double-literal = [ "+" / "-" ] 1*DIGIT ( "." 1*DIGIT [ exponent ] / exponent)
  std::string num_str;

  if (peek() == '+' || peek() == '-') {
    num_str += static_cast<char>(peek());
    advance();
  }

  if (!utf8::is_digit(peek())) {
    return std::unexpected(make_error("expected double literal"));
  }

  while (utf8::is_digit(peek())) {
    num_str += static_cast<char>(peek());
    advance();
  }

  bool has_decimal = false;
  if (peek() == '.') {
    num_str += '.';
    advance();
    if (!utf8::is_digit(peek())) {
      return std::unexpected(make_error("expected digits after decimal point"));
    }
    while (utf8::is_digit(peek())) {
      num_str += static_cast<char>(peek());
      advance();
    }
    has_decimal = true;
  }

  bool has_exponent = false;
  if (peek() == 'e' || peek() == 'E') {
    num_str += 'e';
    advance();
    if (peek() == '+' || peek() == '-') {
      num_str += static_cast<char>(peek());
      advance();
    }
    if (!utf8::is_digit(peek())) {
      return std::unexpected(make_error("expected digits in exponent"));
    }
    while (utf8::is_digit(peek())) {
      num_str += static_cast<char>(peek());
      advance();
    }
    has_exponent = true;
  }

  if (!has_decimal && !has_exponent) {
    return std::unexpected(make_error("double must have decimal or exponent"));
  }

  double value;
  auto result = std::from_chars(num_str.data(), num_str.data() + num_str.size(), value);
  if (result.ec != std::errc{}) {
    return std::unexpected(make_error("invalid double literal"));
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = value;
  return expr;
}

auto Parser::parse_text_literal() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;
  std::vector<TextChunk> chunks;

  if (peek() == '"') {
    // double-quote-literal
    advance(); // consume "

    std::string current_text;
    while (true) {
      auto cp = peek();
      if (cp == '"') {
        advance();
        break;
      }
      if (cp == '$' && peek(1) == '{') {
        // String interpolation
        if (!current_text.empty()) {
          chunks.push_back(TextChunk{std::move(current_text)});
          current_text.clear();
        }
        advance();
        advance(); // consume ${
        skip_whitespace();
        auto inner = parse_complete_expression();
        if (!inner)
          return std::unexpected(inner.error());
        skip_whitespace();
        if (auto r = expect('}'); !r)
          return std::unexpected(r.error());
        chunks.push_back(TextChunk{std::move(*inner)});
      } else if (cp == '\\') {
        // Escape sequence
        advance();
        auto esc = peek();
        switch (esc) {
          case '"':
            current_text += '"';
            advance();
            break;
          case '$':
            current_text += '$';
            advance();
            break;
          case '\\':
            current_text += '\\';
            advance();
            break;
          case '/':
            current_text += '/';
            advance();
            break;
          case 'b':
            current_text += '\b';
            advance();
            break;
          case 'f':
            current_text += '\f';
            advance();
            break;
          case 'n':
            current_text += '\n';
            advance();
            break;
          case 'r':
            current_text += '\r';
            advance();
            break;
          case 't':
            current_text += '\t';
            advance();
            break;
          case 'u': {
            advance(); // consume u
            char32_t codepoint = 0;
            if (peek() == '{') {
              advance();
              while (peek() == '0')
                advance(); // skip leading zeros
              int digits = 0;
              while (auto v = utf8::hex_value(peek())) {
                codepoint = codepoint * 16 + *v;
                advance();
                digits++;
                if (digits > 6) {
                  return std::unexpected(make_error("unicode escape too long"));
                }
              }
              if (auto r = expect('}'); !r)
                return std::unexpected(r.error());
            } else {
              // Exactly 4 hex digits
              for (int i = 0; i < 4; i++) {
                auto v = utf8::hex_value(peek());
                if (!v) {
                  return std::unexpected(make_error("expected 4 hex digits"));
                }
                codepoint = codepoint * 16 + *v;
                advance();
              }
            }
            // Validate codepoint
            if (!utf8::is_valid_non_ascii(codepoint) && codepoint >= 0x80) {
              return std::unexpected(make_error("invalid unicode codepoint"));
            }
            char buf[4];
            auto len = utf8::encode(codepoint, buf);
            current_text.append(buf, len);
            break;
          }
          default:
            return std::unexpected(make_error("invalid escape sequence"));
        }
      } else if (utf8::is_double_quote_char(cp)) {
        char buf[4];
        auto len = utf8::encode(cp, buf);
        current_text.append(buf, len);
        advance();
      } else {
        return std::unexpected(make_error("invalid character in string"));
      }
    }

    if (!current_text.empty()) {
      chunks.push_back(TextChunk{std::move(current_text)});
    }
  } else if (peek() == '\'' && peek(1) == '\'') {
    // single-quote-literal (multi-line)
    advance();
    advance(); // consume ''

    // Must have end-of-line immediately after ''
    if (peek() == '\n') {
      advance();
    } else if (peek() == '\r') {
      advance();
      if (peek() == '\n')
        advance();
    } else {
      return std::unexpected(make_error("newline required after ''"));
    }

    std::string current_text;
    while (true) {
      if (peek() == '\'' && peek(1) == '\'') {
        if (peek(2) == '\'') {
          // Escaped single quotes: ''' -> ''
          current_text += "''";
          advance();
          advance();
          advance();
        } else if (peek(2) == '$' && peek(3) == '{') {
          // Escaped interpolation: ''${ -> ${
          current_text += "${";
          advance();
          advance();
          advance();
          advance();
        } else {
          // End of string
          advance();
          advance();
          break;
        }
      } else if (peek() == '$' && peek(1) == '{') {
        // Interpolation
        if (!current_text.empty()) {
          chunks.push_back(TextChunk{std::move(current_text)});
          current_text.clear();
        }
        advance();
        advance();
        skip_whitespace();
        auto inner = parse_complete_expression();
        if (!inner)
          return std::unexpected(inner.error());
        skip_whitespace();
        if (auto r = expect('}'); !r)
          return std::unexpected(r.error());
        chunks.push_back(TextChunk{std::move(*inner)});
      } else if (utf8::is_single_quote_char(peek())) {
        char buf[4];
        auto len = utf8::encode(peek(), buf);
        current_text.append(buf, len);
        advance();
      } else {
        return std::unexpected(make_error("invalid character in multi-line string"));
      }
    }

    if (!current_text.empty()) {
      chunks.push_back(TextChunk{std::move(current_text)});
    }
  } else {
    return std::unexpected(make_error("expected string literal"));
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = std::move(chunks);
  return expr;
}

auto Parser::parse_bytes_literal() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // bytes-literal = "0" %x78 %x22 *(HEXDIG HEXDIG) %x22
  if (!match("0x\"")) {
    return std::unexpected(make_error("expected bytes literal"));
  }

  std::vector<std::uint8_t> bytes;
  while (peek() != '"') {
    auto hi = utf8::hex_value(peek());
    if (!hi) {
      return std::unexpected(make_error("expected hex digit"));
    }
    advance();
    auto lo = utf8::hex_value(peek());
    if (!lo) {
      return std::unexpected(make_error("expected hex digit"));
    }
    advance();
    bytes.push_back((*hi << 4) | *lo);
  }
  advance(); // consume "

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = std::move(bytes);
  return expr;
}

// ============================================================================
// Expression Parsers
// ============================================================================

auto Parser::parse() -> std::expected<ExprPtr, ParseError> {
  // complete-dhall-file = *shebang complete-expression [ line-comment-prefix ]

  // Skip shebang lines
  while (peek() == '#' && peek(1) == '!') {
    while (peek() != '\n' && peek() != '\r' && peek() != utf8::END_OF_INPUT) {
      advance();
    }
    if (peek() == '\r')
      advance();
    if (peek() == '\n')
      advance();
  }

  auto result = parse_complete_expression();
  if (!result)
    return result;

  skip_whitespace();

  // Optional trailing line comment
  if (peek() == '-' && peek(1) == '-') {
    skip_line_comment();
  }

  if (peek() != utf8::END_OF_INPUT) {
    return std::unexpected(make_error("unexpected content after expression"));
  }

  return result;
}

auto Parser::parse_expression() -> std::expected<ExprPtr, ParseError> {
  return parse_complete_expression();
}

auto Parser::parse_complete_expression() -> std::expected<ExprPtr, ParseError> {
  // complete-expression = whsp expression whsp
  skip_whitespace();
  auto result = parse_operator_expression(); // Start from the top of precedence
  skip_whitespace();
  return result;
}

auto Parser::parse_operator_expression() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Check for lambda
  if (peek() == '\\' || peek() == 0x03BB) { // λ
    return parse_lambda();
  }

  // Check for forall
  if (match_keyword("forall") || peek() == 0x2200) { // ∀
    if (peek() == 0x2200)
      advance();
    return parse_forall();
  }

  // Check for if
  if (match_keyword("if")) {
    return parse_if();
  }

  // Check for let
  if (peek() == 'l' && peek(1) == 'e' && peek(2) == 't' && !utf8::is_simple_label_next(peek(3))) {
    std::vector<Binding> bindings;
    while (match_keyword("let")) {
      skip_whitespace();
      auto binding = parse_let_binding();
      if (!binding)
        return std::unexpected(binding.error());
      bindings.push_back(std::move(*binding));
      skip_whitespace();
    }

    if (!match_keyword("in")) {
      return std::unexpected(make_error("expected 'in' after let bindings"));
    }
    skip_whitespace();

    auto body = parse_complete_expression();
    if (!body)
      return body;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Let{std::move(bindings), std::move(*body)};
    return expr;
  }

  // Check for merge with type annotation
  if (match_keyword("merge")) {
    return parse_merge();
  }

  // Check for empty list with type
  if (peek() == '[') {
    auto saved = pos_;
    advance();
    skip_whitespace();
    if (peek() == ',' || peek() == ']') {
      pos_ = saved;
      return parse_empty_list();
    }
    pos_ = saved;
  }

  // Check for toMap with type annotation
  if (match_keyword("toMap")) {
    return parse_tomap();
  }

  // Check for assert
  if (match_keyword("assert")) {
    return parse_assert();
  }

  // Parse the first operand
  auto lhs = parse_equivalent_expression();
  if (!lhs)
    return lhs;

  // Check for type annotation: e : T
  skip_whitespace();
  if (peek() == ':') {
    // But not ::
    if (peek(1) == ':') {
      return lhs; // This is completion operator, not annotation
    }
    advance();
    skip_whitespace();
    auto type = parse_complete_expression();
    if (!type)
      return type;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Annot{std::move(*lhs), std::move(*type)};
    return expr;
  }

  // Check for arrow (function type)
  if ((peek() == '-' && peek(1) == '>') || peek() == 0x2192) {
    if (peek() == 0x2192)
      advance();
    else {
      advance();
      advance();
    }
    skip_whitespace();
    auto rhs = parse_complete_expression();
    if (!rhs)
      return rhs;

    // Convert lhs -> rhs to Pi with anonymous parameter
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Pi{"_", std::move(*lhs), std::move(*rhs)};
    return expr;
  }

  return lhs;
}

auto Parser::parse_let_binding() -> std::expected<Binding, ParseError> {
  auto start = pos_;

  auto name = parse_nonreserved_label();
  if (!name)
    return std::unexpected(name.error());

  skip_whitespace();

  std::optional<ExprPtr> type;
  if (peek() == ':') {
    advance();
    skip_whitespace();
    auto t = parse_complete_expression();
    if (!t)
      return std::unexpected(t.error());
    type = std::move(*t);
    skip_whitespace();
  }

  if (auto r = expect('='); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto value = parse_complete_expression();
  if (!value)
    return std::unexpected(value.error());

  return Binding{
      .name = std::move(*name),
      .type = std::move(type),
      .value = std::move(*value),
      .span = SourceSpan{start, pos_, {}},
  };
}

// Binary operator precedence parsers
auto Parser::parse_equivalent_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_import_alt_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    // equivalent = %x2261 / "==="
    if (peek() == 0x2261 || (peek() == '=' && peek(1) == '=' && peek(2) == '=')) {
      auto start = (*lhs)->span.begin;
      if (peek() == 0x2261)
        advance();
      else {
        advance();
        advance();
        advance();
      }
      skip_whitespace();
      auto rhs = parse_import_alt_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Equivalent, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_import_alt_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_or_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '?') {
      auto start = (*lhs)->span.begin;
      advance();
      skip_whitespace();
      auto rhs = parse_or_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::ImportAlt, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_or_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_plus_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '|' && peek(1) == '|') {
      auto start = (*lhs)->span.begin;
      advance();
      advance();
      skip_whitespace();
      auto rhs = parse_plus_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Or, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_plus_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_text_append_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '+' && peek(1) != '+') {
      auto start = (*lhs)->span.begin;
      advance();
      skip_whitespace();
      auto rhs = parse_text_append_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Plus, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_text_append_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_list_append_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '+' && peek(1) == '+') {
      auto start = (*lhs)->span.begin;
      advance();
      advance();
      skip_whitespace();
      auto rhs = parse_list_append_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::TextAppend, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_list_append_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_and_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '#') {
      auto start = (*lhs)->span.begin;
      advance();
      skip_whitespace();
      auto rhs = parse_and_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::ListAppend, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_and_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_combine_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '&' && peek(1) == '&') {
      auto start = (*lhs)->span.begin;
      advance();
      advance();
      skip_whitespace();
      auto rhs = parse_combine_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::And, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_combine_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_prefer_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    // combine = %x2227 / "/\"
    if (peek() == 0x2227 || (peek() == '/' && peek(1) == '\\')) {
      auto start = (*lhs)->span.begin;
      if (peek() == 0x2227)
        advance();
      else {
        advance();
        advance();
      }
      skip_whitespace();
      auto rhs = parse_prefer_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Combine, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_prefer_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_combine_types_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    // prefer = %x2AFD / "//"
    // But not "//\\"
    if (peek() == 0x2AFD || (peek() == '/' && peek(1) == '/' && peek(2) != '\\')) {
      auto start = (*lhs)->span.begin;
      if (peek() == 0x2AFD)
        advance();
      else {
        advance();
        advance();
      }
      skip_whitespace();
      auto rhs = parse_combine_types_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Prefer, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_combine_types_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_times_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    // combine-types = %x2A53 / "//\\"
    if (peek() == 0x2A53 ||
        (peek() == '/' && peek(1) == '/' && peek(2) == '\\' && peek(3) == '\\')) {
      auto start = (*lhs)->span.begin;
      if (peek() == 0x2A53)
        advance();
      else {
        advance();
        advance();
        advance();
        advance();
      }
      skip_whitespace();
      auto rhs = parse_times_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::CombineTypes, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_times_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_equal_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '*') {
      auto start = (*lhs)->span.begin;
      advance();
      skip_whitespace();
      auto rhs = parse_equal_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Times, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_equal_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_not_equal_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '=' && peek(1) == '=' && peek(2) != '=') {
      auto start = (*lhs)->span.begin;
      advance();
      advance();
      skip_whitespace();
      auto rhs = parse_not_equal_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Eq, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_not_equal_expression() -> std::expected<ExprPtr, ParseError> {
  auto lhs = parse_application_expression();
  if (!lhs)
    return lhs;

  while (true) {
    skip_whitespace();
    if (peek() == '!' && peek(1) == '=') {
      auto start = (*lhs)->span.begin;
      advance();
      advance();
      skip_whitespace();
      auto rhs = parse_application_expression();
      if (!rhs)
        return rhs;

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::BinOp{Expr::BinOp::Op::Ne, std::move(*lhs), std::move(*rhs)};
      lhs = std::move(expr);
    } else {
      break;
    }
  }
  return lhs;
}

auto Parser::parse_application_expression() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // first-application-expression: merge, Some, toMap, showConstructor, or import-expression

  // Check for merge (without type annotation - those are caught earlier)
  if (match_keyword("merge")) {
    skip_whitespace();
    auto handler = parse_import_expression();
    if (!handler)
      return handler;
    skip_whitespace();
    auto union_val = parse_import_expression();
    if (!union_val)
      return union_val;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Merge{std::move(*handler), std::move(*union_val), std::nullopt};
    return expr;
  }

  // Check for Some
  if (match_keyword("Some")) {
    skip_whitespace();
    auto value = parse_import_expression();
    if (!value)
      return value;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Some{std::move(*value)};
    return expr;
  }

  // Check for toMap (without type annotation)
  if (match_keyword("toMap")) {
    skip_whitespace();
    auto record = parse_import_expression();
    if (!record)
      return record;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::ToMap{std::move(*record), std::nullopt};
    return expr;
  }

  // Check for showConstructor
  if (match_keyword("showConstructor")) {
    skip_whitespace();
    auto union_val = parse_import_expression();
    if (!union_val)
      return union_val;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::ShowConstructor{std::move(*union_val)};
    return expr;
  }

  // Regular import expression, then optional applications
  auto func = parse_import_expression();
  if (!func)
    return func;

  // Application: func arg1 arg2 ...
  while (true) {
    skip_whitespace();
    // Need whitespace before next argument
    auto saved = pos_;

    // Try to parse another import expression
    auto arg = parse_import_expression();
    if (!arg) {
      pos_ = saved; // backtrack
      break;
    }

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::App{std::move(*func), std::move(*arg)};
    func = std::move(expr);
  }

  return func;
}

auto Parser::parse_import_expression() -> std::expected<ExprPtr, ParseError> {
  // import-expression = import / completion-expression

  // Try to parse import
  auto saved = pos_;

  // Check for import indicators
  if (peek() == '.' || peek() == '/' || peek() == '~' ||
      (peek() == 'h' && peek(1) == 't' && peek(2) == 't' && peek(3) == 'p') ||
      (peek() == 'e' && peek(1) == 'n' && peek(2) == 'v' && peek(3) == ':') ||
      match_keyword("missing")) {
    auto imp = parse_import();
    if (imp)
      return imp;
    // Fall through to completion-expression
    pos_ = saved;
  }

  return parse_completion_expression();
}

auto Parser::parse_completion_expression() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;
  auto lhs = parse_selector_expression();
  if (!lhs)
    return lhs;

  skip_whitespace();
  // completion = "::"
  if (peek() == ':' && peek(1) == ':') {
    advance();
    advance();
    skip_whitespace();
    auto rhs = parse_selector_expression();
    if (!rhs)
      return rhs;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::Completion{std::move(*lhs), std::move(*rhs)};
    return expr;
  }

  return lhs;
}

auto Parser::parse_selector_expression() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;
  auto base = parse_primitive_expression();
  if (!base)
    return base;

  while (true) {
    skip_whitespace();
    if (peek() != '.')
      break;

    // Could be field access, projection, or type selector
    // But need to distinguish from ./ path!
    if (peek(1) == '/')
      break;

    advance(); // consume .
    skip_whitespace();

    if (peek() == '{') {
      // Projection by labels: .{ x, y, z }
      advance(); // consume {
      skip_whitespace();

      std::vector<std::string> fields;
      if (peek() == ',') {
        advance();
        skip_whitespace();
      }

      if (peek() != '}') {
        auto label = parse_any_label();
        if (!label)
          return std::unexpected(label.error());
        fields.push_back(std::move(*label));
        skip_whitespace();

        while (peek() == ',') {
          advance();
          skip_whitespace();
          if (peek() == '}')
            break; // trailing comma
          label = parse_any_label();
          if (!label)
            return std::unexpected(label.error());
          fields.push_back(std::move(*label));
          skip_whitespace();
        }
      }

      if (auto r = expect('}'); !r)
        return std::unexpected(r.error());

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::Project{std::move(*base), std::move(fields)};
      base = std::move(expr);
    } else if (peek() == '(') {
      // Projection by type: .(T)
      advance(); // consume (
      skip_whitespace();
      auto type = parse_complete_expression();
      if (!type)
        return type;
      skip_whitespace();
      if (auto r = expect(')'); !r)
        return std::unexpected(r.error());

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::ProjectType{std::move(*base), std::move(*type)};
      base = std::move(expr);
    } else {
      // Field access: .field
      auto label = parse_any_label();
      if (!label)
        return std::unexpected(label.error());

      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::Field{std::move(*base), std::move(*label)};
      base = std::move(expr);
    }
  }

  return base;
}

auto Parser::parse_primitive_expression() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // temporal-literal, double-literal, natural-literal, integer-literal
  // (these all start with digits or +/-)

  // Check for temporal or numeric literal
  auto cp = peek();
  if (utf8::is_digit(cp) || cp == '+' || cp == '-') {
    // Could be temporal, double, natural, or integer
    // Need lookahead to distinguish

    // Check for date: YYYY-MM-DD
    if (utf8::is_digit(cp) && utf8::is_digit(peek(1)) && utf8::is_digit(peek(2)) &&
        utf8::is_digit(peek(3)) && peek(4) == '-') {
      return parse_temporal_literal();
    }

    // Check for time: HH:MM:SS
    if (utf8::is_digit(cp) && utf8::is_digit(peek(1)) && peek(2) == ':') {
      return parse_temporal_literal();
    }

    // Check for timezone: +/-HH:MM
    if ((cp == '+' || cp == '-') && utf8::is_digit(peek(1)) && utf8::is_digit(peek(2)) &&
        peek(3) == ':') {
      return parse_temporal_literal();
    }

    // Integer starts with + or -
    if (cp == '+' || cp == '-') {
      // Check if it's a double (has decimal or exponent)
      auto saved = pos_;
      advance(); // skip sign
      while (utf8::is_digit(peek()))
        advance();
      if (peek() == '.' || peek() == 'e' || peek() == 'E') {
        pos_ = saved;
        return parse_double();
      }
      pos_ = saved;
      return parse_integer();
    }

    // Natural starts with digit
    // Check if it's a double
    auto saved = pos_;
    while (utf8::is_digit(peek()))
      advance();
    if (peek() == '.' || peek() == 'e' || peek() == 'E') {
      pos_ = saved;
      return parse_double();
    }
    pos_ = saved;
    return parse_natural();
  }

  // NaN
  if (match_keyword("NaN")) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = std::nan("");
    return expr;
  }

  // Infinity
  if (match_keyword("Infinity")) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = std::numeric_limits<double>::infinity();
    return expr;
  }

  // Text literal
  if (cp == '"' || (cp == '\'' && peek(1) == '\'')) {
    return parse_text_literal();
  }

  // Bytes literal
  if (cp == '0' && peek(1) == 'x' && peek(2) == '"') {
    return parse_bytes_literal();
  }

  // Record: { ... }
  if (cp == '{') {
    return parse_record();
  }

  // Union: < ... >
  if (cp == '<') {
    return parse_union();
  }

  // List: [ ... ]
  if (cp == '[') {
    return parse_list();
  }

  // Parenthesized expression
  if (cp == '(') {
    advance();
    auto inner = parse_complete_expression();
    if (!inner)
      return inner;
    if (auto r = expect(')'); !r)
      return std::unexpected(r.error());
    return inner;
  }

  // Identifier (variable or builtin)
  return parse_identifier();
}

auto Parser::parse_identifier() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  auto label = parse_label();
  if (!label)
    return std::unexpected(label.error());

  // Check if it's a builtin
  if (is_builtin(*label)) {
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};

    // Map builtin name to enum
    Expr::Builtin::Name name;
    if (*label == "Bool")
      name = Expr::Builtin::Name::Bool;
    else if (*label == "Natural")
      name = Expr::Builtin::Name::Natural;
    else if (*label == "Integer")
      name = Expr::Builtin::Name::Integer;
    else if (*label == "Double")
      name = Expr::Builtin::Name::Double;
    else if (*label == "Text")
      name = Expr::Builtin::Name::Text;
    else if (*label == "Bytes")
      name = Expr::Builtin::Name::Bytes;
    else if (*label == "Date")
      name = Expr::Builtin::Name::Date;
    else if (*label == "Time")
      name = Expr::Builtin::Name::Time;
    else if (*label == "TimeZone")
      name = Expr::Builtin::Name::TimeZone;
    else if (*label == "List")
      name = Expr::Builtin::Name::List;
    else if (*label == "Optional")
      name = Expr::Builtin::Name::Optional;
    else if (*label == "Type")
      name = Expr::Builtin::Name::Type;
    else if (*label == "Kind")
      name = Expr::Builtin::Name::Kind;
    else if (*label == "Sort")
      name = Expr::Builtin::Name::Sort;
    else if (*label == "True")
      name = Expr::Builtin::Name::True;
    else if (*label == "False")
      name = Expr::Builtin::Name::False;
    else if (*label == "None")
      name = Expr::Builtin::Name::None;
    else if (*label == "Natural/fold")
      name = Expr::Builtin::Name::NaturalFold;
    else if (*label == "Natural/build")
      name = Expr::Builtin::Name::NaturalBuild;
    else if (*label == "Natural/isZero")
      name = Expr::Builtin::Name::NaturalIsZero;
    else if (*label == "Natural/even")
      name = Expr::Builtin::Name::NaturalEven;
    else if (*label == "Natural/odd")
      name = Expr::Builtin::Name::NaturalOdd;
    else if (*label == "Natural/toInteger")
      name = Expr::Builtin::Name::NaturalToInteger;
    else if (*label == "Natural/show")
      name = Expr::Builtin::Name::NaturalShow;
    else if (*label == "Natural/subtract")
      name = Expr::Builtin::Name::NaturalSubtract;
    else if (*label == "Integer/toDouble")
      name = Expr::Builtin::Name::IntegerToDouble;
    else if (*label == "Integer/show")
      name = Expr::Builtin::Name::IntegerShow;
    else if (*label == "Integer/negate")
      name = Expr::Builtin::Name::IntegerNegate;
    else if (*label == "Integer/clamp")
      name = Expr::Builtin::Name::IntegerClamp;
    else if (*label == "Double/show")
      name = Expr::Builtin::Name::DoubleShow;
    else if (*label == "List/build")
      name = Expr::Builtin::Name::ListBuild;
    else if (*label == "List/fold")
      name = Expr::Builtin::Name::ListFold;
    else if (*label == "List/length")
      name = Expr::Builtin::Name::ListLength;
    else if (*label == "List/head")
      name = Expr::Builtin::Name::ListHead;
    else if (*label == "List/last")
      name = Expr::Builtin::Name::ListLast;
    else if (*label == "List/indexed")
      name = Expr::Builtin::Name::ListIndexed;
    else if (*label == "List/reverse")
      name = Expr::Builtin::Name::ListReverse;
    else if (*label == "Text/show")
      name = Expr::Builtin::Name::TextShow;
    else if (*label == "Text/replace")
      name = Expr::Builtin::Name::TextReplace;
    else if (*label == "Date/show")
      name = Expr::Builtin::Name::DateShow;
    else if (*label == "Time/show")
      name = Expr::Builtin::Name::TimeShow;
    else if (*label == "TimeZone/show")
      name = Expr::Builtin::Name::TimeZoneShow;
    else {
      return std::unexpected(make_error("unknown builtin: " + *label));
    }

    expr->data = Expr::Builtin{name};
    return expr;
  }

  // It's a variable
  std::uint64_t index = 0;
  skip_whitespace();
  if (peek() == '@') {
    advance();
    skip_whitespace();
    auto nat = parse_natural();
    if (!nat)
      return nat;
    index = std::get<std::uint64_t>((*nat)->data);
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::Variable{std::move(*label), index};
  return expr;
}

auto Parser::parse_lambda() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched \ or λ
  if (peek() == '\\')
    advance();
  else if (peek() == 0x03BB)
    advance();

  skip_whitespace();
  if (auto r = expect('('); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto param = parse_nonreserved_label();
  if (!param)
    return std::unexpected(param.error());

  skip_whitespace();
  if (auto r = expect(':'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto type = parse_complete_expression();
  if (!type)
    return type;

  skip_whitespace();
  if (auto r = expect(')'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  // arrow = %x2192 / "->"
  if (peek() == 0x2192) {
    advance();
  } else if (peek() == '-' && peek(1) == '>') {
    advance();
    advance();
  } else {
    return std::unexpected(make_error("expected '->' or '→'"));
  }
  skip_whitespace();

  auto body = parse_complete_expression();
  if (!body)
    return body;

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::Lambda{std::move(*param), std::move(*type), std::move(*body)};
  return expr;
}

auto Parser::parse_forall() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched 'forall' or ∀
  skip_whitespace();
  if (auto r = expect('('); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto param = parse_nonreserved_label();
  if (!param)
    return std::unexpected(param.error());

  skip_whitespace();
  if (auto r = expect(':'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto type = parse_complete_expression();
  if (!type)
    return type;

  skip_whitespace();
  if (auto r = expect(')'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  // arrow
  if (peek() == 0x2192) {
    advance();
  } else if (peek() == '-' && peek(1) == '>') {
    advance();
    advance();
  } else {
    return std::unexpected(make_error("expected '->' or '→'"));
  }
  skip_whitespace();

  auto body = parse_complete_expression();
  if (!body)
    return body;

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::Pi{std::move(*param), std::move(*type), std::move(*body)};
  return expr;
}

auto Parser::parse_if() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched 'if'
  skip_whitespace();
  auto cond = parse_complete_expression();
  if (!cond)
    return cond;

  skip_whitespace();
  if (!match_keyword("then")) {
    return std::unexpected(make_error("expected 'then'"));
  }
  skip_whitespace();

  auto then_branch = parse_complete_expression();
  if (!then_branch)
    return then_branch;

  skip_whitespace();
  if (!match_keyword("else")) {
    return std::unexpected(make_error("expected 'else'"));
  }
  skip_whitespace();

  auto else_branch = parse_complete_expression();
  if (!else_branch)
    return else_branch;

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::If{std::move(*cond), std::move(*then_branch), std::move(*else_branch)};
  return expr;
}

auto Parser::parse_merge() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched 'merge'
  skip_whitespace();
  auto handler = parse_import_expression();
  if (!handler)
    return handler;

  skip_whitespace();
  auto union_val = parse_import_expression();
  if (!union_val)
    return union_val;

  skip_whitespace();
  std::optional<ExprPtr> type;
  if (peek() == ':') {
    advance();
    skip_whitespace();
    auto t = parse_complete_expression();
    if (!t)
      return t;
    type = std::move(*t);
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::Merge{std::move(*handler), std::move(*union_val), std::move(type)};
  return expr;
}

auto Parser::parse_assert() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched 'assert'
  skip_whitespace();
  if (auto r = expect(':'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto type = parse_complete_expression();
  if (!type)
    return type;

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::Assert{std::move(*type)};
  return expr;
}

auto Parser::parse_empty_list() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  if (auto r = expect('['); !r)
    return std::unexpected(r.error());
  skip_whitespace();
  if (peek() == ',') {
    advance();
    skip_whitespace();
  }
  if (auto r = expect(']'); !r)
    return std::unexpected(r.error());
  skip_whitespace();
  if (auto r = expect(':'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  auto type = parse_complete_expression();
  if (!type)
    return type;

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::ListLit{std::move(*type), {}};
  return expr;
}

auto Parser::parse_tomap() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // Already matched 'toMap'
  skip_whitespace();
  auto record = parse_import_expression();
  if (!record)
    return record;

  skip_whitespace();
  std::optional<ExprPtr> type;
  if (peek() == ':') {
    advance();
    skip_whitespace();
    auto t = parse_complete_expression();
    if (!t)
      return t;
    type = std::move(*t);
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::ToMap{std::move(*record), std::move(type)};
  return expr;
}

auto Parser::parse_record() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  if (auto r = expect('{'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  // Optional leading comma
  if (peek() == ',') {
    advance();
    skip_whitespace();
  }

  // Check for empty record literal: { = }
  if (peek() == '=') {
    advance();
    skip_whitespace();
    if (peek() == ',') {
      advance();
      skip_whitespace();
    }
    if (auto r = expect('}'); !r)
      return std::unexpected(r.error());

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::RecordLit{{}};
    return expr;
  }

  // Check for empty record type: { }
  if (peek() == '}') {
    advance();
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::RecordType{{}};
    return expr;
  }

  // Parse first entry to determine if this is a type or literal
  auto first_label = parse_any_label();
  if (!first_label)
    return std::unexpected(first_label.error());

  skip_whitespace();

  // Check if this is a record type (has :) or literal (has = or .)
  if (peek() == ':') {
    // Record type
    advance();
    skip_whitespace();
    auto first_type = parse_complete_expression();
    if (!first_type)
      return first_type;

    std::vector<std::pair<std::string, ExprPtr>> fields;
    fields.emplace_back(std::move(*first_label), std::move(*first_type));

    skip_whitespace();
    while (peek() == ',') {
      advance();
      skip_whitespace();
      if (peek() == '}')
        break; // trailing comma

      auto label = parse_any_label();
      if (!label)
        return std::unexpected(label.error());
      skip_whitespace();
      if (auto r = expect(':'); !r)
        return std::unexpected(r.error());
      skip_whitespace();
      auto type = parse_complete_expression();
      if (!type)
        return type;
      fields.emplace_back(std::move(*label), std::move(*type));
      skip_whitespace();
    }

    if (auto r = expect('}'); !r)
      return std::unexpected(r.error());

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::RecordType{std::move(fields)};
    return expr;
  }

  // Record literal
  std::vector<RecordEntry> entries;

  // Parse first entry
  std::vector<std::string> path;
  while (peek() == '.') {
    advance();
    skip_whitespace();
    auto nested = parse_any_label();
    if (!nested)
      return std::unexpected(nested.error());
    path.push_back(std::move(*nested));
    skip_whitespace();
  }

  ExprPtr first_value;
  if (peek() == '=' || !path.empty()) {
    if (auto r = expect('='); !r)
      return std::unexpected(r.error());
    skip_whitespace();
    auto v = parse_complete_expression();
    if (!v)
      return v;
    first_value = std::move(*v);
  } else {
    // Pun: { x } means { x = x }
    auto var = std::make_unique<Expr>();
    var->span = SourceSpan{start, pos_, {}};
    var->data = Expr::Variable{*first_label, 0};
    first_value = std::move(var);
  }

  entries.push_back(RecordEntry{
      std::move(*first_label),
      std::move(path),
      std::move(first_value),
  });

  skip_whitespace();
  while (peek() == ',') {
    advance();
    skip_whitespace();
    if (peek() == '}')
      break; // trailing comma

    auto label = parse_any_label();
    if (!label)
      return std::unexpected(label.error());
    skip_whitespace();

    std::vector<std::string> entry_path;
    while (peek() == '.') {
      advance();
      skip_whitespace();
      auto nested = parse_any_label();
      if (!nested)
        return std::unexpected(nested.error());
      entry_path.push_back(std::move(*nested));
      skip_whitespace();
    }

    ExprPtr value;
    if (peek() == '=' || !entry_path.empty()) {
      if (auto r = expect('='); !r)
        return std::unexpected(r.error());
      skip_whitespace();
      auto v = parse_complete_expression();
      if (!v)
        return v;
      value = std::move(*v);
    } else {
      // Pun
      auto var = std::make_unique<Expr>();
      var->span = SourceSpan{start, pos_, {}};
      var->data = Expr::Variable{*label, 0};
      value = std::move(var);
    }

    entries.push_back(RecordEntry{
        std::move(*label),
        std::move(entry_path),
        std::move(value),
    });

    skip_whitespace();
  }

  if (auto r = expect('}'); !r)
    return std::unexpected(r.error());

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::RecordLit{std::move(entries)};
  return expr;
}

auto Parser::parse_union() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  if (auto r = expect('<'); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  // Optional leading |
  if (peek() == '|') {
    advance();
    skip_whitespace();
  }

  std::vector<UnionAlt> alternatives;

  // Check for empty union
  if (peek() == '>') {
    advance();
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::UnionType{{}};
    return expr;
  }

  // Parse alternatives
  auto label = parse_any_label();
  if (!label)
    return std::unexpected(label.error());

  skip_whitespace();
  std::optional<ExprPtr> type;
  if (peek() == ':') {
    advance();
    skip_whitespace();
    auto t = parse_complete_expression();
    if (!t)
      return t;
    type = std::move(*t);
    skip_whitespace();
  }
  alternatives.push_back(UnionAlt{std::move(*label), std::move(type)});

  while (peek() == '|') {
    advance();
    skip_whitespace();
    if (peek() == '>')
      break; // trailing |

    label = parse_any_label();
    if (!label)
      return std::unexpected(label.error());

    skip_whitespace();
    type.reset();
    if (peek() == ':') {
      advance();
      skip_whitespace();
      auto t = parse_complete_expression();
      if (!t)
        return t;
      type = std::move(*t);
      skip_whitespace();
    }
    alternatives.push_back(UnionAlt{std::move(*label), std::move(type)});
  }

  if (auto r = expect('>'); !r)
    return std::unexpected(r.error());

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::UnionType{std::move(alternatives)};
  return expr;
}

auto Parser::parse_list() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  if (auto r = expect('['); !r)
    return std::unexpected(r.error());
  skip_whitespace();

  // Optional leading comma
  if (peek() == ',') {
    advance();
    skip_whitespace();
  }

  // Check for empty list (handled by parse_empty_list for [] : T)
  if (peek() == ']') {
    // This shouldn't happen here - empty lists need type annotation
    return std::unexpected(make_error("empty list requires type annotation: [] : T"));
  }

  std::vector<ExprPtr> elements;
  auto first = parse_complete_expression();
  if (!first)
    return first;
  elements.push_back(std::move(*first));

  skip_whitespace();
  while (peek() == ',') {
    advance();
    skip_whitespace();
    if (peek() == ']')
      break; // trailing comma

    auto elem = parse_complete_expression();
    if (!elem)
      return elem;
    elements.push_back(std::move(*elem));
    skip_whitespace();
  }

  if (auto r = expect(']'); !r)
    return std::unexpected(r.error());

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::ListLit{std::nullopt, std::move(elements)};
  return expr;
}

auto Parser::parse_import() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;
  Import import;

  // import-type = missing / local / http / env

  if (match_keyword("missing")) {
    import.type = MissingImport{};
  } else if (peek() == '.' || peek() == '/' || peek() == '~') {
    // Local import
    LocalImport local;

    if (match("..")) {
      local.type = LocalImport::Type::Parent;
    } else if (peek() == '.') {
      advance();
      local.type = LocalImport::Type::Here;
    } else if (peek() == '~') {
      advance();
      local.type = LocalImport::Type::Home;
    } else {
      local.type = LocalImport::Type::Absolute;
    }

    // Parse path components
    while (peek() == '/') {
      advance();
      std::string component;

      if (peek() == '"') {
        // Quoted path component
        advance();
        while (peek() != '"' && peek() != utf8::END_OF_INPUT) {
          // Simplified - real impl needs proper quoted-path-char handling
          char buf[4];
          auto len = utf8::encode(peek(), buf);
          component.append(buf, len);
          advance();
        }
        if (auto r = expect('"'); !r)
          return std::unexpected(r.error());
      } else {
        // Unquoted path component
        while (utf8::is_path_char(peek())) {
          char buf[4];
          auto len = utf8::encode(peek(), buf);
          component.append(buf, len);
          advance();
        }
      }

      if (component.empty()) {
        return std::unexpected(make_error("expected path component"));
      }
      local.path.push_back(std::move(component));
    }

    import.type = std::move(local);
  } else if (match("http://") || match("https://")) {
    // HTTP import
    RemoteImport remote;
    remote.scheme = source_.substr(start.offset, pos_.offset - start.offset - 3);

    // Parse authority and path (simplified)
    std::string authority;
    while (peek() != '/' && peek() != '?' && peek() != utf8::END_OF_INPUT && peek() != ' ' &&
           peek() != '\t' && peek() != '\n') {
      char buf[4];
      auto len = utf8::encode(peek(), buf);
      authority.append(buf, len);
      advance();
    }
    remote.authority = std::move(authority);

    // Parse path
    while (peek() == '/') {
      advance();
      std::string component;
      while (peek() != '/' && peek() != '?' && peek() != utf8::END_OF_INPUT && peek() != ' ' &&
             peek() != '\t' && peek() != '\n') {
        char buf[4];
        auto len = utf8::encode(peek(), buf);
        component.append(buf, len);
        advance();
      }
      remote.path.push_back(std::move(component));
    }

    // Parse query
    if (peek() == '?') {
      advance();
      std::string query;
      while (peek() != utf8::END_OF_INPUT && peek() != ' ' && peek() != '\t' && peek() != '\n') {
        char buf[4];
        auto len = utf8::encode(peek(), buf);
        query.append(buf, len);
        advance();
      }
      remote.query = std::move(query);
    }

    // Check for 'using'
    skip_whitespace();
    if (match_keyword("using")) {
      skip_whitespace();
      auto headers = parse_import_expression();
      if (!headers)
        return headers;
      remote.headers = std::move(*headers);
    }

    import.type = std::move(remote);
  } else if (match("env:")) {
    // Environment variable import
    EnvImport env;

    if (peek() == '"') {
      // Quoted POSIX env var
      advance();
      while (peek() != '"' && peek() != utf8::END_OF_INPUT) {
        // Handle escape sequences
        if (peek() == '\\') {
          advance();
          switch (peek()) {
            case '"':
              env.variable += '"';
              break;
            case '\\':
              env.variable += '\\';
              break;
            case 'a':
              env.variable += '\a';
              break;
            case 'b':
              env.variable += '\b';
              break;
            case 'f':
              env.variable += '\f';
              break;
            case 'n':
              env.variable += '\n';
              break;
            case 'r':
              env.variable += '\r';
              break;
            case 't':
              env.variable += '\t';
              break;
            case 'v':
              env.variable += '\v';
              break;
            default:
              return std::unexpected(make_error("invalid escape in env var"));
          }
          advance();
        } else {
          char buf[4];
          auto len = utf8::encode(peek(), buf);
          env.variable.append(buf, len);
          advance();
        }
      }
      if (auto r = expect('"'); !r)
        return std::unexpected(r.error());
    } else {
      // Bash-style env var
      while (utf8::is_alpha(peek()) || utf8::is_digit(peek()) || peek() == '_') {
        char buf[4];
        auto len = utf8::encode(peek(), buf);
        env.variable.append(buf, len);
        advance();
      }
    }

    if (env.variable.empty()) {
      return std::unexpected(make_error("expected environment variable name"));
    }

    import.type = std::move(env);
  } else {
    return std::unexpected(make_error("expected import"));
  }

  // Check for hash
  skip_whitespace();
  if (match("sha256:")) {
    Hash hash;
    for (int i = 0; i < 64; i++) {
      auto v = utf8::hex_value(peek());
      if (!v) {
        return std::unexpected(make_error("expected 64 hex digits after sha256:"));
      }
      hash.sha256[i / 2] = (i % 2 == 0) ? (*v << 4) : (hash.sha256[i / 2] | *v);
      advance();
    }
    import.hash = hash;
  }

  // Check for import mode (as Text/Location/Bytes)
  skip_whitespace();
  if (match_keyword("as")) {
    skip_whitespace();
    if (match_keyword("Text")) {
      import.mode = ImportMode::RawText;
    } else if (match_keyword("Location")) {
      import.mode = ImportMode::Location;
    } else if (match_keyword("Bytes")) {
      import.mode = ImportMode::RawBytes;
    } else {
      return std::unexpected(make_error("expected Text, Location, or Bytes after 'as'"));
    }
  }

  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = std::move(import);
  return expr;
}

auto Parser::parse_temporal_literal() -> std::expected<ExprPtr, ParseError> {
  auto start = pos_;

  // This is complex - need to handle all combinations:
  // - YYYY-MM-DD
  // - YYYY-MM-DDThh:mm:ss
  // - YYYY-MM-DDThh:mm:ss+HH:MM
  // - hh:mm:ss
  // - hh:mm:ss+HH:MM
  // - +HH:MM or -HH:MM (timezone only)

  // Check for standalone timezone (+/- followed by HH:MM)
  if ((peek() == '+' || peek() == '-') && utf8::is_digit(peek(1)) && utf8::is_digit(peek(2)) &&
      peek(3) == ':') {
    bool negative = peek() == '-';
    advance();

    int hour = (peek() - '0') * 10 + (peek() - '0');
    advance();
    advance();

    if (auto r = expect(':'); !r)
      return std::unexpected(r.error());

    int minute = (peek() - '0') * 10 + (peek() - '0');
    advance();
    advance();

    int total_minutes = hour * 60 + minute;
    if (negative)
      total_minutes = -total_minutes;

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::TimeZoneLiteral{total_minutes};
    return expr;
  }

  // Check if this starts with time (HH:MM:SS)
  if (utf8::is_digit(peek()) && utf8::is_digit(peek(1)) && peek(2) == ':') {
    // Parse time
    int hour = (peek() - '0') * 10;
    advance();
    hour += peek() - '0';
    advance();

    if (auto r = expect(':'); !r)
      return std::unexpected(r.error());

    int minute = (peek() - '0') * 10;
    advance();
    minute += peek() - '0';
    advance();

    if (auto r = expect(':'); !r)
      return std::unexpected(r.error());

    int second = (peek() - '0') * 10;
    advance();
    second += peek() - '0';
    advance();

    int nanoseconds = 0;
    if (peek() == '.') {
      advance();
      int scale = 100000000; // 10^8
      while (utf8::is_digit(peek())) {
        nanoseconds += (peek() - '0') * scale;
        scale /= 10;
        advance();
      }
    }

    // Check for timezone
    if (peek() == 'Z' || peek() == '+' || peek() == '-') {
      int tz_minutes = 0;
      if (peek() == 'Z') {
        advance();
        tz_minutes = 0;
      } else {
        bool negative = peek() == '-';
        advance();
        int tz_hour = (peek() - '0') * 10 + (peek() - '0');
        advance();
        advance();
        if (auto r = expect(':'); !r)
          return std::unexpected(r.error());
        int tz_min = (peek() - '0') * 10 + (peek() - '0');
        advance();
        advance();
        tz_minutes = tz_hour * 60 + tz_min;
        if (negative)
          tz_minutes = -tz_minutes;
      }

      // Return { time, timeZone } record
      // For simplicity, we'll represent this as a Time with timezone embedded
      // (In a full impl, this would be a record type)
      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::TimeLiteral{hour, minute, second, nanoseconds};
      return expr;
    }

    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::TimeLiteral{hour, minute, second, nanoseconds};
    return expr;
  }

  // Parse date: YYYY-MM-DD
  int year = 0;
  for (int i = 0; i < 4; i++) {
    if (!utf8::is_digit(peek())) {
      return std::unexpected(make_error("expected 4-digit year"));
    }
    year = year * 10 + (peek() - '0');
    advance();
  }

  if (auto r = expect('-'); !r)
    return std::unexpected(r.error());

  int month = (peek() - '0') * 10;
  advance();
  month += peek() - '0';
  advance();

  if (auto r = expect('-'); !r)
    return std::unexpected(r.error());

  int day = (peek() - '0') * 10;
  advance();
  day += peek() - '0';
  advance();

  // Check for time part
  if (peek() == 'T' || peek() == 't') {
    advance();
    // Parse time
    int hour = (peek() - '0') * 10;
    advance();
    hour += peek() - '0';
    advance();

    if (auto r = expect(':'); !r)
      return std::unexpected(r.error());

    int minute = (peek() - '0') * 10;
    advance();
    minute += peek() - '0';
    advance();

    if (auto r = expect(':'); !r)
      return std::unexpected(r.error());

    int second = (peek() - '0') * 10;
    advance();
    second += peek() - '0';
    advance();

    int nanoseconds = 0;
    if (peek() == '.') {
      advance();
      int scale = 100000000;
      while (utf8::is_digit(peek())) {
        nanoseconds += (peek() - '0') * scale;
        scale /= 10;
        advance();
      }
    }

    // Check for timezone
    if (peek() == 'Z' || peek() == '+' || peek() == '-') {
      // Has timezone - return { date, time, timeZone }
      // For simplicity, just return date for now
      auto expr = std::make_unique<Expr>();
      expr->span = SourceSpan{start, pos_, {}};
      expr->data = Expr::DateLiteral{year, month, day};
      return expr;
    }

    // Return { date, time }
    auto expr = std::make_unique<Expr>();
    expr->span = SourceSpan{start, pos_, {}};
    expr->data = Expr::DateLiteral{year, month, day};
    return expr;
  }

  // Just date
  auto expr = std::make_unique<Expr>();
  expr->span = SourceSpan{start, pos_, {}};
  expr->data = Expr::DateLiteral{year, month, day};
  return expr;
}

// ============================================================================
// Hash implementation
// ============================================================================

auto Hash::parse(std::string_view s) -> std::optional<Hash> {
  if (!s.starts_with("sha256:"))
    return std::nullopt;
  s.remove_prefix(7);
  if (s.size() != 64)
    return std::nullopt;

  Hash hash;
  for (std::size_t i = 0; i < 64; i += 2) {
    auto hi = utf8::hex_value(s[i]);
    auto lo = utf8::hex_value(s[i + 1]);
    if (!hi || !lo)
      return std::nullopt;
    hash.sha256[i / 2] = (*hi << 4) | *lo;
  }
  return hash;
}

auto Hash::to_string() const -> std::string {
  std::string result = "sha256:";
  result.reserve(71);
  for (auto byte : sha256) {
    result += utf8::to_hex_char(byte >> 4);
    result += utf8::to_hex_char(byte & 0xF);
  }
  return result;
}

} // namespace continuity::codec
