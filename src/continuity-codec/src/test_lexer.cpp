// Continuity.Codec.Dhall - Lexer Test
// straylight.software · 2026

#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "lexer.hpp"

using namespace continuity::dhall;

const char* token_kind_name(TokenKind k) {
  switch (k) {
    case TokenKind::LParen:
      return "LParen";
    case TokenKind::RParen:
      return "RParen";
    case TokenKind::LBrace:
      return "LBrace";
    case TokenKind::RBrace:
      return "RBrace";
    case TokenKind::LBracket:
      return "LBracket";
    case TokenKind::RBracket:
      return "RBracket";
    case TokenKind::LAngle:
      return "LAngle";
    case TokenKind::RAngle:
      return "RAngle";
    case TokenKind::Comma:
      return "Comma";
    case TokenKind::Dot:
      return "Dot";
    case TokenKind::Colon:
      return "Colon";
    case TokenKind::At:
      return "At";
    case TokenKind::Equal:
      return "Equal";
    case TokenKind::Pipe:
      return "Pipe";
    case TokenKind::Backslash:
      return "Backslash";
    case TokenKind::Question:
      return "Question";
    case TokenKind::Arrow:
      return "Arrow";
    case TokenKind::FatArrow:
      return "FatArrow";
    case TokenKind::DoubleColon:
      return "DoubleColon";
    case TokenKind::Combine:
      return "Combine";
    case TokenKind::CombineTypes:
      return "CombineTypes";
    case TokenKind::Prefer:
      return "Prefer";
    case TokenKind::Alternative:
      return "Alternative";
    case TokenKind::Equivalent:
      return "Equivalent";
    case TokenKind::NotEqual:
      return "NotEqual";
    case TokenKind::And:
      return "And";
    case TokenKind::Or:
      return "Or";
    case TokenKind::Plus:
      return "Plus";
    case TokenKind::Times:
      return "Times";
    case TokenKind::TextAppend:
      return "TextAppend";
    case TokenKind::ListAppend:
      return "ListAppend";
    case TokenKind::If:
      return "If";
    case TokenKind::Then:
      return "Then";
    case TokenKind::Else:
      return "Else";
    case TokenKind::Let:
      return "Let";
    case TokenKind::In:
      return "In";
    case TokenKind::Forall:
      return "Forall";
    case TokenKind::Assert:
      return "Assert";
    case TokenKind::As:
      return "As";
    case TokenKind::Using:
      return "Using";
    case TokenKind::Merge:
      return "Merge";
    case TokenKind::ToMap:
      return "ToMap";
    case TokenKind::With:
      return "With";
    case TokenKind::Missing:
      return "Missing";
    case TokenKind::Type:
      return "Type";
    case TokenKind::Kind:
      return "Kind";
    case TokenKind::Sort:
      return "Sort";
    case TokenKind::Builtin:
      return "Builtin";
    case TokenKind::NaturalLit:
      return "NaturalLit";
    case TokenKind::IntegerLit:
      return "IntegerLit";
    case TokenKind::DoubleLit:
      return "DoubleLit";
    case TokenKind::TextLit:
      return "TextLit";
    case TokenKind::TextInterpolStart:
      return "TextInterpolStart";
    case TokenKind::TextInterpolEnd:
      return "TextInterpolEnd";
    case TokenKind::Label:
      return "Label";
    case TokenKind::QuotedLabel:
      return "QuotedLabel";
    case TokenKind::LocalPath:
      return "LocalPath";
    case TokenKind::EnvVar:
      return "EnvVar";
    case TokenKind::HttpUrl:
      return "HttpUrl";
    case TokenKind::Newline:
      return "Newline";
    case TokenKind::Eof:
      return "Eof";
    case TokenKind::Error:
      return "Error";
  }
  return "Unknown";
}

void print_token(const Token& t, std::string_view src) {
  std::cout << token_kind_name(t.kind) << " [" << t.offset << ":" << t.length << "]";

  if (t.kind == TokenKind::Label || t.kind == TokenKind::QuotedLabel ||
      t.kind == TokenKind::TextLit || t.kind == TokenKind::LocalPath) {
    std::cout << " \"" << t.text(src) << "\"";
  } else if (t.kind == TokenKind::NaturalLit) {
    std::cout << " " << t.natural_val;
  } else if (t.kind == TokenKind::IntegerLit) {
    std::cout << " " << t.integer_val;
  } else if (t.kind == TokenKind::DoubleLit) {
    std::cout << " " << t.double_val;
  } else if (t.kind == TokenKind::Builtin) {
    std::cout << " builtin#" << t.natural_val;
  }
  std::cout << "\n";
}

