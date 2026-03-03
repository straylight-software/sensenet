// Continuity.Codec - C++23 Dhall Interpreter
//
// LL(k) parser for the Dhall configuration language.
// Based on the libevring prelude type system.
//
// Design goals:
//   - Zero runtime dependencies (header-only where possible)
//   - Minimal power: LL(k) not PEG, no arbitrary backtracking
//   - Direct correspondence with dhall.abnf grammar
//   - UTF-8 native, no ICU dependency
//   - Content-addressed imports via evring Hash type
//
// straylight.software - 2026

#pragma once

#include <cstdint>
#include <expected>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace continuity::codec {

// ============================================================================
// Source Location Tracking
// ============================================================================

struct SourcePos {
  std::size_t line = 1;
  std::size_t column = 1;
  std::size_t offset = 0; // byte offset

  constexpr auto operator<=>(const SourcePos&) const = default;
};

struct SourceSpan {
  SourcePos begin;
  SourcePos end;
  std::string_view text; // The actual source text
};

// ============================================================================
// Hash Type (mirrors evring/Toolchain.dhall Hash)
// ============================================================================

struct Hash {
  std::array<std::uint8_t, 32> sha256;

  constexpr auto operator<=>(const Hash&) const = default;

  // Parse from "sha256:HEXDIGITS"
  static auto parse(std::string_view s) -> std::optional<Hash>;

  // Render to "sha256:HEXDIGITS"
  [[nodiscard]] auto to_string() const -> std::string;
};

// ============================================================================
// Import Types
// ============================================================================

enum class ImportMode {
  Code,     // Normal expression import
  RawText,  // Import as Text literal
  Location, // Import as Location
  RawBytes, // Import as Bytes literal
};

struct LocalImport {
  enum class Type { Here, Parent, Home, Absolute };
  Type type;
  std::vector<std::string> path;
};

struct RemoteImport {
  std::string scheme; // "http" or "https"
  std::string authority;
  std::vector<std::string> path;
  std::optional<std::string> query;
  std::optional<std::unique_ptr<struct Expr>> headers; // using keyword
};

struct EnvImport {
  std::string variable;
};

struct MissingImport {};

using ImportType = std::variant<LocalImport, RemoteImport, EnvImport, MissingImport>;

struct Import {
  ImportType type;
  std::optional<Hash> hash; // Content-addressed
  ImportMode mode = ImportMode::Code;
};

// ============================================================================
// Expression AST (mirrors Dhall core syntax)
// ============================================================================

// Forward declarations for recursive types
struct Expr;
using ExprPtr = std::unique_ptr<Expr>;

// Binding in let expression: let name : type = value
struct Binding {
  std::string name;
  std::optional<ExprPtr> type;
  ExprPtr value;
  SourceSpan span;
};

// Record literal entry: { name = value } or { name } (pun)
struct RecordEntry {
  std::string name;
  std::vector<std::string> path; // For nested: { a.b.c = x }
  ExprPtr value;
};

// Union alternative: < Name : Type > or < Name >
struct UnionAlt {
  std::string name;
  std::optional<ExprPtr> type;
};

// Chunk of a text literal (either literal text or interpolation)
struct TextChunk {
  std::variant<std::string, ExprPtr> content;
};

// The core expression type
struct Expr {
  SourceSpan span;

  // All expression variants
  std::variant <
      // Literals
      bool,                      // Bool literal
      std::uint64_t,             // Natural literal
      std::int64_t,              // Integer literal
      double,                    // Double literal
      std::vector<TextChunk>,    // Text literal (with interpolation)
      std::vector<std::uint8_t>, // Bytes literal

      // Temporal literals
      struct DateLiteral {
    int year;
    int month;
    int day;
  }, struct TimeLiteral {
    int hour;
    int minute;
    int second;
    int nanoseconds;
  }, struct TimeZoneLiteral {
    int minutes;
  },

      // Variable: name@index
      struct Variable {
    std::string name;
    std::uint64_t index;
  },

      // Lambda: \(x : A) -> b
      struct Lambda {
    std::string param;
    ExprPtr type;
    ExprPtr body;
  },

      // Pi/forall: forall (x : A) -> B
      struct Pi {
    std::string param;
    ExprPtr type;
    ExprPtr body;
  },

      // Application: f x
      struct App {
    ExprPtr func;
    ExprPtr arg;
  },

      // Let: let x : T = e in body
      struct Let {
    std::vector<Binding> bindings;
    ExprPtr body;
  },

