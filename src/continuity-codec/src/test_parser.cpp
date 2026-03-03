// Continuity.Codec.Dhall - Parser Test
// straylight.software · 2026

#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>

#include "parser.hpp"

using namespace continuity::dhall;

// Simple AST printer
void print_expr(Interner& interner, ExprPtr e, int indent = 0) {
  std::string pad(indent * 2, ' ');

  if (!e) {
    std::cout << pad << "NULL\n";
    return;
  }

  switch (e->kind) {
    case Expr::Kind::Const:
      std::cout << pad << "Const(";
      switch (e->const_val) {
        case Const::Type:
          std::cout << "Type";
          break;
        case Const::Kind:
          std::cout << "Kind";
          break;
        case Const::Sort:
          std::cout << "Sort";
          break;
      }
      std::cout << ")\n";
      break;

    case Expr::Kind::Var:
      std::cout << pad << "Var(" << e->var_idx << ")\n";
      break;

    case Expr::Kind::Builtin:
      std::cout << pad << "Builtin(" << static_cast<int>(e->builtin) << ")\n";
      break;

    case Expr::Kind::Lit:
      std::cout << pad << "Lit(";
      switch (e->lit.kind) {
        case Lit::Kind::Bool:
          std::cout << (e->lit.b ? "True" : "False");
          break;
        case Lit::Kind::Nat:
          std::cout << e->lit.n;
          break;
        case Lit::Kind::Int:
          std::cout << e->lit.i;
          break;
        case Lit::Kind::Double:
          std::cout << e->lit.d;
          break;
        case Lit::Kind::Text:
          std::cout << "\"" << std::string_view(e->lit.text.data, e->lit.text.len) << "\"";
          break;
      }
      std::cout << ")\n";
      break;

    case Expr::Kind::Lam:
      std::cout << pad << "Lam(" << interner.get(e->lam.name) << ")\n";
      std::cout << pad << "  type:\n";
      print_expr(interner, e->lam.type, indent + 2);
      std::cout << pad << "  body:\n";
      print_expr(interner, e->lam.body, indent + 2);
      break;

    case Expr::Kind::Pi:
      std::cout << pad << "Pi(" << interner.get(e->pi.name) << ")\n";
      std::cout << pad << "  domain:\n";
      print_expr(interner, e->pi.domain, indent + 2);
      std::cout << pad << "  codomain:\n";
      print_expr(interner, e->pi.codomain, indent + 2);
      break;

    case Expr::Kind::App:
      std::cout << pad << "App\n";
      std::cout << pad << "  func:\n";
      print_expr(interner, e->app.func, indent + 2);
      std::cout << pad << "  arg:\n";
      print_expr(interner, e->app.arg, indent + 2);
      break;

    case Expr::Kind::Let:
      std::cout << pad << "Let(" << interner.get(e->let.name) << ")\n";
      if (e->let.type) {
        std::cout << pad << "  type:\n";
        print_expr(interner, e->let.type, indent + 2);
      }
      std::cout << pad << "  value:\n";
      print_expr(interner, e->let.value, indent + 2);
      std::cout << pad << "  body:\n";
      print_expr(interner, e->let.body, indent + 2);
      break;

    case Expr::Kind::BoolAnd:
      std::cout << pad << "BoolAnd\n";
      print_expr(interner, e->binop.lhs, indent + 1);
      print_expr(interner, e->binop.rhs, indent + 1);
      break;

    case Expr::Kind::BoolOr:
      std::cout << pad << "BoolOr\n";
      print_expr(interner, e->binop.lhs, indent + 1);
      print_expr(interner, e->binop.rhs, indent + 1);
      break;

    case Expr::Kind::BoolIf:
      std::cout << pad << "If\n";
      std::cout << pad << "  cond:\n";
      print_expr(interner, e->if_.cond, indent + 2);
      std::cout << pad << "  then:\n";
      print_expr(interner, e->if_.then_, indent + 2);
      std::cout << pad << "  else:\n";
      print_expr(interner, e->if_.else_, indent + 2);
      break;

    case Expr::Kind::NatPlus:
      std::cout << pad << "NatPlus\n";
      print_expr(interner, e->binop.lhs, indent + 1);
      print_expr(interner, e->binop.rhs, indent + 1);
      break;

    case Expr::Kind::NatTimes:
      std::cout << pad << "NatTimes\n";
      print_expr(interner, e->binop.lhs, indent + 1);
      print_expr(interner, e->binop.rhs, indent + 1);
      break;

    case Expr::Kind::List:
      std::cout << pad << "List[" << e->list.count << "]\n";
      for (std::size_t i = 0; i < e->list.count; ++i) {
        print_expr(interner, e->list.elems[i], indent + 1);
      }
      break;

    case Expr::Kind::RecordLit:
      std::cout << pad << "RecordLit{" << e->fields->size() << " fields}\n";
      for (const auto& entry : *e->fields) {
        std::cout << pad << "  " << interner.get(entry.name) << ":\n";
        print_expr(interner, entry.value, indent + 2);
      }
      break;

    case Expr::Kind::Record:
      std::cout << pad << "Record{" << e->fields->size() << " fields}\n";
      for (const auto& entry : *e->fields) {
        std::cout << pad << "  " << interner.get(entry.name) << ":\n";
        print_expr(interner, entry.value, indent + 2);
      }
      break;

    case Expr::Kind::Field:
      std::cout << pad << "Field(." << interner.get(e->field.name) << ")\n";
      print_expr(interner, e->field.record, indent + 1);
      break;

    case Expr::Kind::Prefer:
      std::cout << pad << "Prefer(//)\n";
      print_expr(interner, e->binop.lhs, indent + 1);
      print_expr(interner, e->binop.rhs, indent + 1);
      break;

    case Expr::Kind::Annot:
      std::cout << pad << "Annot\n";
      std::cout << pad << "  expr:\n";
      print_expr(interner, e->annot.expr, indent + 2);
      std::cout << pad << "  type:\n";
      print_expr(interner, e->annot.type, indent + 2);
      break;

    default:
      std::cout << pad << "Unknown(" << static_cast<int>(e->kind) << ")\n";
      break;
  }
}

