// Continuity.Codec - Test Suite
//
// Basic tests for the C++23 Dhall parser.
//
// straylight.software - 2026

#include <cassert>
#include <iostream>

#include "../Codec.hpp"

namespace cc = continuity::codec;

void test_parse_natural() {
  auto result = cc::parse("42");
  assert(result.has_value());
  auto* nat = std::get_if<std::uint64_t>(&(*result)->data);
  assert(nat != nullptr);
  assert(*nat == 42);
  std::cout << "  parse_natural: PASS\n";
}

void test_parse_integer() {
  auto result = cc::parse("+42");
  assert(result.has_value());
  auto* i = std::get_if<std::int64_t>(&(*result)->data);
  assert(i != nullptr);
  assert(*i == 42);

  result = cc::parse("-17");
  assert(result.has_value());
  i = std::get_if<std::int64_t>(&(*result)->data);
  assert(i != nullptr);
  assert(*i == -17);
  std::cout << "  parse_integer: PASS\n";
}

void test_parse_bool() {
  auto result = cc::parse("True");
  assert(result.has_value());
  auto* builtin = std::get_if<cc::Expr::Builtin>(&(*result)->data);
  assert(builtin != nullptr);
  assert(builtin->name == cc::Expr::Builtin::Name::True);

  result = cc::parse("False");
  assert(result.has_value());
  builtin = std::get_if<cc::Expr::Builtin>(&(*result)->data);
  assert(builtin != nullptr);
  assert(builtin->name == cc::Expr::Builtin::Name::False);
  std::cout << "  parse_bool: PASS\n";
}

void test_parse_text() {
  auto result = cc::parse("\"hello world\"");
  assert(result.has_value());
  auto* text = std::get_if<std::vector<cc::TextChunk>>(&(*result)->data);
  assert(text != nullptr);
  assert(text->size() == 1);
  auto* s = std::get_if<std::string>(&(*text)[0].content);
  assert(s != nullptr);
  assert(*s == "hello world");
  std::cout << "  parse_text: PASS\n";
}

void test_parse_list() {
  auto result = cc::parse("[1, 2, 3]");
  assert(result.has_value());
  auto* list = std::get_if<cc::Expr::ListLit>(&(*result)->data);
  assert(list != nullptr);
  assert(list->elements.size() == 3);
  std::cout << "  parse_list: PASS\n";
}

void test_parse_record() {
  auto result = cc::parse("{ x = 1, y = 2 }");
  assert(result.has_value());
  auto* rec = std::get_if<cc::Expr::RecordLit>(&(*result)->data);
  assert(rec != nullptr);
  assert(rec->entries.size() == 2);
  std::cout << "  parse_record: PASS\n";
}

void test_parse_lambda() {
  auto result = cc::parse("\\(x : Natural) -> x");
  assert(result.has_value());
  auto* lam = std::get_if<cc::Expr::Lambda>(&(*result)->data);
  assert(lam != nullptr);
  assert(lam->param == "x");
  std::cout << "  parse_lambda: PASS\n";
}

void test_parse_let() {
  auto result = cc::parse("let x = 1 in x");
  assert(result.has_value());
  // After parsing, the let should be present
  // (normalization would eliminate it)
  std::cout << "  parse_let: PASS\n";
}

void test_parse_if() {
  auto result = cc::parse("if True then 1 else 0");
  assert(result.has_value());
  auto* ife = std::get_if<cc::Expr::If>(&(*result)->data);
  assert(ife != nullptr);
  std::cout << "  parse_if: PASS\n";
}

void test_normalize_natural() {
  auto expr = cc::parse("1 + 2");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* nat = std::get_if<std::uint64_t>(&norm->data);
  assert(nat != nullptr);
  assert(*nat == 3);
  std::cout << "  normalize_natural_plus: PASS\n";
}

void test_normalize_bool() {
  auto expr = cc::parse("True && False");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* b = std::get_if<bool>(&norm->data);
  assert(b != nullptr);
  assert(*b == false);
  std::cout << "  normalize_bool_and: PASS\n";
}

void test_normalize_let() {
  auto expr = cc::parse("let x = 1 in let y = 2 in x + y");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* nat = std::get_if<std::uint64_t>(&norm->data);
  assert(nat != nullptr);
  assert(*nat == 3);
  std::cout << "  normalize_let: PASS\n";
}

