# Continuity.Codec - C++23 Dhall Interpreter

## Target: Full sensenet eval in <10ms

### Workload Analysis

From codebase exploration:
- **111 .dhall files**, ~12K LOC project code
- **15 transitive imports** per BUILD.dhall (prelude is shared)
- **No remote imports** - all local, no network I/O
- **Heavy record usage** - `with`, `//`, field access dominate
- **Minimal builtins** - List/fold, List/head, Natural/isZero
- **Simple subset** - no Natural/fold loops, minimal recursion

### Performance Budget (10ms total)

| Phase | Budget | Strategy |
|-------|--------|----------|
| File I/O | 1ms | mmap, readahead hint |
| Lexing | 1ms | SIMD UTF-8, zero-copy |
| Parsing | 2ms | LL(k), arena allocation |
| Import resolution | 1ms | Pre-hashed cache |
| Normalization | 3ms | NbE, SIMD record ops |
| Decode to IR | 2ms | Direct field extraction |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Continuity.Codec                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Lexer     │  │   Parser    │  │      Evaluator          │  │
│  │  (SIMD)     │→ │  (LL(4))    │→ │  (NbE + SIMD records)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│         ↑                                      ↓                 │
│  ┌─────────────┐                    ┌─────────────────────────┐  │
│  │ mmap Files  │                    │   Quote / Decode        │  │
│  └─────────────┘                    └─────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    Arena Allocator                          ││
│  │  - Per-file arena (bulk free on import complete)            ││
│  │  - 64-byte aligned for cache lines                          ││
│  │  - Pre-allocated 1MB blocks                                 ││
│  └─────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    Prelude Cache                            ││
│  │  - Compiled at build time (constexpr where possible)        ││
│  │  - SHA256-indexed normalized values                         ││
│  │  - Copy-on-write for prelude references                     ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Core Infrastructure

### 1.1 Arena Allocator (`Arena.hpp`)

```cpp
class Arena {
    struct Block {
        alignas(64) std::byte data[1024 * 1024];  // 1MB blocks
        std::size_t used = 0;
    };
    std::vector<std::unique_ptr<Block>> blocks_;
    Block* current_;

public:
    template<typename T, typename... Args>
    T* alloc(Args&&... args);  // Placement new in arena

    void reset();  // Bulk deallocation - O(1)
};
```

**Why**: Haskell's GC is the enemy of predictable latency. Arena allocation:
- No GC pauses
- Cache-friendly sequential allocation
- O(1) bulk free when done with a file

### 1.2 Interned Strings (`Intern.hpp`)

```cpp
class StringInterner {
    // Global intern table - thread-safe, lock-free reads
    static inline std::atomic<InternTable*> table_;

public:
    struct Interned {
        std::uint32_t id;      // 4 bytes vs 24 for std::string
        std::uint32_t hash;    // Pre-computed
    };

    static Interned intern(std::string_view s);
    static std::string_view get(Interned i);
};
```

**Why**: Field names repeat constantly. Interning means:
- 8 bytes per field name vs 24+
- O(1) equality comparison (compare IDs)
- Pre-computed hashes for record operations

### 1.3 Source Manager (`Source.hpp`)

```cpp
class SourceManager {
    struct MappedFile {
        int fd;
        const char* data;
        std::size_t size;
        Hash sha256;  // For content-addressing
    };

    std::unordered_map<std::string, MappedFile> files_;
    std::unordered_map<Hash, NormalizedExpr*> cache_;  // CA cache

public:
    std::expected<std::string_view, Error> load(const Path& path);
    std::optional<NormalizedExpr*> lookup_cache(const Hash& h);
    void insert_cache(const Hash& h, NormalizedExpr* e);
};
```

**Why**: 
- mmap avoids copy into userspace
- posix_fadvise(WILLNEED) for readahead
- Content-addressed cache enables prelude sharing

---

## Phase 2: Lexer (SIMD-accelerated)

### 2.1 Token Types (`Token.hpp`)

