// Continuity.Codec.Dhall - Parallel HTTP/2 Fetcher using evring
// Multiplexes requests on single connection for maximum throughput
//
// straylight.software · 2026

#pragma once

#include <chrono>
#include <cstring>
#include <format>
#include <map>
#include <string>
#include <string_view>
#include <vector>

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <spdlog/spdlog.h>
#include <sys/socket.h>

#include "straylight/evring/evring.h"
#include "straylight/evring/http2.h"
#include "straylight/evring/tls.h"

namespace continuity::dhall {

// ═══════════════════════════════════════════════════════════════════════════════
// PARSED URL
// ═══════════════════════════════════════════════════════════════════════════════

struct ParsedUrl {
  std::string scheme;
  std::string host;
  std::string port;
  std::string path;
  bool valid{false};

  static ParsedUrl parse(std::string_view url) {
    ParsedUrl result;

    if (url.starts_with("https://")) {
      result.scheme = "https";
      url.remove_prefix(8);
    } else if (url.starts_with("http://")) {
      result.scheme = "http";
      url.remove_prefix(7);
    } else {
      return result; // invalid
    }

    auto path_pos = url.find('/');
    std::string_view authority;
    if (path_pos != std::string_view::npos) {
      authority = url.substr(0, path_pos);
      result.path = std::string(url.substr(path_pos));
    } else {
      authority = url;
      result.path = "/";
    }

    auto port_pos = authority.find(':');
    if (port_pos != std::string_view::npos) {
      result.host = std::string(authority.substr(0, port_pos));
      result.port = std::string(authority.substr(port_pos + 1));
    } else {
      result.host = std::string(authority);
      result.port = (result.scheme == "https") ? "443" : "80";
    }

    result.valid = !result.host.empty();
    return result;
  }

  std::string origin() const { return scheme + "://" + host + ":" + port; }
};

// ═══════════════════════════════════════════════════════════════════════════════
// FETCH RESULT
// ═══════════════════════════════════════════════════════════════════════════════

struct Http2FetchResult {
  std::string url;
  std::string content;
  std::string error;
  int status_code{0};
  bool success{false};
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONNECTION STATE
// ═══════════════════════════════════════════════════════════════════════════════

struct Http2Connection {
  std::string origin; // https://host:port
  evring::handle socket;
  std::unique_ptr<evring::tls_connection> tls;
  std::unique_ptr<evring::http2_session> session;
  bool connected{false};

  // Pending requests: stream_id -> (url, result_index)
  std::map<std::int32_t, std::pair<std::string, std::size_t>> pending_requests;
};

// ═══════════════════════════════════════════════════════════════════════════════
// PARALLEL HTTP/2 FETCHER
// ═══════════════════════════════════════════════════════════════════════════════

class Http2Fetcher {
  std::unique_ptr<evring::ring> ring_;
  std::map<std::string, Http2Connection> connections_; // origin -> connection

  std::size_t total_requests_{0};
  std::size_t completed_requests_{0};
  std::size_t bytes_fetched_{0};

public:
  Http2Fetcher() : ring_(evring::make_io_uring_ring(1024, evring::ring_flags::single_issuer)) {}

  /// Fetch multiple URLs in parallel, returns results in same order
  std::vector<Http2FetchResult> fetch_batch(const std::vector<std::string>& urls) {
    auto start = std::chrono::high_resolution_clock::now();

    std::vector<Http2FetchResult> results(urls.size());
    for (std::size_t i = 0; i < urls.size(); ++i) {
      results[i].url = urls[i];
    }

    // Group URLs by origin
    std::map<std::string, std::vector<std::pair<std::size_t, ParsedUrl>>> by_origin;
    for (std::size_t i = 0; i < urls.size(); ++i) {
      auto parsed = ParsedUrl::parse(urls[i]);
      if (!parsed.valid) {
        results[i].error = "Invalid URL";
        continue;
      }
      if (parsed.scheme != "https") {
        results[i].error = "Only HTTPS supported";
        continue;
      }
      by_origin[parsed.origin()].push_back({i, std::move(parsed)});
    }

    // Process each origin
    for (auto& [origin, url_list] : by_origin) {
      fetch_from_origin(origin, url_list, results);
    }

    auto end = std::chrono::high_resolution_clock::now();
    auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

    spdlog::info("HTTP/2 batch fetch: {} URLs in {} ms ({} bytes)", urls.size(), duration_ms,
                 bytes_fetched_);

    return results;
  }

