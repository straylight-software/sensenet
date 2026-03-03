// Continuity.Codec.Dhall Benchmark
// straylight.software · 2026

#include <chrono>
#include <functional>
#include <iostream>

#include "dhall.hpp"

using namespace continuity::dhall;

// Build a single record with N fields starting at offset
ExprPtr buildRecord(Arena& arena, Interner& interner, int offset, int fieldsPerRecord) {
  auto* fields = arena.alloc<Fields<ExprPtr>>();
  for (int i = 0; i < fieldsPerRecord; ++i) {
    int idx = offset + i;
    auto* lit = arena.alloc<Expr>();
    lit->kind = Expr::Kind::Lit;
    lit->lit = Lit::Nat(static_cast<std::uint64_t>(idx));
    fields->insert(interner.intern(std::to_string(idx)), lit);
  }
  auto* rec = arena.alloc<Expr>();
  rec->kind = Expr::Kind::RecordLit;
  rec->fields = fields;
  return rec;
}

// Build a chain of N record merges, M fields each (iterative)
ExprPtr buildRecordChain(Arena& arena, Interner& interner, int depth, int fieldsPerRecord) {
  ExprPtr result = buildRecord(arena, interner, 0, fieldsPerRecord);

  for (int d = 1; d <= depth; ++d) {
    auto* rec = buildRecord(arena, interner, d * fieldsPerRecord, fieldsPerRecord);
    auto* prefer = arena.alloc<Expr>();
    prefer->kind = Expr::Kind::Prefer;
    prefer->binop = {result, rec};
    result = prefer;
  }

  return result;
}

// Build evring pattern
ExprPtr buildEvringPattern(Arena& arena, Interner& interner) {
  auto n100 = interner.intern("100");
  auto n101 = interner.intern("cxx_binary");
  auto n102 = interner.intern("name");
  auto n103 = interner.intern("srcs");
  auto n104 = interner.intern("deps");
  auto n105 = interner.intern("target");

  // { cxx_binary = λname. λsrcs. { name, srcs, deps = [] } }
  auto* innerFields = arena.alloc<Fields<ExprPtr>>();

  // name = var 1
  auto* var1 = arena.alloc<Expr>();
  var1->kind = Expr::Kind::Var;
  var1->var_idx = 1;
  innerFields->insert(n102, var1);

  // srcs = var 0
  auto* var0 = arena.alloc<Expr>();
  var0->kind = Expr::Kind::Var;
  var0->var_idx = 0;
  innerFields->insert(n103, var0);

  // deps = []
  auto* emptyList = arena.alloc<Expr>();
  emptyList->kind = Expr::Kind::List;
  emptyList->list = {nullptr, nullptr, 0};
  innerFields->insert(n104, emptyList);

  auto* innerRec = arena.alloc<Expr>();
  innerRec->kind = Expr::Kind::RecordLit;
  innerRec->fields = innerFields;

  // λsrcs. { ... }
  auto* lamSrcs = arena.alloc<Expr>();
  lamSrcs->kind = Expr::Kind::Lam;
  auto* listType = arena.alloc<Expr>();
  listType->kind = Expr::Kind::Builtin;
  listType->builtin = Builtin::List;
  lamSrcs->lam = {n103, listType, innerRec};

  // λname. λsrcs. { ... }
  auto* lamName = arena.alloc<Expr>();
  lamName->kind = Expr::Kind::Lam;
  auto* textType = arena.alloc<Expr>();
  textType->kind = Expr::Kind::Builtin;
  textType->builtin = Builtin::Text;
  lamName->lam = {n102, textType, lamSrcs};

  // { cxx_binary = λname. λsrcs. { ... } }
  auto* eFields = arena.alloc<Fields<ExprPtr>>();
  eFields->insert(n101, lamName);

  auto* eRec = arena.alloc<Expr>();
  eRec->kind = Expr::Kind::RecordLit;
  eRec->fields = eFields;

  // let E = { cxx_binary = ... }
  // let target = E.cxx_binary "hello" ["main.cxx"]
  // in target.name

  // E.cxx_binary
  auto* fieldAccess = arena.alloc<Expr>();
  fieldAccess->kind = Expr::Kind::Field;
  auto* varE = arena.alloc<Expr>();
  varE->kind = Expr::Kind::Var;
  varE->var_idx = 0;
  fieldAccess->field = {varE, n101};

  // "hello"
  auto* hello = arena.alloc<Expr>();
  hello->kind = Expr::Kind::Lit;
  hello->lit = Lit::Text("hello", 5);

  // E.cxx_binary "hello"
  auto* app1 = arena.alloc<Expr>();
  app1->kind = Expr::Kind::App;
  app1->app = {fieldAccess, hello};

  // ["main.cxx"]
  auto mainCxx = arena.alloc<Expr>();
  mainCxx->kind = Expr::Kind::Lit;
  mainCxx->lit = Lit::Text("main.cxx", 8);
  auto elemSpan = arena.alloc_array<ExprPtr>(1);
  elemSpan[0] = mainCxx;
  auto* srcsList = arena.alloc<Expr>();
  srcsList->kind = Expr::Kind::List;
  srcsList->list = {nullptr, elemSpan.data(), 1};

  // E.cxx_binary "hello" ["main.cxx"]
  auto* app2 = arena.alloc<Expr>();
  app2->kind = Expr::Kind::App;
  app2->app = {app1, srcsList};

  // target.name
  auto* targetField = arena.alloc<Expr>();
  targetField->kind = Expr::Kind::Field;
  auto* varTarget = arena.alloc<Expr>();
  varTarget->kind = Expr::Kind::Var;
  varTarget->var_idx = 0;
  targetField->field = {varTarget, n102};

  // let target = ... in target.name
  auto* letTarget = arena.alloc<Expr>();
  letTarget->kind = Expr::Kind::Let;
  letTarget->let = {n105, nullptr, app2, targetField};

  // let E = ... in let target = ...
  auto* letE = arena.alloc<Expr>();
  letE->kind = Expr::Kind::Let;
  letE->let = {n100, nullptr, eRec, letTarget};

  return letE;
}

