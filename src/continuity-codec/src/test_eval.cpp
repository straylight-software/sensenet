// Continuity.Codec.Dhall - Integrated Parse + Eval Test
// straylight.software · 2026

#include <chrono>
#include <iostream>

#include "parser.hpp"

using namespace continuity::dhall;

// Print a value (simplified)
void print_value(Interner& interner, ValuePtr v, int indent = 0) {
  std::string pad(indent * 2, ' ');

  if (!v) {
    std::cout << pad << "NULL\n";
    return;
  }

  switch (v->kind) {
    case Value::Kind::Const:
      std::cout << pad << "Const(";
      switch (v->const_val) {
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

    case Value::Kind::Var:
      std::cout << pad << "Var(" << v->var_level << ")\n";
      break;

    case Value::Kind::Lit:
      std::cout << pad << "Lit(";
      switch (v->lit.kind) {
        case Lit::Kind::Bool:
          std::cout << (v->lit.b ? "True" : "False");
          break;
        case Lit::Kind::Nat:
          std::cout << v->lit.n;
          break;
        case Lit::Kind::Int:
          std::cout << v->lit.i;
          break;
        case Lit::Kind::Double:
          std::cout << v->lit.d;
          break;
        case Lit::Kind::Text:
          std::cout << "\"" << std::string_view(v->lit.text.data, v->lit.text.len) << "\"";
          break;
      }
      std::cout << ")\n";
      break;

    case Value::Kind::Lam:
      std::cout << pad << "Lam(" << interner.get(v->closure->name) << ")\n";
      break;

    case Value::Kind::Pi:
      std::cout << pad << "Pi\n";
      break;

    case Value::Kind::App:
      std::cout << pad << "App\n";
      break;

    case Value::Kind::Builtin:
      std::cout << pad << "Builtin(" << static_cast<int>(v->builtin.b) << ")\n";
      break;

    case Value::Kind::List:
      std::cout << pad << "List[" << (v->list.elems ? v->list.elems->size() : 0) << "]\n";
      break;

    case Value::Kind::RecordLit:
      std::cout << pad << "RecordLit{" << v->fields->size() << " fields}\n";
      for (const auto& entry : *v->fields) {
        std::cout << pad << "  " << interner.get(entry.name) << ": ";
        // Print inline for simple values
        if (entry.value->kind == Value::Kind::Lit) {
          if (entry.value->lit.kind == Lit::Kind::Nat) {
            std::cout << entry.value->lit.n << "\n";
          } else if (entry.value->lit.kind == Lit::Kind::Text) {
            std::cout << "\""
                      << std::string_view(entry.value->lit.text.data, entry.value->lit.text.len)
                      << "\"\n";
          } else {
            std::cout << "...\n";
          }
        } else if (entry.value->kind == Value::Kind::RecordLit) {
          std::cout << "{...}\n";
        } else if (entry.value->kind == Value::Kind::List) {
          std::cout << "[" << (entry.value->list.elems ? entry.value->list.elems->size() : 0)
                    << " elems]\n";
        } else {
          std::cout << "...\n";
        }
      }
      break;

    case Value::Kind::Record:
      std::cout << pad << "Record{" << v->fields->size() << " fields}\n";
      break;

    case Value::Kind::Field:
      std::cout << pad << "Field(." << interner.get(v->field.name) << ")\n";
      break;

    case Value::Kind::Prefer:
      std::cout << pad << "Prefer\n";
      break;

    default:
      std::cout << pad << "Unknown(" << static_cast<int>(v->kind) << ")\n";
      break;
  }
}

void test_eval(const char* name, const std::string& src) {
  std::cout << "=== " << name << " ===\n";

  Arena arena;
  Interner interner;

  Parser parser(src, arena, interner);
  auto parse_result = parser.parse();

  if (!parse_result) {
    std::cout << "Parse error: " << parse_result.error().message << "\n\n";
    return;
  }

  Evaluator eval(arena, interner);
  Env env;
  auto* value = eval.eval(env, *parse_result);

  print_value(interner, value);
  std::cout << "\n";
}

void bench_eval(const std::string& label, const std::string& src, int iterations) {
  Arena arena;
  Interner interner;

  Parser parser(src, arena, interner);
  auto parse_result = parser.parse();
  if (!parse_result) {
    std::cout << "Parse error\n";
    return;
  }

  Evaluator eval(arena, interner);

  auto start = std::chrono::high_resolution_clock::now();

  for (int i = 0; i < iterations; i++) {
    Env env;
    eval.eval(env, *parse_result);
  }

  auto end = std::chrono::high_resolution_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  std::cout << label << ": " << iterations << " iters in " << us << " us ("
            << (us * 1000 / iterations) << " ns/iter)\n";
}

int main() {
  // Basic evaluations
  test_eval("Natural literal", "42");
  test_eval("Boolean literal", "True");
  test_eval("Text literal", "\"hello\"");
  test_eval("Empty record", "{}");
  test_eval("Simple record", "{ x = 1, y = 2 }");
  test_eval("Let expression", "let x = 1 in x");
  test_eval("Let with addition", "let x = 1 let y = 2 in x + y");
  test_eval("Lambda applied", "(\\(x : Natural) -> x) 42");
  test_eval("Record field access", "{ x = 42, y = 10 }.x");
  test_eval("Record prefer", "{ x = 1, y = 2 } // { y = 3, z = 4 }");
  test_eval("If true", "if True then 1 else 2");
  test_eval("Natural addition", "1 + 2 + 3");
  test_eval("List literal", "[1, 2, 3]");
  test_eval("Nested record", "{ a = { b = 42 } }.a.b");

  // BUILD-like expression
  test_eval("BUILD-like", R"(
    let cxx_binary = \(name : Text) -> \(srcs : List Text) -> { name, srcs }
    let hello = cxx_binary "hello" ["hello.cpp"]
    in { targets = [hello] }
  )");

  // Benchmarks
  std::cout << "\n=== Benchmarks ===\n";
  bench_eval("Literal", "42", 100000);
  bench_eval("Let", "let x = 1 in x", 100000);
  bench_eval("Addition", "1 + 2 + 3", 100000);
  bench_eval("Field access", "{ x = 1, y = 2 }.x", 100000);
  bench_eval("Record merge", "{ a = 1 } // { b = 2 }", 100000);
  bench_eval("Lambda app", "(\\(x : Natural) -> x) 42", 100000);
  bench_eval("If", "if True then 1 else 2", 100000);
  bench_eval("List", "[1, 2, 3, 4, 5]", 100000);

  // Large record
  std::string large_record = "{ ";
  for (int i = 0; i < 100; i++) {
    if (i > 0)
      large_record += ", ";
    large_record += "field" + std::to_string(i) + " = " + std::to_string(i);
  }
  large_record += " }";
  bench_eval("100-field record", large_record, 10000);

  // Record merge
  std::string merge_expr = "{ ";
  for (int i = 0; i < 50; i++) {
    if (i > 0)
      merge_expr += ", ";
    merge_expr += "a" + std::to_string(i) + " = " + std::to_string(i);
  }
  merge_expr += " } // { ";
  for (int i = 0; i < 50; i++) {
    if (i > 0)
      merge_expr += ", ";
    merge_expr += "b" + std::to_string(i) + " = " + std::to_string(i + 50);
  }
  merge_expr += " }";
  bench_eval("50+50 merge", merge_expr, 10000);

  return 0;
}
