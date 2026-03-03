// Continuity.Codec - UTF-8 Support
//
// Zero-dependency UTF-8 handling for LL(k) parsing.
// Following the Dhall grammar's valid-non-ascii rule.
//
// straylight.software - 2026

#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace continuity::codec::utf8 {

// Invalid codepoint marker
constexpr char32_t INVALID = 0xFFFD;
constexpr char32_t END_OF_INPUT = 0xFFFFFFFF;

// ============================================================================
// UTF-8 Decoder
// ============================================================================

// Decode a single UTF-8 codepoint from the beginning of the string.
// Returns the codepoint and the number of bytes consumed.
// Returns {INVALID, 1} for invalid sequences.
constexpr auto decode(std::string_view s) -> std::pair<char32_t, std::size_t> {
  if (s.empty()) {
    return {END_OF_INPUT, 0};
  }

  auto b0 = static_cast<std::uint8_t>(s[0]);

  // ASCII (0x00-0x7F)
  if (b0 < 0x80) {
    return {static_cast<char32_t>(b0), 1};
  }

  // Invalid: continuation byte or overlong encoding start
  if (b0 < 0xC2) {
    return {INVALID, 1};
  }

  // 2-byte sequence (0xC2-0xDF)
  if (b0 < 0xE0) {
    if (s.size() < 2)
      return {INVALID, 1};
    auto b1 = static_cast<std::uint8_t>(s[1]);
    if ((b1 & 0xC0) != 0x80)
      return {INVALID, 1};

    char32_t cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
    return {cp, 2};
  }

  // 3-byte sequence (0xE0-0xEF)
  if (b0 < 0xF0) {
    if (s.size() < 3)
      return {INVALID, 1};
    auto b1 = static_cast<std::uint8_t>(s[1]);
    auto b2 = static_cast<std::uint8_t>(s[2]);
    if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
      return {INVALID, 1};

    // Check for overlong encoding
    if (b0 == 0xE0 && b1 < 0xA0)
      return {INVALID, 1};
    // Check for surrogate pairs (0xD800-0xDFFF)
    if (b0 == 0xED && b1 >= 0xA0)
      return {INVALID, 1};

    char32_t cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
    return {cp, 3};
  }

  // 4-byte sequence (0xF0-0xF4)
  if (b0 < 0xF5) {
    if (s.size() < 4)
      return {INVALID, 1};
    auto b1 = static_cast<std::uint8_t>(s[1]);
    auto b2 = static_cast<std::uint8_t>(s[2]);
    auto b3 = static_cast<std::uint8_t>(s[3]);
    if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) {
      return {INVALID, 1};
    }

    // Check for overlong encoding
    if (b0 == 0xF0 && b1 < 0x90)
      return {INVALID, 1};
    // Check for codepoints above U+10FFFF
    if (b0 == 0xF4 && b1 >= 0x90)
      return {INVALID, 1};

    char32_t cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
    return {cp, 4};
  }

  // Invalid start byte
  return {INVALID, 1};
}

// ============================================================================
// UTF-8 Encoder
// ============================================================================

