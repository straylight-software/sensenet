// Continuity.Codec.Dhall - Kubernetes Benchmark
// Fetch and evaluate dhall-kubernetes from GitHub
//
// straylight.software · 2026

#include <chrono>
#include <filesystem>
#include <format>
#include <fstream>
#include <vector>

#include <spdlog/spdlog.h>

#include "async_import.hpp"
#include "parser.hpp"

namespace fs = std::filesystem;
using namespace continuity::dhall;

int main(int argc, char** argv) {
  spdlog::set_level(spdlog::level::info);
  spdlog::info("Continuity.Codec.Dhall - Kubernetes Benchmark");

  // dhall-kubernetes 1.30 from GitHub
  std::string k8s_url =
      "https://raw.githubusercontent.com/dhall-lang/dhall-kubernetes/master/1.30/package.dhall";

  // Check for --h2 flag to use evring HTTP/2 instead of curl -Z
  bool use_h2 = false;
  for (int i = 1; i < argc; ++i) {
    std::string_view arg = argv[i];
    if (arg == "--h2") {
      use_h2 = true;
    } else if (!arg.starts_with("-")) {
      k8s_url = std::string(arg);
    }
  }

  spdlog::info("Fetching: {} ({})", k8s_url, use_h2 ? "evring HTTP/2" : "curl -Z");

  Arena arena;
  Interner interner;
  AsyncImportResolver resolver(arena, interner);

  auto start = std::chrono::high_resolution_clock::now();

  try {
    // Wave-based HTTP resolution: fetch all imports in parallel batches
    // This pre-populates the cache with all HTTP-fetched files
    auto wave_start = std::chrono::high_resolution_clock::now();
    if (use_h2) {
      resolver.resolve_http_waves_h2(k8s_url);
    } else {
      resolver.resolve_http_waves(k8s_url);
    }
    auto wave_end = std::chrono::high_resolution_clock::now();

    spdlog::info(
        "Wave fetch time: {:.3f} ms (cache: {} files)",
        std::chrono::duration_cast<std::chrono::microseconds>(wave_end - wave_start).count() /
            1000.0,
        resolver.cache_size());

    // Create a dummy file that imports the k8s package
    std::string source = std::format("let k8s = {} in k8s", k8s_url);

    // Parse
    auto parse_start = std::chrono::high_resolution_clock::now();
    Parser parser(source, arena, interner);
    auto result = parser.parse();
    auto parse_end = std::chrono::high_resolution_clock::now();

    if (!result) {
      spdlog::error("Parse error: {}", result.error().message);
      return 1;
    }

    spdlog::info(
        "Parse time: {:.3f} ms",
        std::chrono::duration_cast<std::chrono::microseconds>(parse_end - parse_start).count() /
            1000.0);

    // Resolve imports (should be fast - everything is already in cache from waves)
    auto resolve_start = std::chrono::high_resolution_clock::now();
    auto* resolved = resolver.resolve(*result, fs::current_path());
    auto resolve_end = std::chrono::high_resolution_clock::now();

    spdlog::info(
        "Resolve time: {:.3f} ms (cache: {} files)",
        std::chrono::duration_cast<std::chrono::microseconds>(resolve_end - resolve_start).count() /
            1000.0,
        resolver.cache_size());

    // Evaluate with value caching
    auto eval_start = std::chrono::high_resolution_clock::now();
    Evaluator eval(arena, interner);
    eval.set_import_callback([&resolver](Evaluator& e, std::string_view abs_path) -> ValuePtr {
      return resolver.eval_import(std::string(abs_path), e);
    });

    Env env;
    auto* value = eval.eval(env, resolved);
    auto eval_end = std::chrono::high_resolution_clock::now();

    spdlog::info(
        "Eval time: {:.3f} ms (value cache: {} values)",
        std::chrono::duration_cast<std::chrono::microseconds>(eval_end - eval_start).count() /
            1000.0,
        resolver.value_cache_size());

    auto total_end = std::chrono::high_resolution_clock::now();
    auto total_time =
        std::chrono::duration_cast<std::chrono::milliseconds>(total_end - start).count();

    spdlog::info("Total time: {} ms", total_time);

    // Check result type
    if (value->kind == Value::Kind::RecordLit) {
      spdlog::info("Result: Record with {} fields", value->fields->size());
    } else {
      spdlog::info("Result: Value kind {}", static_cast<int>(value->kind));
    }

    return 0;

  } catch (const std::exception& e) {
    spdlog::error("Error: {}", e.what());
    return 1;
  }
}
