// Continuity.Codec.Dhall - Async Batch Evaluator
// Evaluate all BUILD.dhall files using io_uring batched I/O
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

// Read file contents
std::string read_file(const fs::path& path) {
  std::ifstream file(path, std::ios::ate | std::ios::binary);
  if (!file) {
    throw std::runtime_error(std::format("Cannot open: {}", path.string()));
  }
  auto size = file.tellg();
  file.seekg(0);
  std::string content(static_cast<std::size_t>(size), '\0');
  file.read(content.data(), size);
  return content;
}

// Find all BUILD.dhall files
std::vector<fs::path> find_build_files(const fs::path& root) {
  std::vector<fs::path> files;
  for (auto& entry : fs::recursive_directory_iterator(root)) {
    if (entry.is_regular_file() && entry.path().filename() == "BUILD.dhall") {
      // Skip vendor and .haskell-sources directories
      auto path_str = entry.path().string();
      if (path_str.find("vendor/") != std::string::npos)
        continue;
      if (path_str.find(".haskell-sources") != std::string::npos)
        continue;
      files.push_back(entry.path());
    }
  }
  return files;
}

// Parse and evaluate a single file (with async import resolution and value caching)
bool process_file(Arena& arena, Interner& interner, AsyncImportResolver& resolver, Evaluator& eval,
                  const fs::path& path, std::chrono::microseconds& parse_time,
                  std::chrono::microseconds& resolve_time, std::chrono::microseconds& eval_time) {
  try {
    auto source = read_file(path);

    // Parse
    auto parse_start = std::chrono::high_resolution_clock::now();
    Parser parser(source, arena, interner);
    auto result = parser.parse();
    auto parse_end = std::chrono::high_resolution_clock::now();
    parse_time = std::chrono::duration_cast<std::chrono::microseconds>(parse_end - parse_start);

    if (!result) {
      spdlog::error("Parse error in {}: {}", path.string(), result.error().message);
      return false;
    }

    // Resolve imports (loads files, keeps Import nodes with abs_path)
    auto resolve_start = std::chrono::high_resolution_clock::now();
    auto* resolved = resolver.resolve(*result, path.parent_path());
    auto resolve_end = std::chrono::high_resolution_clock::now();
    resolve_time =
        std::chrono::duration_cast<std::chrono::microseconds>(resolve_end - resolve_start);

    // Evaluate (import callback uses value caching)
    auto eval_start = std::chrono::high_resolution_clock::now();
    Env env;
    auto* value = eval.eval(env, resolved);
    auto eval_end = std::chrono::high_resolution_clock::now();
    eval_time = std::chrono::duration_cast<std::chrono::microseconds>(eval_end - eval_start);

    // Verify we got a record with targets
    if (value->kind != Value::Kind::RecordLit) {
      spdlog::warn("{} did not evaluate to a record", path.string());
    }

    return true;
  } catch (const std::exception& e) {
    spdlog::error("Error processing {}: {}", path.string(), e.what());
    return false;
  }
}

int main(int argc, char** argv) {
  fs::path root = ".";
  if (argc > 1) {
    root = argv[1];
  }

  spdlog::info("Continuity.Codec.Dhall Async Batch Evaluator (io_uring)");

  // Find all BUILD.dhall files
  auto files = find_build_files(root);
  spdlog::info("Found {} BUILD.dhall files", files.size());

  // Process all files with shared async resolver and value caching
  Arena arena;
  Interner interner;
  AsyncImportResolver resolver(arena, interner);

  // Create evaluator with import callback for value caching
  Evaluator eval(arena, interner);
  eval.set_import_callback([&resolver](Evaluator& e, std::string_view abs_path) -> ValuePtr {
    return resolver.eval_import(std::string(abs_path), e);
  });

  std::chrono::microseconds total_parse{0};
  std::chrono::microseconds total_resolve{0};
  std::chrono::microseconds total_eval{0};
  int success_count = 0;
  int fail_count = 0;

  auto batch_start = std::chrono::high_resolution_clock::now();

  for (const auto& file : files) {
    std::chrono::microseconds parse_time{0};
    std::chrono::microseconds resolve_time{0};
    std::chrono::microseconds eval_time{0};

    if (process_file(arena, interner, resolver, eval, file, parse_time, resolve_time, eval_time)) {
      success_count++;
      total_parse += parse_time;
      total_resolve += resolve_time;
      total_eval += eval_time;
      spdlog::debug("OK: {} (parse: {} us, resolve: {} us, eval: {} us)", file.string(),
                    parse_time.count(), resolve_time.count(), eval_time.count());
    } else {
      fail_count++;
      spdlog::error("FAIL: {}", file.string());
    }
  }

  auto batch_end = std::chrono::high_resolution_clock::now();
  auto total_time = std::chrono::duration_cast<std::chrono::microseconds>(batch_end - batch_start);

  spdlog::info("Results: {}/{} success, {} failed", success_count, files.size(), fail_count);
  spdlog::info("Import cache: {} files, value cache: {} values", resolver.cache_size(),
               resolver.value_cache_size());
  spdlog::info("Timing - parse: {:.3f} ms, resolve: {:.3f} ms, eval: {:.3f} ms, total: {:.3f} ms",
               total_parse.count() / 1000.0, total_resolve.count() / 1000.0,
               total_eval.count() / 1000.0, total_time.count() / 1000.0);

  if (total_time.count() < 10000) {
    spdlog::info("TARGET MET: Total time < 10ms");
  } else {
    spdlog::warn("Target missed: {:.3f} ms > 10 ms", total_time.count() / 1000.0);
  }

  return fail_count > 0 ? 1 : 0;
}
