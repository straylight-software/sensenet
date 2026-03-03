// Continuity.Codec.Dhall - HTTP Fetcher (curl subprocess)
// Simple HTTP fetcher using curl for now
// TODO: Move to evring HTTP/2 state machines in libevring
//
// straylight.software · 2026

#pragma once

#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <openssl/sha.h>
#include <spdlog/spdlog.h>

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// HTTP FETCH RESULT
// ═══════════════════════════════════════════════════════════════════════════════

struct HttpFetchResult {
  std::string url;
  std::string content;
  std::string error;
  int http_code{0};
  bool success{false};
};

// ═══════════════════════════════════════════════════════════════════════════════
// SHA256 UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

inline std::string sha256_hex(std::string_view data) {
  unsigned char hash[SHA256_DIGEST_LENGTH];
  SHA256(reinterpret_cast<const unsigned char*>(data.data()), data.size(), hash);

  static const char hex[] = "0123456789abcdef";
  std::string result;
  result.reserve(SHA256_DIGEST_LENGTH * 2);
  for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) {
    result.push_back(hex[hash[i] >> 4]);
    result.push_back(hex[hash[i] & 0x0f]);
  }
  return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HTTP FETCHER (curl subprocess)
// ═══════════════════════════════════════════════════════════════════════════════

class HttpFetcher {
  std::filesystem::path cache_dir_;
  std::size_t bytes_fetched_{0};
  std::size_t cache_hits_{0};
  std::size_t cache_misses_{0};

public:
  HttpFetcher() {
    const char* xdg_cache = std::getenv("XDG_CACHE_HOME");
    if (xdg_cache) {
      cache_dir_ = std::filesystem::path(xdg_cache) / "dhall";
    } else {
      const char* home = std::getenv("HOME");
      if (home) {
        cache_dir_ = std::filesystem::path(home) / ".cache" / "dhall";
      } else {
        cache_dir_ = "/tmp/dhall-cache";
      }
    }

    std::error_code ec;
    std::filesystem::create_directories(cache_dir_, ec);
    spdlog::debug("HTTP fetcher initialized, cache dir: {}", cache_dir_.string());
  }

  HttpFetchResult fetch(const std::string& url, std::string_view expected_hash = {}) {
    HttpFetchResult result;
    result.url = url;

    // Check disk cache first
    if (!expected_hash.empty()) {
      if (auto cached = load_from_cache(expected_hash)) {
        result.content = std::move(*cached);
        result.success = true;
        result.http_code = 200;
        cache_hits_++;
        return result;
      }
      cache_misses_++;
    }

    // Fetch via curl
    std::string cmd = "curl -sS --fail --http2 '" + url + "' 2>&1";

    std::array<char, 4096> buffer;
    std::string output;

    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) {
      result.error = "Failed to run curl";
      return result;
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
      output += buffer.data();
    }

    int status = pclose(pipe.release());
    if (status != 0) {
      result.error = output.empty() ? "curl failed" : output;
      return result;
    }

    result.content = std::move(output);
    result.success = true;
    result.http_code = 200;
    bytes_fetched_ += result.content.size();

    // Cache by hash
    if (!expected_hash.empty()) {
      store_in_cache(expected_hash, result.content);
    }

    return result;
  }

  /// Fetch multiple URLs in parallel using curl -Z (HTTP/2 multiplexing)
  /// Returns results in same order as input URLs
  /// max_parallel=500 reduces curl subprocess overhead (GitHub CDN handles it fine)
  std::vector<HttpFetchResult> fetch_batch(const std::vector<std::string>& urls,
                                           std::size_t max_parallel = 500) {
    std::vector<HttpFetchResult> results(urls.size());

    for (std::size_t batch_start = 0; batch_start < urls.size(); batch_start += max_parallel) {
      std::size_t batch_end = std::min(batch_start + max_parallel, urls.size());

      // Pre-size command string: base ~60 + per-url ~100
      std::string cmd;
      cmd.reserve(64 + (batch_end - batch_start) * 128);

      std::format_to(std::back_inserter(cmd), "curl -Z --parallel-max {} --fail --http2 -sS",
                     batch_end - batch_start);

      for (std::size_t i = batch_start; i < batch_end; ++i) {
        std::format_to(std::back_inserter(cmd), " -o /tmp/dhall_{}.tmp '{}'", i, urls[i]);
      }

      spdlog::debug("Parallel fetch {}-{}/{}", batch_start, batch_end, urls.size());

      [[maybe_unused]] int status = std::system(cmd.c_str());

      for (std::size_t i = batch_start; i < batch_end; ++i) {
        results[i].url = urls[i];
        auto tmp_path = std::format("/tmp/dhall_{}.tmp", i);

        std::ifstream file(tmp_path, std::ios::ate | std::ios::binary);
        if (file) {
          auto size = file.tellg();
          file.seekg(0);
          results[i].content.resize(static_cast<std::size_t>(size));
          file.read(results[i].content.data(), size);
          results[i].success = true;
          results[i].http_code = 200;
          bytes_fetched_ += results[i].content.size();
          std::filesystem::remove(tmp_path);
        } else {
          results[i].error = "fetch failed";
          results[i].success = false;
        }
      }
    }

    return results;
  }

  std::size_t bytes_fetched() const { return bytes_fetched_; }
  std::size_t cache_hits() const { return cache_hits_; }
  std::size_t cache_misses() const { return cache_misses_; }

private:
  std::optional<std::string> load_from_cache(std::string_view hash) {
    if (hash.size() != 64)
      return std::nullopt;

    std::filesystem::path cache_path = cache_dir_ / hash.substr(0, 2) / hash;

    std::error_code ec;
    if (!std::filesystem::exists(cache_path, ec))
      return std::nullopt;

    std::ifstream file(cache_path, std::ios::binary | std::ios::ate);
    if (!file)
      return std::nullopt;

    auto size = file.tellg();
    file.seekg(0);
    std::string content(static_cast<size_t>(size), '\0');
    file.read(content.data(), size);

    return content;
  }

  void store_in_cache(std::string_view hash, std::string_view content) {
    if (hash.size() != 64)
      return;

    std::filesystem::path dir = cache_dir_ / hash.substr(0, 2);
    std::filesystem::path cache_path = dir / hash;

    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec)
      return;

    std::ofstream file(cache_path, std::ios::binary);
    if (file) {
      file.write(content.data(), static_cast<std::streamsize>(content.size()));
    }
  }
};

} // namespace continuity::dhall