void test_basic() {
  std::cout << "=== Basic Token Test ===\n";

  std::string src = R"(
let x = 42
let y = "hello"
let z = x + y
in { foo = z, bar = True }
)";

  Lexer lexer(src);
  while (true) {
    Token t = lexer.next();
    print_token(t, src);
    if (t.kind == TokenKind::Eof || t.kind == TokenKind::Error)
      break;
  }
  std::cout << "\n";
}

void test_operators() {
  std::cout << "=== Operator Test ===\n";

  std::string src = R"(a // b /\ c === d != e && f || g -> h :: i ++ j # k)";

  Lexer lexer(src);
  while (true) {
    Token t = lexer.next();
    print_token(t, src);
    if (t.kind == TokenKind::Eof || t.kind == TokenKind::Error)
      break;
  }
  std::cout << "\n";
}

void test_numbers() {
  std::cout << "=== Number Test ===\n";

  std::string src = R"(0 42 0x1F +5 -10 3.14 1e10 2.5e-3)";

  Lexer lexer(src);
  while (true) {
    Token t = lexer.next();
    print_token(t, src);
    if (t.kind == TokenKind::Eof || t.kind == TokenKind::Error)
      break;
  }
  std::cout << "\n";
}

void test_comments() {
  std::cout << "=== Comment Test ===\n";

  std::string src = R"(
-- This is a line comment
let x = 1 -- inline comment
{- Block comment -}
let y = {- nested {- comment -} -} 2
in x
)";

  Lexer lexer(src);
  while (true) {
    Token t = lexer.next();
    print_token(t, src);
    if (t.kind == TokenKind::Eof || t.kind == TokenKind::Error)
      break;
  }
  std::cout << "\n";
}

void test_builtins() {
  std::cout << "=== Builtin Test ===\n";

  std::string src = R"(Natural List/fold True False None Some Optional Text/show)";

  Lexer lexer(src);
  while (true) {
    Token t = lexer.next();
    print_token(t, src);
    if (t.kind == TokenKind::Eof || t.kind == TokenKind::Error)
      break;
  }
  std::cout << "\n";
}

void test_real_dhall(const std::string& path) {
  std::cout << "=== Real Dhall File: " << path << " ===\n";

  std::ifstream file(path);
  if (!file) {
    std::cout << "Could not open file\n\n";
    return;
  }

  std::stringstream buffer;
  buffer << file.rdbuf();
  std::string src = buffer.str();

  auto start = std::chrono::high_resolution_clock::now();

  Lexer lexer(src);
  int count = 0;
  while (true) {
    Token t = lexer.next();
    count++;
    if (t.kind == TokenKind::Eof)
      break;
    if (t.kind == TokenKind::Error) {
      std::cout << "ERROR at offset " << t.offset << "\n";
      break;
    }
  }

  auto end = std::chrono::high_resolution_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  std::cout << "Tokens: " << count << ", Time: " << us << " us (" << (us / 1000.0) << " ms)\n";
  std::cout << "Throughput: " << (src.size() * 1000000.0 / us / 1024 / 1024) << " MB/s\n\n";
}

void bench_throughput() {
  std::cout << "=== Throughput Benchmark ===\n";

  // Generate synthetic Dhall-like content
  std::string src;
  for (int i = 0; i < 1000; i++) {
    src +=
        "let var" + std::to_string(i) + " = { field1 = 42, field2 = \"hello\", field3 = True }\n";
  }
  src += "in var0\n";

  auto start = std::chrono::high_resolution_clock::now();

  const int iterations = 100;
  int total_tokens = 0;
  for (int i = 0; i < iterations; i++) {
    Lexer lexer(src);
    while (true) {
      Token t = lexer.next();
      total_tokens++;
      if (t.kind == TokenKind::Eof)
        break;
    }
  }

  auto end = std::chrono::high_resolution_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  std::cout << "Source size: " << src.size() << " bytes\n";
  std::cout << "Iterations: " << iterations << "\n";
  std::cout << "Total tokens: " << total_tokens << "\n";
  std::cout << "Total time: " << (us / 1000.0) << " ms\n";
  std::cout << "Per iteration: " << (us / iterations) << " us\n";
  std::cout << "Throughput: " << (src.size() * iterations * 1000000.0 / us / 1024 / 1024)
            << " MB/s\n\n";
}

int main(int argc, char** argv) {
  test_basic();
  test_operators();
  test_numbers();
  test_comments();
  test_builtins();
  bench_throughput();

  // Test real files if provided
  if (argc > 1) {
    for (int i = 1; i < argc; i++) {
      test_real_dhall(argv[i]);
    }
  } else {
    // Try default paths
    test_real_dhall("../../../dhall/evring/Compat.dhall");
    test_real_dhall("../../../src/examples/cxx/BUILD.dhall");
  }

  return 0;
}