```cpp
enum class TokenKind : std::uint8_t {
    // Single-char (fast path)
    LParen, RParen, LBrace, RBrace, LBracket, RBracket,
    Comma, Dot, Colon, At, Equal, Pipe, Backslash,

    // Multi-char operators
    Arrow, FatArrow, DoubleColon, DoublePipe, DoubleAmpersand,
    DoubleEqual, NotEqual, Combine, CombineTypes, Prefer,

    // Keywords (intern IDs)
    If, Then, Else, Let, In, Forall, Assert, As, Using,
    Merge, ToMap, With, ShowConstructor, Missing,

    // Literals
    Natural, Integer, Double, Text, Bytes,
    Date, Time, TimeZone,

    // Identifiers
    Label, QuotedLabel,

    // Special
    Builtin,  // Natural, List, etc.
    Newline,  // For shebang handling
    Eof,
    Error,
};

struct Token {
    TokenKind kind;
    std::uint32_t offset;  // Into source
    std::uint32_t length;
    union {
        std::uint64_t natural_val;
        std::int64_t integer_val;
        double double_val;
        Interned label;
    };
};
```

### 2.2 SIMD Lexer (`Lexer.hpp`)

```cpp
class Lexer {
    const char* src_;
    const char* end_;
    const char* ptr_;

    // SIMD lookup tables
    static constexpr auto SINGLE_CHAR_TABLE = make_single_char_table();
    static constexpr auto LABEL_CHAR_TABLE = make_label_char_table();

public:
    explicit Lexer(std::string_view source);

    Token next();

private:
    // Fast paths
    Token lex_single_char();           // Table lookup
    Token lex_operator();              // 2-4 char lookahead
    Token lex_label();                 // SIMD scan for end
    Token lex_number();                // State machine
    Token lex_string();                // Handle interpolation
    Token lex_multiline_string();      // '' strings

    // SIMD helpers
    std::size_t skip_whitespace_simd();  // AVX2: 32 bytes/cycle
    std::size_t scan_label_simd();       // Find non-label char
    bool match_keyword(std::string_view kw);
};
```

**SIMD Strategy**:

```cpp
// Skip whitespace: compare 32 bytes against space/tab/newline
__m256i whitespace = _mm256_set1_epi8(' ');
__m256i chunk = _mm256_loadu_si256(ptr);
__m256i is_space = _mm256_cmpeq_epi8(chunk, whitespace);
// ... similar for tab, newline
int mask = _mm256_movemask_epi8(is_space | is_tab | is_newline);
int skip = __builtin_ctz(~mask);  // Count leading whitespace
```

---

## Phase 3: LL(k) Parser

### 3.1 AST Types (`Ast.hpp`)

```cpp
// Compact AST node - fits in 32 bytes
struct Expr {
    enum class Kind : std::uint8_t {
        Const, Var, Lam, Pi, App, Let, Lit,
        BoolAnd, BoolOr, BoolIf,
        NatPlus, NatTimes, TextAppend,
        List, ListAppend,
        Record, RecordLit, Union,
        Combine, CombineTypes, Prefer,
        Merge, ToMap, Field, Project,
        Assert, Equivalent, With,
        Builtin, Annot, Import,
    };

    Kind kind;
    std::uint8_t flags;        // Inline small data
    std::uint16_t _pad;
    std::uint32_t span_start;  // Source location
    std::uint32_t span_end;

    union {
        // Literals (inline)
        bool bool_val;
        std::uint64_t nat_val;
        std::int64_t int_val;
        double double_val;

        // Variable
        struct { std::uint32_t index; } var;

        // Binary ops
        struct { Expr* lhs; Expr* rhs; } binop;

        // Lambda/Pi
        struct { Interned name; Expr* type; Expr* body; } binder;

        // Let
        struct { Interned name; Expr* type; Expr* value; Expr* body; } let;

        // App
        struct { Expr* func; Expr* arg; } app;

        // Record
        struct { Fields* fields; } record;

        // List
        struct { Expr* elem_type; ExprList* elements; } list;

        // Field access
        struct { Expr* record; Interned field; } field;

        // Import
        struct { Import* import; } import;
    };
};

// Sorted vector of fields - cache-friendly
struct Fields {
    std::uint32_t count;
    std::uint32_t capacity;
    // Followed by: Interned names[count], Expr* values[count]
    // Sorted by name for binary search
};
```

### 3.2 Parser (`Parser.hpp`)

