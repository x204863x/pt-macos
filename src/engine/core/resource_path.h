#pragma once

#include <filesystem>
#include <string_view>

namespace pt {

std::filesystem::path ExecutableDir();
/* The path of the running executable. Helper processes (museum/loop previews) start this; SDL_GetBasePath() is Contents/Resources
   inside a macOS bundle, where the executable is not. */
std::filesystem::path SelfExecutablePath();
std::filesystem::path ResourceDir(std::string_view name, const std::filesystem::path& build_dir);

}