template <typename F>
double timeMs(F&& f) {
  auto start = std::chrono::high_resolution_clock::now();
  f();
  auto end = std::chrono::high_resolution_clock::now();
  return std::chrono::duration<double, std::milli>(end - start).count();
}

int countFields(ExprPtr e) {
  if (e->kind == Expr::Kind::RecordLit)
    return static_cast<int>(e->fields->size());
  return 0;
}

int main() {
  std::cout << "Continuity.Codec.Dhall Benchmark (C++23)\n";
  std::cout << "=========================================\n\n";

  Arena arena;
  Interner interner;
  Evaluator eval(arena, interner);

  std::cout << "Arena and interner initialized\n";

  // Correctness tests
  std::cout << "-- Correctness tests --\n";

  // 1 + 2
  {
    std::cout << "Building 1+2 expr...\n";
    auto* one = arena.alloc<Expr>();
    one->kind = Expr::Kind::Lit;
    one->lit = Lit::Nat(1);
    auto* two = arena.alloc<Expr>();
    two->kind = Expr::Kind::Lit;
    two->lit = Lit::Nat(2);
    auto* add = arena.alloc<Expr>();
    add->kind = Expr::Kind::NatPlus;
    add->binop = {one, two};
    std::cout << "Normalizing...\n";
    auto* result = eval.normalize(add);
    std::cout << "1 + 2 = " << (result->kind == Expr::Kind::Lit ? result->lit.n : 0) << "\n";
  }

  // evring pattern
  {
    auto* evring = buildEvringPattern(arena, interner);
    auto* result = eval.normalize(evring);
    if (result->kind == Expr::Kind::Lit && result->lit.kind == Lit::Kind::Text) {
      std::cout << "evring pattern = \""
                << std::string_view(result->lit.text.data, result->lit.text.len) << "\"\n";
    }
  }

  std::cout << "\n-- Performance benchmarks --\n";

  // 100x10
  {
    arena.reset();
    ExprPtr e;
    double buildTime = timeMs([&] { e = buildRecordChain(arena, interner, 100, 10); });
    ExprPtr result;
    double evalTime = timeMs([&] { result = eval.normalize(e); });
    std::cout << "100x10 (1K fields): build=" << buildTime << "ms eval=" << evalTime << "ms -> "
              << countFields(result) << " fields\n";
  }

  // 500x10
  {
    arena.reset();
    ExprPtr e;
    double buildTime = timeMs([&] { e = buildRecordChain(arena, interner, 500, 10); });
    ExprPtr result;
    double evalTime = timeMs([&] { result = eval.normalize(e); });
    std::cout << "500x10 (5K fields): build=" << buildTime << "ms eval=" << evalTime << "ms -> "
              << countFields(result) << " fields\n";
  }

  // 1000x10
  {
    arena.reset();
    ExprPtr e;
    double buildTime = timeMs([&] { e = buildRecordChain(arena, interner, 1000, 10); });
    ExprPtr result;
    double evalTime = timeMs([&] { result = eval.normalize(e); });
    std::cout << "1000x10 (10K fields): build=" << buildTime << "ms eval=" << evalTime << "ms -> "
              << countFields(result) << " fields\n";
  }

  // 5000x5
  {
    arena.reset();
    ExprPtr e;
    double buildTime = timeMs([&] { e = buildRecordChain(arena, interner, 5000, 5); });
    ExprPtr result;
    double evalTime = timeMs([&] { result = eval.normalize(e); });
    std::cout << "5000x5 (25K fields): build=" << buildTime << "ms eval=" << evalTime << "ms -> "
              << countFields(result) << " fields\n";
  }

  std::cout << "\nDone.\n";
  return 0;
}
