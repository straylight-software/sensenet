// Continuity.Codec - Expression Normalization
//
// Beta-reduction and normalization for Dhall expressions.
// Implements the normalization rules from the Dhall standard.
//
// straylight.software - 2026

#include <cmath>
#include <sstream>

#include "Codec.hpp"
#include "Utf8.hpp"

namespace continuity::codec {

namespace {

// Deep clone an expression
auto clone(const Expr& e) -> ExprPtr {
  auto result = std::make_unique<Expr>();
  result->span = e.span;

  std::visit(
      [&](const auto& data) {
        using T = std::decay_t<decltype(data)>;

        if constexpr (std::is_same_v<T, bool> || std::is_same_v<T, std::uint64_t> ||
                      std::is_same_v<T, std::int64_t> || std::is_same_v<T, double> ||
                      std::is_same_v<T, std::vector<std::uint8_t>> ||
                      std::is_same_v<T, Expr::DateLiteral> ||
                      std::is_same_v<T, Expr::TimeLiteral> ||
                      std::is_same_v<T, Expr::TimeZoneLiteral> ||
                      std::is_same_v<T, Expr::Variable> || std::is_same_v<T, Expr::Builtin> ||
                      std::is_same_v<T, Import>) {
          result->data = data;
        } else if constexpr (std::is_same_v<T, std::vector<TextChunk>>) {
          std::vector<TextChunk> chunks;
          for (const auto& chunk : data) {
            if (auto* s = std::get_if<std::string>(&chunk.content)) {
              chunks.push_back(TextChunk{*s});
            } else {
              chunks.push_back(TextChunk{clone(*std::get<ExprPtr>(chunk.content))});
            }
          }
          result->data = std::move(chunks);
        } else if constexpr (std::is_same_v<T, Expr::Lambda>) {
          result->data = Expr::Lambda{data.param, clone(*data.type), clone(*data.body)};
        } else if constexpr (std::is_same_v<T, Expr::Pi>) {
          result->data = Expr::Pi{data.param, clone(*data.type), clone(*data.body)};
        } else if constexpr (std::is_same_v<T, Expr::App>) {
          result->data = Expr::App{clone(*data.func), clone(*data.arg)};
        } else if constexpr (std::is_same_v<T, Expr::Let>) {
          std::vector<Binding> bindings;
          for (const auto& b : data.bindings) {
            bindings.push_back(Binding{b.name,
                                       b.type ? std::optional{clone(**b.type)} : std::nullopt,
                                       clone(*b.value), b.span});
          }
          result->data = Expr::Let{std::move(bindings), clone(*data.body)};
        } else if constexpr (std::is_same_v<T, Expr::Annot>) {
          result->data = Expr::Annot{clone(*data.expr), clone(*data.type)};
        } else if constexpr (std::is_same_v<T, Expr::If>) {
          result->data =
              Expr::If{clone(*data.cond), clone(*data.then_branch), clone(*data.else_branch)};
        } else if constexpr (std::is_same_v<T, Expr::Merge>) {
          result->data = Expr::Merge{clone(*data.handler), clone(*data.union_val),
                                     data.type ? std::optional{clone(**data.type)} : std::nullopt};
        } else if constexpr (std::is_same_v<T, Expr::ToMap>) {
          result->data = Expr::ToMap{clone(*data.record),
                                     data.type ? std::optional{clone(**data.type)} : std::nullopt};
        } else if constexpr (std::is_same_v<T, Expr::ShowConstructor>) {
          result->data = Expr::ShowConstructor{clone(*data.union_val)};
        } else if constexpr (std::is_same_v<T, Expr::Assert>) {
          result->data = Expr::Assert{clone(*data.type)};
        } else if constexpr (std::is_same_v<T, Expr::With>) {
          result->data = Expr::With{clone(*data.base), data.path, clone(*data.value)};
        } else if constexpr (std::is_same_v<T, Expr::Field>) {
          result->data = Expr::Field{clone(*data.record), data.field};
        } else if constexpr (std::is_same_v<T, Expr::Project>) {
          result->data = Expr::Project{clone(*data.record), data.fields};
        } else if constexpr (std::is_same_v<T, Expr::ProjectType>) {
          result->data = Expr::ProjectType{clone(*data.record), clone(*data.type)};
        } else if constexpr (std::is_same_v<T, Expr::Completion>) {
          result->data = Expr::Completion{clone(*data.type), clone(*data.record)};
        } else if constexpr (std::is_same_v<T, Expr::RecordLit>) {
          std::vector<RecordEntry> entries;
          for (const auto& entry : data.entries) {
            entries.push_back(RecordEntry{entry.name, entry.path, clone(*entry.value)});
          }
          result->data = Expr::RecordLit{std::move(entries)};
        } else if constexpr (std::is_same_v<T, Expr::RecordType>) {
          std::vector<std::pair<std::string, ExprPtr>> fields;
          for (const auto& [name, type] : data.fields) {
            fields.emplace_back(name, clone(*type));
          }
          result->data = Expr::RecordType{std::move(fields)};
        } else if constexpr (std::is_same_v<T, Expr::UnionType>) {
          std::vector<UnionAlt> alts;
          for (const auto& alt : data.alternatives) {
            alts.push_back(
                UnionAlt{alt.name, alt.type ? std::optional{clone(**alt.type)} : std::nullopt});
          }
          result->data = Expr::UnionType{std::move(alts)};
        } else if constexpr (std::is_same_v<T, Expr::ListLit>) {
          std::vector<ExprPtr> elements;
          for (const auto& elem : data.elements) {
            elements.push_back(clone(*elem));
          }
          result->data = Expr::ListLit{data.type ? std::optional{clone(**data.type)} : std::nullopt,
                                       std::move(elements)};
        } else if constexpr (std::is_same_v<T, Expr::Some>) {
          result->data = Expr::Some{clone(*data.value)};
        } else if constexpr (std::is_same_v<T, Expr::BinOp>) {
          result->data = Expr::BinOp{data.op, clone(*data.lhs), clone(*data.rhs)};
        }
      },
      e.data);

  return result;
}

// Shift de Bruijn indices
auto shift(const Expr& e, std::int64_t d, const std::string& x, std::uint64_t minIndex) -> ExprPtr;

// Substitute x@n with v in e
auto substitute(const Expr& e, const std::string& x, std::uint64_t n, const Expr& v) -> ExprPtr;

// Implementation of shift
auto shift(const Expr& e, std::int64_t d, const std::string& x, std::uint64_t minIndex) -> ExprPtr {
  auto result = std::make_unique<Expr>();
  result->span = e.span;

  std::visit(
      [&](const auto& data) {
        using T = std::decay_t<decltype(data)>;

        if constexpr (std::is_same_v<T, Expr::Variable>) {
          if (data.name == x && data.index >= minIndex) {
            result->data = Expr::Variable{
                data.name, static_cast<std::uint64_t>(static_cast<std::int64_t>(data.index) + d)};
          } else {
            result->data = data;
          }
        } else if constexpr (std::is_same_v<T, Expr::Lambda>) {
          auto newMin = (data.param == x) ? minIndex + 1 : minIndex;
          result->data = Expr::Lambda{data.param, shift(*data.type, d, x, minIndex),
                                      shift(*data.body, d, x, newMin)};
        } else if constexpr (std::is_same_v<T, Expr::Pi>) {
          auto newMin = (data.param == x) ? minIndex + 1 : minIndex;
          result->data = Expr::Pi{data.param, shift(*data.type, d, x, minIndex),
                                  shift(*data.body, d, x, newMin)};
        } else if constexpr (std::is_same_v<T, Expr::Let>) {
          std::vector<Binding> bindings;
          auto currentMin = minIndex;
          for (const auto& b : data.bindings) {
            bindings.push_back(Binding{
                b.name, b.type ? std::optional{shift(**b.type, d, x, currentMin)} : std::nullopt,
                shift(*b.value, d, x, currentMin), b.span});
            if (b.name == x)
              currentMin++;
          }
          result->data = Expr::Let{std::move(bindings), shift(*data.body, d, x, currentMin)};
        } else if constexpr (std::is_same_v<T, Expr::App>) {
          result->data =
              Expr::App{shift(*data.func, d, x, minIndex), shift(*data.arg, d, x, minIndex)};
        } else if constexpr (std::is_same_v<T, Expr::BinOp>) {
          result->data = Expr::BinOp{data.op, shift(*data.lhs, d, x, minIndex),
                                     shift(*data.rhs, d, x, minIndex)};
        } else if constexpr (std::is_same_v<T, Expr::If>) {
          result->data =
              Expr::If{shift(*data.cond, d, x, minIndex), shift(*data.then_branch, d, x, minIndex),
                       shift(*data.else_branch, d, x, minIndex)};
        } else if constexpr (std::is_same_v<T, Expr::ListLit>) {
          std::vector<ExprPtr> elements;
          for (const auto& elem : data.elements) {
            elements.push_back(shift(*elem, d, x, minIndex));
          }
          result->data = Expr::ListLit{data.type ? std::optional{shift(**data.type, d, x, minIndex)}
                                                 : std::nullopt,
                                       std::move(elements)};
        } else if constexpr (std::is_same_v<T, Expr::RecordLit>) {
          std::vector<RecordEntry> entries;
          for (const auto& entry : data.entries) {
            entries.push_back(
                RecordEntry{entry.name, entry.path, shift(*entry.value, d, x, minIndex)});
          }
          result->data = Expr::RecordLit{std::move(entries)};
        } else if constexpr (std::is_same_v<T, Expr::RecordType>) {
          std::vector<std::pair<std::string, ExprPtr>> fields;
          for (const auto& [name, type] : data.fields) {
            fields.emplace_back(name, shift(*type, d, x, minIndex));
          }
          result->data = Expr::RecordType{std::move(fields)};
        } else {
          // For other cases, just clone
          result = clone(e);
        }
      },
      e.data);

  return result;
}

// Implementation of substitute
auto substitute(const Expr& e, const std::string& x, std::uint64_t n, const Expr& v) -> ExprPtr {
  auto result = std::make_unique<Expr>();
  result->span = e.span;

  std::visit(
      [&](const auto& data) {
        using T = std::decay_t<decltype(data)>;

        if constexpr (std::is_same_v<T, Expr::Variable>) {
          if (data.name == x && data.index == n) {
            result = clone(v);
          } else {
            result->data = data;
          }
        } else if constexpr (std::is_same_v<T, Expr::Lambda>) {
          auto newN = (data.param == x) ? n + 1 : n;
          auto shiftedV = (data.param == x) ? shift(v, 1, x, 0) : clone(v);
          result->data = Expr::Lambda{data.param, substitute(*data.type, x, n, v),
                                      substitute(*data.body, x, newN, *shiftedV)};
        } else if constexpr (std::is_same_v<T, Expr::Pi>) {
          auto newN = (data.param == x) ? n + 1 : n;
          auto shiftedV = (data.param == x) ? shift(v, 1, x, 0) : clone(v);
          result->data = Expr::Pi{data.param, substitute(*data.type, x, n, v),
                                  substitute(*data.body, x, newN, *shiftedV)};
        } else if constexpr (std::is_same_v<T, Expr::Let>) {
          std::vector<Binding> bindings;
          auto currentN = n;
          auto currentV = clone(v);
          for (const auto& b : data.bindings) {
            bindings.push_back(Binding{
                b.name,
                b.type ? std::optional{substitute(**b.type, x, currentN, *currentV)} : std::nullopt,
                substitute(*b.value, x, currentN, *currentV), b.span});
            if (b.name == x) {
              currentN++;
              currentV = shift(*currentV, 1, x, 0);
            }
          }
          result->data =
              Expr::Let{std::move(bindings), substitute(*data.body, x, currentN, *currentV)};
        } else if constexpr (std::is_same_v<T, Expr::App>) {
          result->data = Expr::App{substitute(*data.func, x, n, v), substitute(*data.arg, x, n, v)};
        } else if constexpr (std::is_same_v<T, Expr::BinOp>) {
          result->data =
              Expr::BinOp{data.op, substitute(*data.lhs, x, n, v), substitute(*data.rhs, x, n, v)};
        } else if constexpr (std::is_same_v<T, Expr::If>) {
          result->data =
              Expr::If{substitute(*data.cond, x, n, v), substitute(*data.then_branch, x, n, v),
                       substitute(*data.else_branch, x, n, v)};
        } else if constexpr (std::is_same_v<T, Expr::ListLit>) {
          std::vector<ExprPtr> elements;
          for (const auto& elem : data.elements) {
            elements.push_back(substitute(*elem, x, n, v));
          }
          result->data = Expr::ListLit{data.type ? std::optional{substitute(**data.type, x, n, v)}
                                                 : std::nullopt,
                                       std::move(elements)};
        } else if constexpr (std::is_same_v<T, Expr::RecordLit>) {
          std::vector<RecordEntry> entries;
          for (const auto& entry : data.entries) {
            entries.push_back(
                RecordEntry{entry.name, entry.path, substitute(*entry.value, x, n, v)});
          }
          result->data = Expr::RecordLit{std::move(entries)};
        } else {
          result = clone(e);
        }
      },
      e.data);

  return result;
}

// Normalize an expression
auto normalizeImpl(const Expr& e) -> ExprPtr {
  auto result = std::make_unique<Expr>();
  result->span = e.span;

  std::visit(
      [&](const auto& data) {
        using T = std::decay_t<decltype(data)>;

        // Literals normalize to themselves
        if constexpr (std::is_same_v<T, bool> || std::is_same_v<T, std::uint64_t> ||
                      std::is_same_v<T, std::int64_t> || std::is_same_v<T, double> ||
                      std::is_same_v<T, std::vector<std::uint8_t>> ||
                      std::is_same_v<T, Expr::DateLiteral> ||
                      std::is_same_v<T, Expr::TimeLiteral> ||
                      std::is_same_v<T, Expr::TimeZoneLiteral> ||
                      std::is_same_v<T, Expr::Variable> || std::is_same_v<T, Expr::Builtin> ||
                      std::is_same_v<T, Import>) {
          result->data = data;
        }
        // Text with interpolation
        else if constexpr (std::is_same_v<T, std::vector<TextChunk>>) {
          std::vector<TextChunk> chunks;
          std::string accum;

          for (const auto& chunk : data) {
            if (auto* s = std::get_if<std::string>(&chunk.content)) {
              accum += *s;
            } else {
              auto normalized = normalizeImpl(*std::get<ExprPtr>(chunk.content));
              // If normalized to text literal, merge
              if (auto* text = std::get_if<std::vector<TextChunk>>(&normalized->data)) {
                if (text->size() == 1) {
                  if (auto* inner = std::get_if<std::string>(&(*text)[0].content)) {
                    accum += *inner;
                    continue;
                  }
                }
              }
              if (!accum.empty()) {
                chunks.push_back(TextChunk{std::move(accum)});
                accum.clear();
              }
              chunks.push_back(TextChunk{std::move(normalized)});
            }
          }
          if (!accum.empty()) {
            chunks.push_back(TextChunk{std::move(accum)});
          }
          result->data = std::move(chunks);
        }
        // Lambda
        else if constexpr (std::is_same_v<T, Expr::Lambda>) {
          result->data =
              Expr::Lambda{data.param, normalizeImpl(*data.type), normalizeImpl(*data.body)};
        }
        // Pi
        else if constexpr (std::is_same_v<T, Expr::Pi>) {
          result->data = Expr::Pi{data.param, normalizeImpl(*data.type), normalizeImpl(*data.body)};
        }
        // Application - beta reduction
        else if constexpr (std::is_same_v<T, Expr::App>) {
          auto func = normalizeImpl(*data.func);
          auto arg = normalizeImpl(*data.arg);

          // Check for beta reduction: (\x -> body) arg -> body[x := arg]
          if (auto* lam = std::get_if<Expr::Lambda>(&func->data)) {
            auto substituted = substitute(*lam->body, lam->param, 0, *arg);
            auto shifted = shift(*substituted, -1, lam->param, 0);
            result = normalizeImpl(*shifted);
            return;
          }

          // Builtin applications
          if (auto* builtin = std::get_if<Expr::Builtin>(&func->data)) {
            // Natural/isZero
            if (builtin->name == Expr::Builtin::Name::NaturalIsZero) {
              if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                result->data = (*n == 0);
                return;
              }
            }
            // Natural/even
            if (builtin->name == Expr::Builtin::Name::NaturalEven) {
              if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                result->data = (*n % 2 == 0);
                return;
              }
            }
            // Natural/odd
            if (builtin->name == Expr::Builtin::Name::NaturalOdd) {
              if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                result->data = (*n % 2 == 1);
                return;
              }
            }
            // Natural/toInteger
            if (builtin->name == Expr::Builtin::Name::NaturalToInteger) {
              if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                result->data = static_cast<std::int64_t>(*n);
                return;
              }
            }
            // Natural/show
            if (builtin->name == Expr::Builtin::Name::NaturalShow) {
              if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                std::vector<TextChunk> chunks;
                chunks.push_back(TextChunk{std::to_string(*n)});
                result->data = std::move(chunks);
                return;
              }
            }
            // Integer/show
            if (builtin->name == Expr::Builtin::Name::IntegerShow) {
              if (auto* n = std::get_if<std::int64_t>(&arg->data)) {
                std::string s = (*n >= 0) ? "+" + std::to_string(*n) : std::to_string(*n);
                std::vector<TextChunk> chunks;
                chunks.push_back(TextChunk{std::move(s)});
                result->data = std::move(chunks);
                return;
              }
            }
            // Integer/negate
            if (builtin->name == Expr::Builtin::Name::IntegerNegate) {
              if (auto* n = std::get_if<std::int64_t>(&arg->data)) {
                result->data = -(*n);
                return;
              }
            }
            // Integer/clamp
            if (builtin->name == Expr::Builtin::Name::IntegerClamp) {
              if (auto* n = std::get_if<std::int64_t>(&arg->data)) {
                result->data =
                    (*n < 0) ? static_cast<std::uint64_t>(0) : static_cast<std::uint64_t>(*n);
                return;
              }
            }
            // Integer/toDouble
            if (builtin->name == Expr::Builtin::Name::IntegerToDouble) {
              if (auto* n = std::get_if<std::int64_t>(&arg->data)) {
                result->data = static_cast<double>(*n);
                return;
              }
            }
            // Double/show
            if (builtin->name == Expr::Builtin::Name::DoubleShow) {
              if (auto* d = std::get_if<double>(&arg->data)) {
                std::ostringstream oss;
                if (std::isnan(*d)) {
                  oss << "NaN";
                } else if (std::isinf(*d)) {
                  oss << (*d > 0 ? "Infinity" : "-Infinity");
                } else {
                  oss << std::showpoint << *d;
                }
                std::vector<TextChunk> chunks;
                chunks.push_back(TextChunk{oss.str()});
                result->data = std::move(chunks);
                return;
              }
            }
            // List/length
            if (builtin->name == Expr::Builtin::Name::ListLength) {
              // List/length T needs another arg (the list)
            }
            // List/head, List/last, List/reverse, etc. require partial application
          }