      // Annotation: e : T
      struct Annot {
    ExprPtr expr;
    ExprPtr type;
  },

      // If-then-else
      struct If {
    ExprPtr cond;
    ExprPtr then_branch;
    ExprPtr else_branch;
  },

      // Merge: merge handler union : T
      struct Merge {
    ExprPtr handler;
    ExprPtr union_val;
    std::optional<ExprPtr> type;
  },

      // toMap: toMap record : T
      struct ToMap {
    ExprPtr record;
    std::optional<ExprPtr> type;
  },

      // showConstructor: showConstructor union
      struct ShowConstructor {
    ExprPtr union_val;
  },

      // Assert: assert : T
      struct Assert {
    ExprPtr type;
  },

      // With: e with path = value
      struct With {
    ExprPtr base;
    std::vector<std::string> path; // "?" is encoded as special string
    ExprPtr value;
  },

      // Field access: record.field
      struct Field {
    ExprPtr record;
    std::string field;
  },

      // Projection: record.{ field1, field2 }
      struct Project {
    ExprPtr record;
    std::vector<std::string> fields;
  },

      // Projection by type: record.(T)
      struct ProjectType {
    ExprPtr record;
    ExprPtr type;
  },

      // Completion: T::r
      struct Completion {
    ExprPtr type;
    ExprPtr record;
  },

      // Record literal: { x = 1, y = 2 }
      struct RecordLit {
    std::vector<RecordEntry> entries;
  },

      // Record type: { x : Natural, y : Bool }
      struct RecordType {
    std::vector<std::pair<std::string, ExprPtr>> fields;
  },

      // Union type: < Left : Natural | Right : Text >
      struct UnionType {
    std::vector<UnionAlt> alternatives;
  },

      // List literal: [1, 2, 3]
      struct ListLit {
    std::optional<ExprPtr> type; // For empty list
    std::vector<ExprPtr> elements;
  },

      // Some: Some x
      struct Some {
    ExprPtr value;
  },

      // Binary operators
      struct BinOp {
    enum class Op {
      Or,
      And,
      Eq,
      Ne,
      Plus,
      Times,
      TextAppend,
      ListAppend,
      Combine,
      CombineTypes,
      Prefer,
      ImportAlt,
      Equivalent,
    };
    Op op;
    ExprPtr lhs;
    ExprPtr rhs;
  },

      // Builtins
      struct Builtin {
    enum class Name {
      // Types
      Bool,
      Natural,
      Integer,
      Double,
      Text,
      Bytes,
      Date,
      Time,
      TimeZone,
      List,
      Optional,
      Type,
      Kind,
      Sort,
      // Values
      True,
      False,
      None,
      // Functions
      NaturalFold,
      NaturalBuild,
      NaturalIsZero,
      NaturalEven,
      NaturalOdd,
      NaturalToInteger,
      NaturalShow,
      NaturalSubtract,
      IntegerToDouble,
      IntegerShow,
      IntegerNegate,
      IntegerClamp,
      DoubleShow,
      ListBuild,
      ListFold,
      ListLength,
      ListHead,
      ListLast,
      ListIndexed,
      ListReverse,
      TextShow,
      TextReplace,
      DateShow,
      TimeShow,
      TimeZoneShow,
    };
    Name name;
  },

      // Import
      Import

          > data;
};

// ============================================================================
// Error Types
// ============================================================================

struct ParseError {
  SourcePos position;
  std::string message;
  std::string context; // What we were trying to parse
};

struct TypeError {
  SourceSpan span;
  std::string message;
  ExprPtr expected;
  ExprPtr actual;
};

using Error = std::variant<ParseError, TypeError>;

// ============================================================================
// Parser Interface
// ============================================================================

class Parser {
public:
  explicit Parser(std::string_view source, std::string filename = "<input>");

  // Parse a complete Dhall expression
  auto parse() -> std::expected<ExprPtr, ParseError>;

  // Parse just the expression (for REPL, assumes no shebang)
  auto parse_expression() -> std::expected<ExprPtr, ParseError>;

private:
  std::string_view source_;
  std::string filename_;
  SourcePos pos_;
  std::size_t lookahead_k_ = 4; // LL(k) lookahead

  // Lexer state
  auto peek(std::size_t ahead = 0) -> char32_t;
  auto advance() -> char32_t;
  auto match(std::string_view s) -> bool;
  auto match_keyword(std::string_view kw) -> bool;