```cpp
class Parser {
    Lexer lexer_;
    Arena& arena_;
    Token current_;
    Token lookahead_[4];  // LL(4)

public:
    Parser(std::string_view source, Arena& arena);

    std::expected<Expr*, ParseError> parse();

private:
    // Token management
    void advance();
    Token peek(std::size_t n = 0);
    bool match(TokenKind k);
    bool check(TokenKind k);
    std::expected<void, ParseError> expect(TokenKind k);

    // Expression parsers (precedence climbing)
    Expr* parse_expression();
    Expr* parse_annotated();
    Expr* parse_operator(int min_prec);
    Expr* parse_application();
    Expr* parse_import_expression();
    Expr* parse_completion();
    Expr* parse_selector();
    Expr* parse_primitive();

    // Specific constructs
    Expr* parse_lambda();
    Expr* parse_forall();
    Expr* parse_if();
    Expr* parse_let();
    Expr* parse_merge();
    Expr* parse_assert();
    Expr* parse_record();
    Expr* parse_union();
    Expr* parse_list();
    Expr* parse_text();
    Expr* parse_import();

    // Operator precedence table
    static constexpr std::array<int, 16> PRECEDENCE = {
        1,  // Equivalent
        2,  // ImportAlt
        3,  // Or
        4,  // Plus
        5,  // TextAppend
        6,  // ListAppend
        7,  // And
        8,  // Combine
        9,  // Prefer
        10, // CombineTypes
        11, // Times
        12, // Equal
        13, // NotEqual
    };
};
```

---

## Phase 4: Evaluator (NbE with SIMD Records)

### 4.1 Values (`Value.hpp`)

```cpp
// Runtime values - WHNF
struct Val {
    enum class Kind : std::uint8_t {
        Const, Neutral, Lam, Pi,
        Bool, BoolLit,
        Natural, NaturalLit,
        Integer, IntegerLit,
        Double, DoubleLit,
        Text, TextLit,
        List, ListLit,
        Optional, Some, None,
        Record, RecordLit,
        Union, Inject,
        Builtin, PrimFun,
    };

    Kind kind;
    std::uint8_t _pad[3];

    union {
        bool bool_val;
        std::uint64_t nat_val;
        std::int64_t int_val;
        double double_val;

        struct { Interned name; Val* type; Closure* body; } lam;
        struct { Interned name; Val* domain; Closure* codomain; } pi;

        // Neutral - stuck computation
        struct { Neutral* neutral; } neutral;

        // Records - SIMD-friendly layout
        struct { ValFields* fields; } record;

        // List - small vector optimization
        struct { Val* elem_type; ValList* elements; } list;

        // Primitive function (for builtins)
        struct { Builtin builtin; std::uint8_t arity; std::uint8_t applied; Val* args[4]; } primfun;
    };
};

// Closure: captures environment
struct Closure {
    Env* env;
    Expr* body;
};

// Environment: array-based for O(1) lookup
struct Env {
    std::uint32_t size;
    std::uint32_t capacity;
    Val* values[];  // Flexible array member
};
```

### 4.2 SIMD Record Operations (`Records.hpp`)

```cpp
// ValFields: sorted by interned name ID for SIMD operations
struct ValFields {
    std::uint32_t count;
    std::uint32_t capacity;
    Interned* names;   // Sorted
    Val** values;

    // Binary search lookup
    Val* lookup(Interned name) const;

    // SIMD merge for // operator
    static ValFields* prefer(Arena& arena, const ValFields* a, const ValFields* b);

    // SIMD merge for /\ operator
    static ValFields* combine(Arena& arena, const ValFields* a, const ValFields* b,
                              Val* (*combine_fn)(Val*, Val*));
};

// SIMD prefer implementation
ValFields* ValFields::prefer(Arena& arena, const ValFields* a, const ValFields* b) {
    // Strategy: merge sorted arrays, right wins on collision
    // Use AVX2 to compare 8 name IDs at once

    // Step 1: Allocate result (max size = a.count + b.count)
    auto* result = arena.alloc<ValFields>(a->count + b->count);

    // Step 2: Merge with SIMD comparison
    std::uint32_t i = 0, j = 0, k = 0;

    // Process 8 elements at a time when possible
    while (i + 8 <= a->count && j + 8 <= b->count) {
        __m256i va = _mm256_loadu_si256((__m256i*)&a->names[i]);
        __m256i vb = _mm256_loadu_si256((__m256i*)&b->names[j]);
        // ... SIMD merge logic
    }

    // Scalar fallback for remainder
    while (i < a->count && j < b->count) {
        if (a->names[i].id < b->names[j].id) {
            result->names[k] = a->names[i];
            result->values[k] = a->values[i];
            i++; k++;
        } else if (a->names[i].id > b->names[j].id) {
            result->names[k] = b->names[j];
            result->values[k] = b->values[j];
            j++; k++;
        } else {
            // Collision: right (b) wins
            result->names[k] = b->names[j];
            result->values[k] = b->values[j];
            i++; j++; k++;
        }
    }
    // Copy remaining...

    result->count = k;
    return result;
}
```

