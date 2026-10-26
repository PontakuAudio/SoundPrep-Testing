#pragma once
// Identical acceptance inputs run against the actual Cocoa and Win32 parsers.
#include "vendor/json.hpp"
#include <fstream>
#include <stdexcept>
#include <string>
inline void test_bar_contract(bool(*set_state)(const char*)) {
  std::ifstream input("tests/native-bar-cases.json");
  if(!input)throw std::runtime_error("Missing shared native bar cases; run from the repository root");
  const auto fixture=nlohmann::json::parse(input);
  for(const auto& test:fixture.at("cases")) {
    auto state=fixture.at("base");
    if(test.contains("set"))state.update(test.at("set"));
    if(test.contains("remove"))for(const auto& key:test.at("remove"))state.erase(key.get<std::string>());
    if(set_state(state.dump().c_str())!=test.at("accept").get<bool>())
      throw std::runtime_error("Native bar contract: "+test.at("name").get<std::string>());
  }
}