  // Whitespace and comments
  auto skip_whitespace() -> void;
  auto skip_line_comment() -> bool;
  auto skip_block_comment() -> bool;

  // Expression parsers (ordered by precedence, lowest first)
  auto parse_complete_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_let_binding() -> std::expected<Binding, ParseError>;
  auto parse_operator_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_equivalent_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_import_alt_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_or_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_plus_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_text_append_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_list_append_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_and_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_combine_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_prefer_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_combine_types_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_times_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_equal_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_not_equal_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_application_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_import_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_completion_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_selector_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_primitive_expression() -> std::expected<ExprPtr, ParseError>;

  // Specific parsers
  auto parse_lambda() -> std::expected<ExprPtr, ParseError>;
  auto parse_forall() -> std::expected<ExprPtr, ParseError>;
  auto parse_if() -> std::expected<ExprPtr, ParseError>;
  auto parse_merge() -> std::expected<ExprPtr, ParseError>;
  auto parse_assert() -> std::expected<ExprPtr, ParseError>;
  auto parse_with_expression() -> std::expected<ExprPtr, ParseError>;
  auto parse_empty_list() -> std::expected<ExprPtr, ParseError>;
  auto parse_tomap() -> std::expected<ExprPtr, ParseError>;

  // Literal parsers
  auto parse_identifier() -> std::expected<ExprPtr, ParseError>;
  auto parse_variable() -> std::expected<ExprPtr, ParseError>;
  auto parse_natural() -> std::expected<ExprPtr, ParseError>;
  auto parse_integer() -> std::expected<ExprPtr, ParseError>;
  auto parse_double() -> std::expected<ExprPtr, ParseError>;
  auto parse_text_literal() -> std::expected<ExprPtr, ParseError>;
  auto parse_bytes_literal() -> std::expected<ExprPtr, ParseError>;
  auto parse_temporal_literal() -> std::expected<ExprPtr, ParseError>;

  // Compound parsers
  auto parse_record() -> std::expected<ExprPtr, ParseError>;
  auto parse_union() -> std::expected<ExprPtr, ParseError>;
  auto parse_list() -> std::expected<ExprPtr, ParseError>;
  auto parse_import() -> std::expected<ExprPtr, ParseError>;

  // Label parsers
  auto parse_label() -> std::expected<std::string, ParseError>;
  auto parse_any_label() -> std::expected<std::string, ParseError>;
  auto parse_nonreserved_label() -> std::expected<std::string, ParseError>;

  // Utilities
  auto make_error(std::string_view msg, std::string_view context = {}) -> ParseError;
  auto expect(char32_t c) -> std::expected<void, ParseError>;
  auto expect(std::string_view s) -> std::expected<void, ParseError>;
  [[nodiscard]] auto is_keyword(std::string_view s) const -> bool;
  [[nodiscard]] auto is_builtin(std::string_view s) const -> bool;
  [[nodiscard]] auto current_span() const -> SourceSpan;
};

// ============================================================================
// Evaluator Interface (Normalization)
// ============================================================================

class Evaluator {
public:
  // Normalize an expression to beta-normal form
  static auto normalize(const Expr& e) -> ExprPtr;

  // Alpha-equivalence check
  static auto alpha_equivalent(const Expr& a, const Expr& b) -> bool;

  // Beta-equivalence check (normalizes first)
  static auto beta_equivalent(const Expr& a, const Expr& b) -> bool;
};

// ============================================================================
// Type Checker Interface
// ============================================================================

class TypeChecker {
public:
  // Infer the type of an expression
  auto infer(const Expr& e) -> std::expected<ExprPtr, TypeError>;

  // Check that an expression has a given type
  auto check(const Expr& e, const Expr& type) -> std::expected<void, TypeError>;
};

// ============================================================================
// Pretty Printer
// ============================================================================

class PrettyPrinter {
public:
  explicit PrettyPrinter(std::size_t width = 80);

  auto print(const Expr& e) -> std::string;

private:
  std::size_t width_;
};

// ============================================================================
// Convenience Functions
// ============================================================================

// Parse a string into an expression
inline auto parse(std::string_view source, std::string filename = "<input>")
    -> std::expected<ExprPtr, ParseError> {
  return Parser(source, std::move(filename)).parse();
}

// Parse and normalize
inline auto evaluate(std::string_view source) -> std::expected<ExprPtr, Error> {
  auto expr = parse(source);
  if (!expr) {
    return std::unexpected(expr.error());
  }
  return Evaluator::normalize(**expr);
}

} // namespace continuity::codec