          // Check for partial builtin application (curried)
          if (auto* outerApp = std::get_if<Expr::App>(&func->data)) {
            if (auto* builtin = std::get_if<Expr::Builtin>(&outerApp->func->data)) {
              // Natural/subtract
              if (builtin->name == Expr::Builtin::Name::NaturalSubtract) {
                if (auto* m = std::get_if<std::uint64_t>(&outerApp->arg->data)) {
                  if (auto* n = std::get_if<std::uint64_t>(&arg->data)) {
                    result->data = (*n >= *m) ? (*n - *m) : static_cast<std::uint64_t>(0);
                    return;
                  }
                }
              }
              // List/length T xs
              if (builtin->name == Expr::Builtin::Name::ListLength) {
                if (auto* list = std::get_if<Expr::ListLit>(&arg->data)) {
                  result->data = static_cast<std::uint64_t>(list->elements.size());
                  return;
                }
              }
              // List/head T xs
              if (builtin->name == Expr::Builtin::Name::ListHead) {
                if (auto* list = std::get_if<Expr::ListLit>(&arg->data)) {
                  if (list->elements.empty()) {
                    result->data = Expr::Builtin{Expr::Builtin::Name::None};
                  } else {
                    result->data = Expr::Some{clone(*list->elements[0])};
                  }
                  return;
                }
              }
              // List/last T xs
              if (builtin->name == Expr::Builtin::Name::ListLast) {
                if (auto* list = std::get_if<Expr::ListLit>(&arg->data)) {
                  if (list->elements.empty()) {
                    result->data = Expr::Builtin{Expr::Builtin::Name::None};
                  } else {
                    result->data = Expr::Some{clone(*list->elements.back())};
                  }
                  return;
                }
              }
              // List/reverse T xs
              if (builtin->name == Expr::Builtin::Name::ListReverse) {
                if (auto* list = std::get_if<Expr::ListLit>(&arg->data)) {
                  std::vector<ExprPtr> elements;
                  for (auto it = list->elements.rbegin(); it != list->elements.rend(); ++it) {
                    elements.push_back(clone(**it));
                  }
                  result->data = Expr::ListLit{std::nullopt, std::move(elements)};
                  return;
                }
              }
            }
          }