// Encode a codepoint to UTF-8. Returns the number of bytes written.
// Buffer must have space for at least 4 bytes.
constexpr auto encode(char32_t cp, char* out) -> std::size_t {
  if (cp < 0x80) {
    out[0] = static_cast<char>(cp);
    return 1;
  }
  if (cp < 0x800) {
    out[0] = static_cast<char>(0xC0 | (cp >> 6));
    out[1] = static_cast<char>(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = static_cast<char>(0xE0 | (cp >> 12));
    out[1] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out[2] = static_cast<char>(0x80 | (cp & 0x3F));
    return 3;
  }
  if (cp <= 0x10FFFF) {
    out[0] = static_cast<char>(0xF0 | (cp >> 18));
    out[1] = static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
    out[2] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out[3] = static_cast<char>(0x80 | (cp & 0x3F));
    return 4;
  }
  // Invalid codepoint, encode replacement character
  out[0] = static_cast<char>(0xEF);
  out[1] = static_cast<char>(0xBF);
  out[2] = static_cast<char>(0xBD);
  return 3;
}

// ============================================================================
// Character Classification (following Dhall grammar)
// ============================================================================

// valid-non-ascii from dhall.abnf
// Excludes surrogates (0xD800-0xDFFF) and non-characters
constexpr auto is_valid_non_ascii(char32_t cp) -> bool {
  // Must be above ASCII
  if (cp < 0x80)
    return false;

  // Check for surrogate pairs and non-characters
  // Surrogates: 0xD800-0xDFFF
  if (cp >= 0xD800 && cp <= 0xDFFF)
    return false;

  // Non-characters at end of each plane: 0xNFFFE-0xNFFFF
  if ((cp & 0xFFFF) >= 0xFFFE)
    return false;

  // Must be <= 0x10FFFF
  if (cp > 0x10FFFF)
    return false;

  return true;
}

// ALPHA: uppercase or lowercase ASCII letter
constexpr auto is_alpha(char32_t cp) -> bool {
  return (cp >= 'A' && cp <= 'Z') || (cp >= 'a' && cp <= 'z');
}

// DIGIT: ASCII digit 0-9
constexpr auto is_digit(char32_t cp) -> bool {
  return cp >= '0' && cp <= '9';
}

// HEXDIG: hexadecimal digit
constexpr auto is_hexdig(char32_t cp) -> bool {
  return is_digit(cp) || (cp >= 'A' && cp <= 'F') || (cp >= 'a' && cp <= 'f');
}

// ALPHANUM: letter or digit
constexpr auto is_alphanum(char32_t cp) -> bool {
  return is_alpha(cp) || is_digit(cp);
}

// simple-label-first-char: ALPHA / "_"
constexpr auto is_simple_label_first(char32_t cp) -> bool {
  return is_alpha(cp) || cp == '_';
}

// simple-label-next-char: ALPHANUM / "-" / "/" / "_"
constexpr auto is_simple_label_next(char32_t cp) -> bool {
  return is_alphanum(cp) || cp == '-' || cp == '/' || cp == '_';
}

// quoted-label-char: %x20-5F / %x61-7E (printable ASCII except backtick)
constexpr auto is_quoted_label_char(char32_t cp) -> bool {
  return (cp >= 0x20 && cp <= 0x5F) || (cp >= 0x61 && cp <= 0x7E);
}

// double-quote-char: printable except " and backslash, plus valid-non-ascii
constexpr auto is_double_quote_char(char32_t cp) -> bool {
  if (cp == '"' || cp == '\\')
    return false;
  return (cp >= 0x20 && cp <= 0x7F) || is_valid_non_ascii(cp);
}

// single-quote-char: printable plus valid-non-ascii, tab, newline
constexpr auto is_single_quote_char(char32_t cp) -> bool {
  return (cp >= 0x20 && cp <= 0x7F) || is_valid_non_ascii(cp) || cp == '\t' || cp == '\n' ||
         cp == '\r';
}

// block-comment-char: printable, valid-non-ascii, tab, end-of-line
constexpr auto is_block_comment_char(char32_t cp) -> bool {
  return (cp >= 0x20 && cp <= 0x7F) || is_valid_non_ascii(cp) || cp == '\t' || cp == '\n' ||
         cp == '\r';
}

// not-end-of-line: %x20-7F / valid-non-ascii / tab
constexpr auto is_not_end_of_line(char32_t cp) -> bool {
  return (cp >= 0x20 && cp <= 0x7F) || is_valid_non_ascii(cp) || cp == '\t';
}

// path-character: printable except " ()[]{}<>/\,"
constexpr auto is_path_char(char32_t cp) -> bool {
  if (cp < 0x21 || cp > 0x7E)
    return false;
  switch (cp) {
    case '"':
    case '(':
    case ')':
    case ',':
    case '/':
    case '<':
    case '>':
    case '?':
    case '[':
    case '\\':
    case ']':
    case '{':
    case '}':
      return false;
    default:
      return true;
  }
}

// ============================================================================
// UTF-8 Iterator
// ============================================================================

class Iterator {
public:
  using iterator_category = std::forward_iterator_tag;
  using value_type = char32_t;
  using difference_type = std::ptrdiff_t;

  constexpr Iterator() = default;
  constexpr explicit Iterator(std::string_view s) : data_(s) {}

  constexpr auto operator*() const -> char32_t {
    auto [cp, _] = decode(data_);
    return cp;
  }

  constexpr auto operator++() -> Iterator& {
    auto [_, len] = decode(data_);
    data_.remove_prefix(len);
    return *this;
  }

  constexpr auto operator++(int) -> Iterator {
    auto copy = *this;
    ++*this;
    return copy;
  }

  constexpr auto operator==(const Iterator& other) const -> bool {
    return data_.data() == other.data_.data();
  }

  [[nodiscard]] constexpr auto remaining() const -> std::string_view { return data_; }

  [[nodiscard]] constexpr auto at_end() const -> bool { return data_.empty(); }

private:
  std::string_view data_;
};

// ============================================================================
// Hex Digit Conversion
// ============================================================================

constexpr auto hex_value(char32_t cp) -> std::optional<std::uint8_t> {
  if (cp >= '0' && cp <= '9')
    return static_cast<std::uint8_t>(cp - '0');
  if (cp >= 'A' && cp <= 'F')
    return static_cast<std::uint8_t>(cp - 'A' + 10);
  if (cp >= 'a' && cp <= 'f')
    return static_cast<std::uint8_t>(cp - 'a' + 10);
  return std::nullopt;
}

constexpr auto to_hex_char(std::uint8_t n) -> char {
  return n < 10 ? static_cast<char>('0' + n) : static_cast<char>('a' + n - 10);
}

} // namespace continuity::codec::utf8
