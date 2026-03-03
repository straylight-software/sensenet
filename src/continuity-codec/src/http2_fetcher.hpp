// Continuity.Codec.Dhall - Parallel HTTP/2 Fetcher using evring
// Multiplexes ALL requests on single connection - no waves, just blast
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
#include <poll.h>
#include <spdlog/spdlog.h>
#include <sys/socket.h>
#include <tls.h>

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
// PARALLEL HTTP/2 FETCHER - BLAST ALL REQUESTS AT ONCE
// ═══════════════════════════════════════════════════════════════════════════════

class Http2Fetcher {
  std::unique_ptr<evring::ring> ring_;
  std::size_t bytes_fetched_{0};

public:
  Http2Fetcher() : ring_(evring::make_io_uring_ring(4096, evring::ring_flags::single_issuer)) {}

  /// Fetch multiple URLs in parallel, returns results in same order
  std::vector<Http2FetchResult> fetch_batch(const std::vector<std::string>& urls) {
    auto start = std::chrono::high_resolution_clock::now();
    bytes_fetched_ = 0;

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

    // Process each origin (typically just one for dhall-kubernetes)
    for (auto& [origin, url_list] : by_origin) {
      fetch_from_origin_parallel(origin, url_list, results);
    }

    auto end = std::chrono::high_resolution_clock::now();
    auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

    spdlog::info("HTTP/2 parallel fetch: {} URLs in {} ms ({:.2f} MB, {:.1f} MB/s)", urls.size(),
                 duration_ms, bytes_fetched_ / 1048576.0,
                 duration_ms > 0 ? (bytes_fetched_ / 1048576.0) / (duration_ms / 1000.0) : 0);

    return results;
  }

  std::size_t bytes_fetched() const { return bytes_fetched_; }

private:
  // TCP connect using io_uring
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

  // TLS handshake with ALPN h2
  std::unique_ptr<evring::tls_connection> establish_tls(evring::handle socket,
                                                        const std::string& host) {
    auto tls_config = evring::tls_client_config::create_default();
    if (!tls_config.set_alpn("h2")) {
      spdlog::error("Failed to set ALPN");
      return nullptr;
    }

    evring::tls_handshake_machine tls_hs{socket, *ring_, tls_config, host};
    auto tls_state = evring::run(tls_hs, *ring_);

    if (!tls_state.ok()) {
      spdlog::error("TLS handshake failed: {}", tls_state.error_message);
      return nullptr;
    }

    auto tls_conn = std::make_unique<evring::tls_connection>(tls_state.take_context());

    const char* alpn = tls_conn->alpn_selected();
    if (!alpn || std::strcmp(alpn, "h2") != 0) {
      spdlog::error("Server doesn't support HTTP/2, ALPN: {}", alpn ? alpn : "none");
      return nullptr;
    }

    return tls_conn;
  }

  // Establish HTTP/2 connection (send preface, receive SETTINGS)
  bool establish_http2(evring::http2_session& session, evring::tls_connection& tls,
                       evring::handle socket) {
    if (!session.init_client()) {
      spdlog::error("Failed to init HTTP/2 session");
      return false;
    }

    evring::http2_connection_machine conn_machine{session, tls, socket};
    auto conn_state = evring::run(conn_machine, *ring_);

    if (!conn_state.ok()) {
      spdlog::error("HTTP/2 connection failed: {}", conn_state.error_message);
      return false;
    }

    return true;
  }

  // BLAST all requests at once, then read all responses
  void fetch_from_origin_parallel(const std::string& origin,
                                  std::vector<std::pair<std::size_t, ParsedUrl>>& url_list,
                                  std::vector<Http2FetchResult>& results) {
    if (url_list.empty())
      return;

    const auto& first_url = url_list[0].second;

    spdlog::info("Connecting to {} for {} URLs", origin, url_list.size());

    // 1. TCP connect
    evring::handle socket = tcp_connect(first_url.host, first_url.port);
    if (!socket.valid()) {
      for (auto& [idx, _] : url_list) {
        results[idx].error = "TCP connect failed";
      }
      return;
    }

    // 2. TLS handshake
    auto tls = establish_tls(socket, first_url.host);
    if (!tls) {
      for (auto& [idx, _] : url_list) {
        results[idx].error = "TLS handshake failed";
      }
      ring_->enqueue(evring::operation::make_close(socket));
      ring_->submit_and_wait(1);
      return;
    }

    // 3. HTTP/2 connection setup
    evring::http2_session session;
    if (!establish_http2(session, *tls, socket)) {
      for (auto& [idx, _] : url_list) {
        results[idx].error = "HTTP/2 connection failed";
      }
      ring_->enqueue(evring::operation::make_close(socket));
      ring_->submit_and_wait(1);
      return;
    }

    spdlog::info("HTTP/2 connected, blasting {} requests", url_list.size());

    // 4. BLAST ALL REQUESTS AT ONCE
    // Map stream_id -> result index
    std::map<std::int32_t, std::size_t> stream_to_result;
    std::size_t streams_pending = 0;

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

      std::int32_t stream_id = session.submit_request(req);
      if (stream_id > 0) {
        stream_to_result[stream_id] = idx;
        streams_pending++;
      } else {
        results[idx].error = "Failed to submit request";
      }
    }

