#include "hardware/vip/common/logging.h"

#include <cstdlib>

#include "spdlog/sinks/stdout_color_sinks.h"

namespace vip {
namespace {

spdlog::level::level_enum LevelFromEnvironment() {
  const char* level = std::getenv("VIP_LOG_LEVEL");
  if (level == nullptr) return spdlog::level::info;
  const spdlog::level::level_enum parsed = spdlog::level::from_str(level);
  // from_str returns `off` for anything it does not recognise, which would
  // silently discard the whole log. A typo in an environment variable should
  // not look like a quiet run.
  if (parsed == spdlog::level::off && std::string(level) != "off") {
    spdlog::warn("VIP_LOG_LEVEL='{}' is not a level; using info", level);
    return spdlog::level::info;
  }
  return parsed;
}

}  // namespace

std::shared_ptr<spdlog::logger> Logger(const std::string& name) {
  if (std::shared_ptr<spdlog::logger> existing = spdlog::get(name)) return existing;

  std::shared_ptr<spdlog::logger> logger = spdlog::stderr_color_mt(name);
  logger->set_level(LevelFromEnvironment());
  // Stderr, so that a testbench's $display and an agent's log interleave in the
  // order they happened rather than in the order two buffers were flushed.
  logger->set_pattern("[%n] %v");
  return logger;
}

}  // namespace vip
