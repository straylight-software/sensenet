#include "parser.hpp"
#include <iostream>
#include <chrono>

using namespace continuity::dhall;

void bench(const std::string& src, int iterations) {
  Arena arena;
  Interner interner;
  
  Parser parser(src, arena, interner);
  auto result = parser.parse();
  
  if (!result) {
    std::cout << "Parse error\n";
    return;
  }
  
  Evaluator eval(arena, interner);
  
  auto start = std::chrono::high_resolution_clock::now();
  
  for (int i = 0; i < iterations; i++) {
    Env env;
    eval.eval(env, *result);
  }
  
  auto end = std::chrono::high_resolution_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
  
  std::cout << src.substr(0, 50) << "...: " << iterations << " iters in " 
            << us << " us (" << (us * 1000 / iterations) << " ns/iter)\n";
}

int main() {
  bench("42", 100000);
  bench("let x = 1 in x", 100000);
  bench("1 + 2 + 3", 100000);
  bench("{ x = 1, y = 2 }.x", 100000);
  bench("{ a = 1 } // { b = 2 }", 100000);
  bench("(\\(x : Natural) -> x) 42", 100000);
  bench("if True then 1 else 2", 100000);
  bench("[1, 2, 3, 4, 5]", 100000);
  
  // Larger record
  std::string large = "{ ";
  for (int i = 0; i < 100; i++) {
    if (i > 0) large += ", ";
    large += "f" + std::to_string(i) + " = " + std::to_string(i);
  }
  large += " }";
  bench(large, 10000);
  
  // Record merge
  std::string merge = "{ ";
  for (int i = 0; i < 50; i++) {
    if (i > 0) merge += ", ";
    merge += "a" + std::to_string(i) + " = " + std::to_string(i);
  }
  merge += " } // { ";
  for (int i = 0; i < 50; i++) {
    if (i > 0) merge += ", ";
    merge += "b" + std::to_string(i) + " = " + std::to_string(i);
  }
  merge += " }";
  bench(merge, 10000);
  
  return 0;
}