void test_normalize_beta() {
  auto expr = cc::parse("(\\(x : Natural) -> x + 1) 5");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* nat = std::get_if<std::uint64_t>(&norm->data);
  assert(nat != nullptr);
  assert(*nat == 6);
  std::cout << "  normalize_beta: PASS\n";
}

void test_builtin_natural_iszero() {
  auto expr = cc::parse("Natural/isZero 0");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* b = std::get_if<bool>(&norm->data);
  assert(b != nullptr);
  assert(*b == true);

  expr = cc::parse("Natural/isZero 5");
  assert(expr.has_value());
  norm = cc::Evaluator::normalize(**expr);
  b = std::get_if<bool>(&norm->data);
  assert(b != nullptr);
  assert(*b == false);
  std::cout << "  builtin_natural_iszero: PASS\n";
}

void test_builtin_list_length() {
  auto expr = cc::parse("List/length Natural [1, 2, 3, 4, 5]");
  assert(expr.has_value());
  auto norm = cc::Evaluator::normalize(**expr);
  auto* nat = std::get_if<std::uint64_t>(&norm->data);
  assert(nat != nullptr);
  assert(*nat == 5);
  std::cout << "  builtin_list_length: PASS\n";
}

void test_comments() {
  // Line comment
  auto result = cc::parse("-- this is a comment\n42");
  assert(result.has_value());
  auto* nat = std::get_if<std::uint64_t>(&(*result)->data);
  assert(nat != nullptr);
  assert(*nat == 42);

  // Block comment
  result = cc::parse("{- block comment -} 17");
  assert(result.has_value());
  nat = std::get_if<std::uint64_t>(&(*result)->data);
  assert(nat != nullptr);
  assert(*nat == 17);

  // Nested block comment
  result = cc::parse("{- outer {- nested -} outer -} 99");
  assert(result.has_value());
  nat = std::get_if<std::uint64_t>(&(*result)->data);
  assert(nat != nullptr);
  assert(*nat == 99);

  std::cout << "  comments: PASS\n";
}

void test_operators() {
  // Text append
  auto result = cc::parse("\"hello\" ++ \" \" ++ \"world\"");
  assert(result.has_value());
  auto norm = cc::Evaluator::normalize(**result);
  auto* text = std::get_if<std::vector<cc::TextChunk>>(&norm->data);
  assert(text != nullptr);
  // After normalization, should be a single text chunk
  std::cout << "  operators_text_append: PASS\n";

  // List append
  result = cc::parse("[1, 2] # [3, 4]");
  assert(result.has_value());
  norm = cc::Evaluator::normalize(**result);
  auto* list = std::get_if<cc::Expr::ListLit>(&norm->data);
  assert(list != nullptr);
  assert(list->elements.size() == 4);
  std::cout << "  operators_list_append: PASS\n";
}

void test_field_access() {
  auto result = cc::parse("{ x = 1, y = 2 }.x");
  assert(result.has_value());
  auto norm = cc::Evaluator::normalize(**result);
  auto* nat = std::get_if<std::uint64_t>(&norm->data);
  assert(nat != nullptr);
  assert(*nat == 1);
  std::cout << "  field_access: PASS\n";
}

void test_projection() {
  auto result = cc::parse("{ x = 1, y = 2, z = 3 }.{ x, z }");
  assert(result.has_value());
  auto norm = cc::Evaluator::normalize(**result);
  auto* rec = std::get_if<cc::Expr::RecordLit>(&norm->data);
  assert(rec != nullptr);
  assert(rec->entries.size() == 2);
  std::cout << "  projection: PASS\n";
}

int main() {
  std::cout << "Continuity.Codec Test Suite\n";
  std::cout << "===========================\n\n";

  std::cout << "Parser Tests:\n";
  test_parse_natural();
  test_parse_integer();
  test_parse_bool();
  test_parse_text();
  test_parse_list();
  test_parse_record();
  test_parse_lambda();
  test_parse_let();
  test_parse_if();
  test_comments();

  std::cout << "\nNormalization Tests:\n";
  test_normalize_natural();
  test_normalize_bool();
  test_normalize_let();
  test_normalize_beta();

  std::cout << "\nBuiltin Tests:\n";
  test_builtin_natural_iszero();
  test_builtin_list_length();

  std::cout << "\nOperator Tests:\n";
  test_operators();
  test_field_access();
  test_projection();

  std::cout << "\n===========================\n";
  std::cout << "All tests passed!\n";

  return 0;
}