void test_parse(const char* name, const std::string& src) {
  std::cout << "=== " << name << " ===\n";
  std::cout << "Source: " << src << "\n\n";

  Arena arena;
  Interner interner;
  Parser parser(src, arena, interner);

  auto result = parser.parse();
  if (result) {
    std::cout << "AST:\n";
    print_expr(interner, *result);
  } else {
    std::cout << "Parse error: " << result.error().message << " at offset " << result.error().offset
              << "\n";
  }
  std::cout << "\n";
}

void test_file(const std::string& path) {
  std::cout << "=== File: " << path << " ===\n";

  std::ifstream file(path);
  if (!file) {
    std::cout << "Could not open file\n\n";
    return;
  }

  std::stringstream buffer;
  buffer << file.rdbuf();
  std::string src = buffer.str();

  Arena arena;
  Interner interner;

  auto start = std::chrono::high_resolution_clock::now();

  Parser parser(src, arena, interner);
  auto result = parser.parse();

  auto end = std::chrono::high_resolution_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  if (result) {
    std::cout << "Parsed successfully in " << us << " us (" << (us / 1000.0) << " ms)\n";
    std::cout << "Throughput: " << (src.size() * 1000000.0 / us / 1024) << " KB/s\n";

    // Count nodes (rough approximation)
    // Don't print full AST for large files
    if (src.size() < 500) {
      std::cout << "\nAST:\n";
      print_expr(interner, *result);
    }
  } else {
    std::cout << "Parse error: " << result.error().message << " at offset " << result.error().offset
              << " (line " << result.error().line << ", col " << result.error().col << ")\n";

    // Show context
    std::size_t start_ctx = result.error().offset > 20 ? result.error().offset - 20 : 0;
    std::size_t end_ctx =
        std::min(result.error().offset + 20, static_cast<std::uint32_t>(src.size()));
    std::cout << "Context: ..." << src.substr(start_ctx, end_ctx - start_ctx) << "...\n";
  }
  std::cout << "\n";
}

int main(int argc, char** argv) {
  // Basic tests
  test_parse("Natural literal", "42");
  test_parse("Text literal", "\"hello\"");
  test_parse("Boolean literal", "True");
  test_parse("Empty record", "{}");
  test_parse("Simple record", "{ x = 1, y = 2 }");
  test_parse("Let expression", "let x = 1 in x");
  test_parse("Let with type", "let x : Natural = 1 in x");
  test_parse("Lambda", "\\(x : Natural) -> x");
  test_parse("Application", "f x y");
  test_parse("Field access", "r.x.y");
  test_parse("Binary operators", "1 + 2 + 3");
  test_parse("Prefer operator", "a // b");
  test_parse("If expression", "if True then 1 else 2");
  test_parse("Empty list", "[] : List Natural");
  test_parse("Non-empty list", "[1, 2, 3]");
  test_parse("Chained let", "let x = 1 let y = 2 in x + y");
  test_parse("Nested record", "{ a = { b = 1 } }");
  test_parse("Union type", "< Foo : Natural | Bar >");

  // Test files
  if (argc > 1) {
    for (int i = 1; i < argc; i++) {
      test_file(argv[i]);
    }
  } else {
    test_file("../../../src/examples/cxx/BUILD.dhall");
  }

  return 0;
}