### 4.3 Evaluator (`Eval.hpp`)

```cpp
class Evaluator {
    Arena& arena_;
    SourceManager& sources_;

public:
    Evaluator(Arena& arena, SourceManager& sources);

    // Evaluate to WHNF
    Val* eval(Env* env, Expr* e);

    // Quote back to Expr (for output)
    Expr* quote(int level, Val* v);

    // Full normalization
    Expr* normalize(Expr* e);

private:
    // Application (handles beta reduction)
    Val* apply(Val* f, Val* x);

    // Field access (handles union constructors)
    Val* field(Val* record, Interned name);

    // With expression
    Val* with(Val* record, std::span<Interned> path, Val* value);

    // Builtins
    Val* apply_builtin(Builtin b, std::span<Val*> args);

    // Record operations
    Val* prefer(Val* a, Val* b);
    Val* combine(Val* a, Val* b);
};

// Hot path: eval
Val* Evaluator::eval(Env* env, Expr* e) {
    switch (e->kind) {
    case Expr::Kind::Var: {
        auto idx = e->var.index;
        return idx < env->size ? env->values[idx] : make_neutral_var(env->size - idx - 1);
    }
    case Expr::Kind::App: {
        auto* f = eval(env, e->app.func);
        auto* x = eval(env, e->app.arg);
        return apply(f, x);
    }
    case Expr::Kind::Let: {
        auto* v = eval(env, e->let.value);
        auto* env2 = extend_env(env, v);
        return eval(env2, e->let.body);
    }
    case Expr::Kind::Prefer: {
        auto* a = eval(env, e->binop.lhs);
        auto* b = eval(env, e->binop.rhs);
        return prefer(a, b);
    }
    // ... etc
    }
}
```

---

## Phase 5: Import Resolution

### 5.1 Import Cache (`ImportCache.hpp`)

```cpp
class ImportCache {
    // Content-addressed cache: SHA256 -> normalized value
    std::unordered_map<Hash, Val*, HashHasher> cache_;

    // Path resolution cache: resolved path -> hash
    std::unordered_map<std::string, Hash> path_to_hash_;

public:
    // Lookup by content hash (for semantic cache)
    std::optional<Val*> lookup(const Hash& h);

    // Lookup by path (for import resolution)
    std::optional<Val*> lookup_path(const std::string& path);

    // Insert normalized value
    void insert(const Hash& h, Val* v);
    void insert_path(const std::string& path, const Hash& h);
};
```

### 5.2 Import Resolution Strategy

```cpp
Val* resolve_import(const Import& imp, const Path& base_dir) {
    // 1. Resolve path
    Path resolved = resolve_path(imp, base_dir);

    // 2. Check path cache
    if (auto cached = cache_.lookup_path(resolved.string())) {
        return *cached;
    }

    // 3. Load file
    auto source = sources_.load(resolved);
    if (!source) return make_error_val(source.error());

    // 4. Compute hash
    Hash hash = sha256(*source);

    // 5. Check content cache
    if (auto cached = cache_.lookup(hash)) {
        cache_.insert_path(resolved.string(), hash);
        return *cached;
    }

    // 6. Check integrity (if import has hash)
    if (imp.hash && *imp.hash != hash) {
        return make_error_val("hash mismatch");
    }

    // 7. Parse
    Arena file_arena;
    Parser parser(*source, file_arena);
    auto ast = parser.parse();
    if (!ast) return make_error_val(ast.error());

    // 8. Resolve nested imports
    auto resolved_ast = resolve_imports(*ast, resolved.parent_path());
    if (!resolved_ast) return make_error_val(resolved_ast.error());

    // 9. Evaluate
    auto* val = eval(empty_env(), *resolved_ast);

    // 10. Cache
    cache_.insert(hash, val);
    cache_.insert_path(resolved.string(), hash);

    return val;
}
```

---

## Phase 6: Precompiled Prelude

### 6.1 Build-time Compilation