    spdlog::debug("Submitted {} streams", streams_pending);

    // 5. Send all pending request frames
    int socket_fd = ring_->get_file_descriptor(socket);
    auto pending = session.get_pending_data();
    while (!pending.empty()) {
      ssize_t written = tls_write(tls->raw(), pending.data(), pending.size());
      if (written > 0) {
        pending.erase(pending.begin(), pending.begin() + written);
      } else if (written == TLS_WANT_POLLIN || written == TLS_WANT_POLLOUT) {
        // Need to poll
        struct pollfd pfd{};
        pfd.fd = socket_fd;
        pfd.events = (written == TLS_WANT_POLLIN) ? POLLIN : POLLOUT;
        poll(&pfd, 1, 1000);
      } else {
        spdlog::error("TLS write error: {}", tls_error(tls->raw()));
        break;
      }
    }

    spdlog::debug("All requests sent, reading responses");

    // 6. Read all responses
    std::byte buffer[65536];
    while (streams_pending > 0) {
      ssize_t nread = tls_read(tls->raw(), buffer, sizeof(buffer));

      if (nread > 0) {
        auto consumed = session.receive_data(std::span<const std::byte>(buffer, nread));
        if (consumed < 0) {
          spdlog::error("nghttp2 receive error");
          break;
        }

        // Check for completed streams
        for (auto it = stream_to_result.begin(); it != stream_to_result.end();) {
          std::int32_t stream_id = it->first;
          std::size_t result_idx = it->second;

          if (session.is_stream_closed(stream_id)) {
            auto* resp = session.get_stream_response(stream_id);
            if (resp) {
              results[result_idx].status_code = resp->status_code;
              if (resp->status_code == 200) {
                results[result_idx].content.assign(reinterpret_cast<const char*>(resp->body.data()),
                                                   resp->body.size());
                results[result_idx].success = true;
                bytes_fetched_ += results[result_idx].content.size();
              } else {
                results[result_idx].error = std::format("HTTP {}", resp->status_code);
              }
            } else {
              auto err = session.get_stream_error(stream_id);
              results[result_idx].error =
                  std::format("Stream error: {}", evring::http2_error_string(err));
            }
            it = stream_to_result.erase(it);
            streams_pending--;
          } else {
            ++it;
          }
        }

        // Send any pending data (like WINDOW_UPDATE)
        pending = session.get_pending_data();
        while (!pending.empty()) {
          ssize_t written = tls_write(tls->raw(), pending.data(), pending.size());
          if (written > 0) {
            pending.erase(pending.begin(), pending.begin() + written);
          } else if (written == TLS_WANT_POLLIN || written == TLS_WANT_POLLOUT) {
            struct pollfd pfd{};
            pfd.fd = socket_fd;
            pfd.events = (written == TLS_WANT_POLLIN) ? POLLIN : POLLOUT;
            poll(&pfd, 1, 100);
          } else {
            break;
          }
        }
      } else if (nread == TLS_WANT_POLLIN || nread == TLS_WANT_POLLOUT) {
        struct pollfd pfd{};
        pfd.fd = socket_fd;
        pfd.events = (nread == TLS_WANT_POLLIN) ? POLLIN : POLLOUT;
        poll(&pfd, 1, 1000);
      } else if (nread == 0) {
        spdlog::warn("Connection closed with {} streams pending", streams_pending);
        break;
      } else {
        spdlog::error("TLS read error: {}", tls_error(tls->raw()));
        break;
      }
    }

    // Mark any remaining streams as failed
    for (auto& [stream_id, result_idx] : stream_to_result) {
      if (!results[result_idx].success && results[result_idx].error.empty()) {
        results[result_idx].error = "Connection closed before response";
      }
    }

    // Cleanup
    ring_->enqueue(evring::operation::make_close(socket));
    ring_->submit_and_wait(1);

    spdlog::info("Fetch complete: {} bytes", bytes_fetched_);
  }
};

} // namespace continuity::dhall
