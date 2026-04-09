// greeter.cpp - Simple greeting library implementation
#include "greeter.hpp"

namespace greeter {
std::string greet(const std::string& name) {
  return "Hello, " + name + "!";
}
} // namespace greeter