```cpp
// At build time, compile the prelude to C++ constexpr data

// Generated: prelude_data.hpp
namespace prelude {

// Interned string table (constexpr)
constexpr std::array<std::string_view, 256> STRINGS = {
    "name", "srcs", "deps", "std", "cflags", "ldflags", "vis",
    "Cxx17", "Cxx20", "Cxx23", "Public", "Private",
    // ...
};

// Pre-normalized values as byte arrays
constexpr std::array<std::byte, 4096> COMPAT_DHALL_DATA = { /* ... */ };
constexpr std::array<std::byte, 2048> TYPES_DHALL_DATA = { /* ... */ };
constexpr std::array<std::byte, 8192> RULES_DHALL_DATA = { /* ... */ };

// Hash table: path -> offset into data
constexpr std::array<std::pair<Hash, std::size_t>, 32> PRELUDE_INDEX = {
    { sha256_of("dhall/evring/Compat.dhall"), 0 },
    { sha256_of("dhall/prelude/Types.dhall"), 4096 },
    // ...
};

}  // namespace prelude
```

### 6.2 Runtime Loading

```cpp
class PreludeCache {
    // Memory-mapped precompiled data
    const std::byte* data_;

public:
    PreludeCache() {
        // Prelude is compiled into the binary
        data_ = reinterpret_cast<const std::byte*>(&prelude::COMPAT_DHALL_DATA);
    }

    std::optional<Val*> lookup(const Hash& h) {
        for (const auto& [hash, offset] : prelude::PRELUDE_INDEX) {
            if (hash == h) {
                return deserialize(data_ + offset);
            }
        }
        return std::nullopt;
    }

private:
    Val* deserialize(const std::byte* data);
};
```

---

## Phase 7: Integration with libevring

### 7.1 C API (`evring_dhall.h`)

```c
#ifndef EVRING_DHALL_H
#define EVRING_DHALL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque types
typedef struct evring_dhall_context evring_dhall_context_t;
typedef struct evring_dhall_value evring_dhall_value_t;
typedef struct evring_dhall_error evring_dhall_error_t;

// Context management
evring_dhall_context_t* evring_dhall_context_new(void);
void evring_dhall_context_free(evring_dhall_context_t* ctx);

// Evaluation
evring_dhall_value_t* evring_dhall_eval_file(
    evring_dhall_context_t* ctx,
    const char* path,
    evring_dhall_error_t** error
);

evring_dhall_value_t* evring_dhall_eval_string(
    evring_dhall_context_t* ctx,
    const char* source,
    size_t len,
    const char* filename,
    evring_dhall_error_t** error
);

// Value inspection
int evring_dhall_value_is_record(const evring_dhall_value_t* v);
int evring_dhall_value_is_list(const evring_dhall_value_t* v);
int evring_dhall_value_is_text(const evring_dhall_value_t* v);

// Record access
size_t evring_dhall_record_size(const evring_dhall_value_t* v);
const char* evring_dhall_record_key(const evring_dhall_value_t* v, size_t i);
const evring_dhall_value_t* evring_dhall_record_value(const evring_dhall_value_t* v, size_t i);
const evring_dhall_value_t* evring_dhall_record_get(const evring_dhall_value_t* v, const char* key);

// List access
size_t evring_dhall_list_size(const evring_dhall_value_t* v);
const evring_dhall_value_t* evring_dhall_list_get(const evring_dhall_value_t* v, size_t i);

// Text access
const char* evring_dhall_text_data(const evring_dhall_value_t* v);
size_t evring_dhall_text_len(const evring_dhall_value_t* v);

// Error handling
const char* evring_dhall_error_message(const evring_dhall_error_t* e);
void evring_dhall_error_free(evring_dhall_error_t* e);

#ifdef __cplusplus
}
#endif

#endif // EVRING_DHALL_H
```

### 7.2 Direct IR Decoding

```cpp
// Decode directly to sensenet IR without intermediate representation

struct Package {
    std::string name;
    std::vector<CxxBinary> cxx_binaries;
    std::vector<CxxLibrary> cxx_libraries;
    std::vector<RustBinary> rust_binaries;
    // ...
};

Package decode_package(Val* v) {
    Package pkg;

    auto* rec = as_record_lit(v);
    if (!rec) throw DecodeError("expected record");

    // Direct field extraction - no intermediate Value type
    if (auto* targets = rec->lookup(intern("targets"))) {
        auto* list = as_list_lit(targets);
        for (auto* elem : *list) {
            decode_target(elem, pkg);
        }
    }

    return pkg;
}

void decode_target(Val* v, Package& pkg) {
    auto* rec = as_record_lit(v);

    // Check discriminant field
    if (auto* kind = rec->lookup(intern("kind"))) {
        auto kind_str = as_text(kind);
        if (kind_str == "cxx_binary") {
            pkg.cxx_binaries.push_back(decode_cxx_binary(rec));
        } else if (kind_str == "cxx_library") {
            pkg.cxx_libraries.push_back(decode_cxx_library(rec));
        }
        // ...
    }
}
```