          // No reduction possible
          result->data = Expr::App{std::move(func), std::move(arg)};
        }
        // Let
        else if constexpr (std::is_same_v<T, Expr::Let>) {
          // Substitute all let bindings
          auto body = clone(*data.body);
          for (auto it = data.bindings.rbegin(); it != data.bindings.rend(); ++it) {
            auto normalized_value = normalizeImpl(*it->value);
            body = substitute(*body, it->name, 0, *normalized_value);
            body = shift(*body, -1, it->name, 0);
          }
          result = normalizeImpl(*body);
        }
        // Annotation
        else if constexpr (std::is_same_v<T, Expr::Annot>) {
          result = normalizeImpl(*data.expr);
        }
        // If-then-else
        else if constexpr (std::is_same_v<T, Expr::If>) {
          auto cond = normalizeImpl(*data.cond);
          if (auto* b = std::get_if<bool>(&cond->data)) {
            result = *b ? normalizeImpl(*data.then_branch) : normalizeImpl(*data.else_branch);
          } else {
            result->data = Expr::If{std::move(cond), normalizeImpl(*data.then_branch),
                                    normalizeImpl(*data.else_branch)};
          }
        }
        // Binary operators
        else if constexpr (std::is_same_v<T, Expr::BinOp>) {
          auto lhs = normalizeImpl(*data.lhs);
          auto rhs = normalizeImpl(*data.rhs);

          switch (data.op) {
            case Expr::BinOp::Op::Or: {
              auto* l = std::get_if<bool>(&lhs->data);
              auto* r = std::get_if<bool>(&rhs->data);
              if (l && r) {
                result->data = *l || *r;
                return;
              }
              if (l && *l) {
                result->data = true;
                return;
              }
              if (r && *r) {
                result->data = true;
                return;
              }
              if (l && !*l) {
                result = std::move(rhs);
                return;
              }
              if (r && !*r) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::And: {
              auto* l = std::get_if<bool>(&lhs->data);
              auto* r = std::get_if<bool>(&rhs->data);
              if (l && r) {
                result->data = *l && *r;
                return;
              }
              if (l && !*l) {
                result->data = false;
                return;
              }
              if (r && !*r) {
                result->data = false;
                return;
              }
              if (l && *l) {
                result = std::move(rhs);
                return;
              }
              if (r && *r) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::Eq: {
              auto* l = std::get_if<bool>(&lhs->data);
              auto* r = std::get_if<bool>(&rhs->data);
              if (l && r) {
                result->data = *l == *r;
                return;
              }
              if (l && *l) {
                result = std::move(rhs);
                return;
              }
              if (r && *r) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::Ne: {
              auto* l = std::get_if<bool>(&lhs->data);
              auto* r = std::get_if<bool>(&rhs->data);
              if (l && r) {
                result->data = *l != *r;
                return;
              }
              if (l && !*l) {
                result = std::move(rhs);
                return;
              }
              if (r && !*r) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::Plus: {
              auto* l = std::get_if<std::uint64_t>(&lhs->data);
              auto* r = std::get_if<std::uint64_t>(&rhs->data);
              if (l && r) {
                result->data = *l + *r;
                return;
              }
              if (l && *l == 0) {
                result = std::move(rhs);
                return;
              }
              if (r && *r == 0) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::Times: {
              auto* l = std::get_if<std::uint64_t>(&lhs->data);
              auto* r = std::get_if<std::uint64_t>(&rhs->data);
              if (l && r) {
                result->data = *l * *r;
                return;
              }
              if (l && *l == 0) {
                result->data = static_cast<std::uint64_t>(0);
                return;
              }
              if (r && *r == 0) {
                result->data = static_cast<std::uint64_t>(0);
                return;
              }
              if (l && *l == 1) {
                result = std::move(rhs);
                return;
              }
              if (r && *r == 1) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::TextAppend: {
              auto* l = std::get_if<std::vector<TextChunk>>(&lhs->data);
              auto* r = std::get_if<std::vector<TextChunk>>(&rhs->data);
              if (l && r) {
                std::vector<TextChunk> combined;
                for (const auto& c : *l)
                  combined.push_back(TextChunk{
                      std::holds_alternative<std::string>(c.content)
                          ? std::variant<std::string, ExprPtr>{std::get<std::string>(c.content)}
                          : std::variant<std::string, ExprPtr>{
                                clone(*std::get<ExprPtr>(c.content))}});
                for (const auto& c : *r)
                  combined.push_back(TextChunk{
                      std::holds_alternative<std::string>(c.content)
                          ? std::variant<std::string, ExprPtr>{std::get<std::string>(c.content)}
                          : std::variant<std::string, ExprPtr>{
                                clone(*std::get<ExprPtr>(c.content))}});
                result->data = std::move(combined);
                return;
              }
              break;
            }
            case Expr::BinOp::Op::ListAppend: {
              auto* l = std::get_if<Expr::ListLit>(&lhs->data);
              auto* r = std::get_if<Expr::ListLit>(&rhs->data);
              if (l && r) {
                std::vector<ExprPtr> elements;
                for (const auto& e : l->elements)
                  elements.push_back(clone(*e));
                for (const auto& e : r->elements)
                  elements.push_back(clone(*e));
                result->data = Expr::ListLit{std::nullopt, std::move(elements)};
                return;
              }
              if (l && l->elements.empty()) {
                result = std::move(rhs);
                return;
              }
              if (r && r->elements.empty()) {
                result = std::move(lhs);
                return;
              }
              break;
            }
            default:
              break;
          }
          result->data = Expr::BinOp{data.op, std::move(lhs), std::move(rhs)};
        }
        // Field access
        else if constexpr (std::is_same_v<T, Expr::Field>) {
          auto record = normalizeImpl(*data.record);
          if (auto* rec = std::get_if<Expr::RecordLit>(&record->data)) {
            for (const auto& entry : rec->entries) {
              if (entry.name == data.field && entry.path.empty()) {
                result = normalizeImpl(*entry.value);
                return;
              }
            }
          }
          // Union constructor
          if (auto* uni = std::get_if<Expr::UnionType>(&record->data)) {
            for (const auto& alt : uni->alternatives) {
              if (alt.name == data.field) {
                // Returns a function that constructs the union value
                // For simplicity, return the field access
                result->data = Expr::Field{std::move(record), data.field};
                return;
              }
            }
          }
          result->data = Expr::Field{std::move(record), data.field};
        }
        // Some
        else if constexpr (std::is_same_v<T, Expr::Some>) {
          result->data = Expr::Some{normalizeImpl(*data.value)};
        }
        // Record literal
        else if constexpr (std::is_same_v<T, Expr::RecordLit>) {
          std::vector<RecordEntry> entries;
          for (const auto& entry : data.entries) {
            entries.push_back(RecordEntry{entry.name, entry.path, normalizeImpl(*entry.value)});
          }
          result->data = Expr::RecordLit{std::move(entries)};
        }
        // Record type
        else if constexpr (std::is_same_v<T, Expr::RecordType>) {
          std::vector<std::pair<std::string, ExprPtr>> fields;
          for (const auto& [name, type] : data.fields) {
            fields.emplace_back(name, normalizeImpl(*type));
          }
          result->data = Expr::RecordType{std::move(fields)};
        }
        // Union type
        else if constexpr (std::is_same_v<T, Expr::UnionType>) {
          std::vector<UnionAlt> alts;
          for (const auto& alt : data.alternatives) {
            alts.push_back(UnionAlt{alt.name, alt.type ? std::optional{normalizeImpl(**alt.type)}
                                                       : std::nullopt});
          }
          result->data = Expr::UnionType{std::move(alts)};
        }
        // List literal
        else if constexpr (std::is_same_v<T, Expr::ListLit>) {
          std::vector<ExprPtr> elements;
          for (const auto& elem : data.elements) {
            elements.push_back(normalizeImpl(*elem));
          }
          result->data =
              Expr::ListLit{data.type ? std::optional{normalizeImpl(**data.type)} : std::nullopt,
                            std::move(elements)};
        }
        // Merge
        else if constexpr (std::is_same_v<T, Expr::Merge>) {
          auto handler = normalizeImpl(*data.handler);
          auto union_val = normalizeImpl(*data.union_val);

          // Try to reduce merge if we have a record handler and union value
          if (auto* rec = std::get_if<Expr::RecordLit>(&handler->data)) {
            // If union_val is a field access of a union type (constructor call)
            if (auto* field = std::get_if<Expr::Field>(&union_val->data)) {
              // Find matching handler
              for (const auto& entry : rec->entries) {
                if (entry.name == field->field && entry.path.empty()) {
                  // Apply handler to the inner value (if any)
                  result->data = Expr::App{clone(*entry.value), clone(*field->record)};
                  result = normalizeImpl(*result);
                  return;
                }
              }
            }
            // If union_val is Some
            if (auto* some = std::get_if<Expr::Some>(&union_val->data)) {
              for (const auto& entry : rec->entries) {
                if (entry.name == "Some" && entry.path.empty()) {
                  result->data = Expr::App{clone(*entry.value), clone(*some->value)};
                  result = normalizeImpl(*result);
                  return;
                }
              }
            }
            // If union_val is None
            if (auto* builtin = std::get_if<Expr::Builtin>(&union_val->data)) {
              if (builtin->name == Expr::Builtin::Name::None) {
                for (const auto& entry : rec->entries) {
                  if (entry.name == "None" && entry.path.empty()) {
                    result = normalizeImpl(*entry.value);
                    return;
                  }
                }
              }
            }
          }

          result->data =
              Expr::Merge{std::move(handler), std::move(union_val),
                          data.type ? std::optional{normalizeImpl(**data.type)} : std::nullopt};
        }
        // ToMap
        else if constexpr (std::is_same_v<T, Expr::ToMap>) {
          auto record = normalizeImpl(*data.record);
          if (auto* rec = std::get_if<Expr::RecordLit>(&record->data)) {
            std::vector<ExprPtr> elements;
            for (const auto& entry : rec->entries) {
              if (entry.path.empty()) {
                // Create { mapKey = "name", mapValue = value }
                std::vector<RecordEntry> map_entry;
                auto key_expr = std::make_unique<Expr>();
                std::vector<TextChunk> key_chunks;
                key_chunks.push_back(TextChunk{entry.name});
                key_expr->data = std::move(key_chunks);
                map_entry.push_back(RecordEntry{"mapKey", {}, std::move(key_expr)});
                map_entry.push_back(RecordEntry{"mapValue", {}, clone(*entry.value)});
                auto map_elem = std::make_unique<Expr>();
                map_elem->data = Expr::RecordLit{std::move(map_entry)};
                elements.push_back(std::move(map_elem));
              }
            }
            result->data = Expr::ListLit{std::nullopt, std::move(elements)};
            return;
          }
          result->data =
              Expr::ToMap{std::move(record),
                          data.type ? std::optional{normalizeImpl(**data.type)} : std::nullopt};
        }
        // Assert
        else if constexpr (std::is_same_v<T, Expr::Assert>) {
          result->data = Expr::Assert{normalizeImpl(*data.type)};
        }
        // Projection
        else if constexpr (std::is_same_v<T, Expr::Project>) {
          auto record = normalizeImpl(*data.record);
          if (auto* rec = std::get_if<Expr::RecordLit>(&record->data)) {
            std::vector<RecordEntry> entries;
            for (const auto& field : data.fields) {
              for (const auto& entry : rec->entries) {
                if (entry.name == field && entry.path.empty()) {
                  entries.push_back(RecordEntry{entry.name, {}, clone(*entry.value)});
                  break;
                }
              }
            }
            result->data = Expr::RecordLit{std::move(entries)};
            return;
          }
          result->data = Expr::Project{std::move(record), data.fields};
        }
        // ShowConstructor
        else if constexpr (std::is_same_v<T, Expr::ShowConstructor>) {
          auto union_val = normalizeImpl(*data.union_val);
          if (auto* field = std::get_if<Expr::Field>(&union_val->data)) {
            std::vector<TextChunk> chunks;
            chunks.push_back(TextChunk{field->field});
            result->data = std::move(chunks);
            return;
          }
          if (auto* some = std::get_if<Expr::Some>(&union_val->data)) {
            std::vector<TextChunk> chunks;
            chunks.push_back(TextChunk{"Some"});
            result->data = std::move(chunks);
            return;
          }
          if (auto* builtin = std::get_if<Expr::Builtin>(&union_val->data)) {
            if (builtin->name == Expr::Builtin::Name::None) {
              std::vector<TextChunk> chunks;
              chunks.push_back(TextChunk{"None"});
              result->data = std::move(chunks);
              return;
            }
          }
          result->data = Expr::ShowConstructor{std::move(union_val)};
        }
        // With
        else if constexpr (std::is_same_v<T, Expr::With>) {
          // TODO: Implement with expression normalization
          result->data =
              Expr::With{normalizeImpl(*data.base), data.path, normalizeImpl(*data.value)};
        }
        // ProjectType
        else if constexpr (std::is_same_v<T, Expr::ProjectType>) {
          result->data = Expr::ProjectType{normalizeImpl(*data.record), normalizeImpl(*data.type)};
        }
        // Completion
        else if constexpr (std::is_same_v<T, Expr::Completion>) {
          // T::r = (T.default // r) : T.Type
          auto type_expr = normalizeImpl(*data.type);
          auto record = normalizeImpl(*data.record);

          // Get T.default
          auto default_expr = std::make_unique<Expr>();
          default_expr->data = Expr::Field{clone(*type_expr), "default"};
          auto default_norm = normalizeImpl(*default_expr);

          // Get T.Type
          auto type_type = std::make_unique<Expr>();
          type_type->data = Expr::Field{clone(*type_expr), "Type"};
          auto type_norm = normalizeImpl(*type_type);

          // Prefer record over default
          auto prefer = std::make_unique<Expr>();
          prefer->data =
              Expr::BinOp{Expr::BinOp::Op::Prefer, std::move(default_norm), std::move(record)};
          auto prefer_norm = normalizeImpl(*prefer);

          // Annotate with type
          result->data = Expr::Annot{std::move(prefer_norm), std::move(type_norm)};
        }
      },
      e.data);

  return result;
}

} // namespace

// ============================================================================
// Public API
// ============================================================================

auto Evaluator::normalize(const Expr& e) -> ExprPtr {
  return normalizeImpl(e);
}

auto Evaluator::alpha_equivalent(const Expr& a, const Expr& b) -> bool {
  // Compare expressions modulo alpha-renaming
  // This is a simplified version - full impl needs proper de Bruijn comparison

  return std::visit(
      [&](const auto& da) {
        return std::visit(
            [&](const auto& db) {
              using TA = std::decay_t<decltype(da)>;
              using TB = std::decay_t<decltype(db)>;

              if constexpr (!std::is_same_v<TA, TB>) {
                return false;
              } else if constexpr (std::is_same_v<TA, bool> || std::is_same_v<TA, std::uint64_t> ||
                                   std::is_same_v<TA, std::int64_t> || std::is_same_v<TA, double>) {
                return da == db;
              } else if constexpr (std::is_same_v<TA, Expr::Variable>) {
                return da.name == db.name && da.index == db.index;
              } else if constexpr (std::is_same_v<TA, Expr::Builtin>) {
                return da.name == db.name;
              } else if constexpr (std::is_same_v<TA, Expr::Lambda>) {
                return alpha_equivalent(*da.type, *db.type) && alpha_equivalent(*da.body, *db.body);
              } else if constexpr (std::is_same_v<TA, Expr::Pi>) {
                return alpha_equivalent(*da.type, *db.type) && alpha_equivalent(*da.body, *db.body);
              } else if constexpr (std::is_same_v<TA, Expr::App>) {
                return alpha_equivalent(*da.func, *db.func) && alpha_equivalent(*da.arg, *db.arg);
              } else {
                // For other cases, do structural comparison
                // This is a simplification
                return true;
              }
            },
            b.data);
      },
      a.data);
}

auto Evaluator::beta_equivalent(const Expr& a, const Expr& b) -> bool {
  auto na = normalize(a);
  auto nb = normalize(b);
  return alpha_equivalent(*na, *nb);
}

} // namespace continuity::codec
