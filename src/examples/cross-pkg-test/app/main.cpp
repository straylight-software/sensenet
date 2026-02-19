// main.cpp - App that uses greeter library
#include <iostream>

#include "../lib/greeter.hpp"

int main() {
  std::cout << greeter::greet("World") << std::endl;
  return 0;
}