---

## File Structure

```
src/continuity-codec/
├── BUILD.dhall
├── DESIGN.md                    # This file
│
├── include/
│   └── evring/
│       ├── dhall.h              # C API
│       └── dhall.hpp            # C++ API
│
├── src/
│   ├── arena.hpp                # Arena allocator
│   ├── intern.hpp               # String interning
│   ├── intern.cpp
│   ├── source.hpp               # Source file management
│   ├── source.cpp
│   │
│   ├── token.hpp                # Token types
│   ├── lexer.hpp                # SIMD lexer
│   ├── lexer.cpp
│   ├── lexer_simd.cpp           # AVX2/NEON implementations
│   │
│   ├── ast.hpp                  # AST types
│   ├── parser.hpp               # LL(k) parser
│   ├── parser.cpp
│   │
│   ├── value.hpp                # Runtime values
│   ├── env.hpp                  # Evaluation environment
│   ├── eval.hpp                 # NbE evaluator
│   ├── eval.cpp
│   ├── records.hpp              # SIMD record operations
│   ├── records.cpp
│   ├── builtins.cpp             # Builtin implementations
│   │
│   ├── import.hpp               # Import resolution
│   ├── import.cpp
│   ├── cache.hpp                # Content-addressed cache
│   ├── cache.cpp
│   │
│   ├── quote.hpp                # Quote values to AST
│   ├── quote.cpp
│   │
│   ├── decode.hpp               # Decode to IR types
│   ├── decode.cpp
│   │
│   ├── api.cpp                  # C/C++ API implementation
│   │
│   └── prelude/                 # Generated at build time
│       ├── data.hpp             # Precompiled prelude data
│       └── index.hpp            # Hash index
│
├── test/
│   ├── lexer_test.cpp
│   ├── parser_test.cpp
│   ├── eval_test.cpp
│   ├── import_test.cpp
│   └── benchmark.cpp            # Performance benchmarks
│
└── tools/
    └── compile_prelude.cpp      # Build-time prelude compiler
```

---

## Implementation Order

### Sprint 1: Core (Week 1)
1. `arena.hpp` - Arena allocator
2. `intern.hpp/cpp` - String interning with hash
3. `source.hpp/cpp` - mmap file loading
4. `token.hpp` - Token types

### Sprint 2: Lexer (Week 1-2)
5. `lexer.hpp/cpp` - Basic lexer
6. `lexer_simd.cpp` - SIMD whitespace/label scanning

### Sprint 3: Parser (Week 2)
7. `ast.hpp` - AST types
8. `parser.hpp/cpp` - Full LL(4) parser

### Sprint 4: Evaluator (Week 2-3)
9. `value.hpp` - Value types
10. `env.hpp` - Environment
11. `eval.hpp/cpp` - NbE evaluator
12. `records.hpp/cpp` - SIMD record ops
13. `builtins.cpp` - Builtin functions

### Sprint 5: Imports (Week 3)
14. `import.hpp/cpp` - Import resolution
15. `cache.hpp/cpp` - Content-addressed cache
16. `quote.hpp/cpp` - Quote values

### Sprint 6: Integration (Week 3-4)
17. `decode.hpp/cpp` - IR decoding
18. `api.cpp` - C/C++ API
19. `tools/compile_prelude.cpp` - Prelude compiler

### Sprint 7: Polish (Week 4)
20. Benchmarks and profiling
21. SIMD tuning
22. Prelude compilation
23. Documentation

---

## Performance Targets

| Benchmark | Target | Notes |
|-----------|--------|-------|
| Lex sensenet.dhall | <500μs | SIMD whitespace |
| Parse sensenet.dhall | <1ms | Arena allocation |
| Eval single BUILD.dhall | <2ms | With cached prelude |
| Full sensenet eval | <10ms | 111 files, parallelizable |
| Import resolution | <100μs/file | mmap + cache |
| Record prefer (100 fields) | <1μs | SIMD merge |

---

## Testing Strategy

1. **Conformance**: Run against dhall-lang test suite
2. **Differential**: Compare output with dhall-haskell
3. **Fuzzing**: AFL++ on parser
4. **Benchmarks**: 
   - Microbenchmarks for each component
   - End-to-end sensenet eval
   - Memory usage tracking
5. **Stress**: Large records, deep nesting, many imports