  std::size_t bytes_fetched() const { return bytes_fetched_; }

private:
  evring::handle tcp_connect(const std::string& host, const std::string& port) {
    struct addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* result = nullptr;
    int gai_result = getaddrinfo(host.c_str(), port.c_str(), &hints, &result);
    if (gai_result != 0) {
      spdlog::error("DNS resolution failed for {}: {}", host, gai_strerror(gai_result));
      return evring::handle::invalid();
    }

    ring_->enqueue(evring::operation::make_socket(AF_INET, SOCK_STREAM, 0, SOCK_CLOEXEC));
    auto events = ring_->submit_and_wait(1);
    if (!events[0].ok()) {
      spdlog::error("Socket creation failed: {}", events[0].error_code());
      freeaddrinfo(result);
      return evring::handle::invalid();
    }

    evring::handle socket = events[0].resource_handle;

    ring_->enqueue(evring::operation::make_connect(socket, result->ai_addr,
                                                   static_cast<std::uint32_t>(result->ai_addrlen)));
    events = ring_->submit_and_wait(1);
    freeaddrinfo(result);

    if (!events[0].ok()) {
      spdlog::error("TCP connect failed: {}", events[0].error_code());
      ring_->enqueue(evring::operation::make_close(socket));
      ring_->submit_and_wait(1);
      return evring::handle::invalid();
    }

    return socket;
  }

  bool establish_tls(Http2Connection& conn, const std::string& host) {
    auto tls_config = evring::tls_client_config::create_default();
    if (!tls_config.set_alpn("h2")) {
      spdlog::error("Failed to set ALPN");
      return false;
    }

    evring::tls_handshake_machine tls_hs{conn.socket, *ring_, tls_config, host};
    auto tls_state = evring::run(tls_hs, *ring_);

    if (!tls_state.ok()) {
      spdlog::error("TLS handshake failed: {}", tls_state.error_message);
      return false;
    }

    conn.tls = std::make_unique<evring::tls_connection>(tls_state.take_context());

    const char* alpn = conn.tls->alpn_selected();
    if (!alpn || std::strcmp(alpn, "h2") != 0) {
      spdlog::error("Server doesn't support HTTP/2, ALPN: {}", alpn ? alpn : "none");
      return false;
    }

    return true;
  }

  bool establish_http2(Http2Connection& conn) {
    conn.session = std::make_unique<evring::http2_session>();
    if (!conn.session->init_client()) {
      spdlog::error("Failed to init HTTP/2 session");
      return false;
    }

    evring::http2_connection_machine conn_machine{*conn.session, *conn.tls, conn.socket};
    auto conn_state = evring::run(conn_machine, *ring_);

    if (!conn_state.ok()) {
      spdlog::error("HTTP/2 connection failed: {}", conn_state.error_message);
      return false;
    }

    conn.connected = true;
    return true;
  }

  void fetch_from_origin(const std::string& origin,
                         std::vector<std::pair<std::size_t, ParsedUrl>>& url_list,
                         std::vector<Http2FetchResult>& results) {
    if (url_list.empty())
      return;

    // Get or create connection
    auto& conn = connections_[origin];
    if (!conn.connected) {
      const auto& first_url = url_list[0].second;
      conn.origin = origin;

      spdlog::debug("Connecting to {}", origin);

      conn.socket = tcp_connect(first_url.host, first_url.port);
      if (!conn.socket.valid()) {
        for (auto& [idx, _] : url_list) {
          results[idx].error = "TCP connect failed";
        }
        return;
      }

      if (!establish_tls(conn, first_url.host)) {
        for (auto& [idx, _] : url_list) {
          results[idx].error = "TLS handshake failed";
        }
        ring_->enqueue(evring::operation::make_close(conn.socket));
        ring_->submit_and_wait(1);
        return;
      }

      if (!establish_http2(conn)) {
        for (auto& [idx, _] : url_list) {
          results[idx].error = "HTTP/2 connection failed";
        }
        ring_->enqueue(evring::operation::make_close(conn.socket));
        ring_->submit_and_wait(1);
        return;
      }

      spdlog::debug("HTTP/2 connection established to {}", origin);
    }

    // Submit all requests (HTTP/2 multiplexing)
    for (auto& [idx, parsed] : url_list) {
      evring::http2_request req;
      req.method = "GET";
      req.scheme = parsed.scheme;
      req.authority = parsed.host;
      if (parsed.port != "443") {
        req.authority += ":" + parsed.port;
      }
      req.path = parsed.path;
      req.headers.push_back({"user-agent", "continuity-dhall/1.0"});
      req.headers.push_back({"accept", "*/*"});

      evring::http2_request_machine req_machine{*conn.session, *conn.tls, conn.socket, req};
      auto req_state = evring::run(req_machine, *ring_);

      if (!req_state.ok()) {
        results[idx].error = req_state.error_message;
        results[idx].success = false;
      } else {
        results[idx].status_code = req_state.response.status_code;
        if (req_state.response.status_code == 200) {
          results[idx].content.assign(reinterpret_cast<const char*>(req_state.response.body.data()),
                                      req_state.response.body.size());
          results[idx].success = true;
          bytes_fetched_ += results[idx].content.size();
        } else {
          results[idx].error = std::format("HTTP {}", req_state.response.status_code);
          results[idx].success = false;
        }
      }
    }
  }
};

} // namespace continuity::dhall
