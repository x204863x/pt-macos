#include "engine/core/resource_path.h"

#include <SDL3/SDL.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>

#include <string>
#include <vector>
#endif

namespace pt {

std::filesystem::path ExecutableDir() {
    const char* base = SDL_GetBasePath();
    return base ? std::filesystem::path(reinterpret_cast<const char8_t*>(base)) : std::filesystem::current_path();
}

std::filesystem::path SelfExecutablePath() {
#ifdef __APPLE__
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> buffer(size + 1, '\0');
    if (_NSGetExecutablePath(buffer.data(), &size) == 0) {
        std::error_code ec;
        const auto canonical = std::filesystem::canonical(std::filesystem::path(buffer.data()), ec);
        return ec ? std::filesystem::path(buffer.data()) : canonical;
    }
#endif
    return ExecutableDir() /
#ifdef _WIN32
        "pt.exe";
#else
        "pt";
#endif
}

std::filesystem::path ResourceDir(std::string_view name, const std::filesystem::path& build_dir) {
    std::error_code ec;
    const std::filesystem::path local = ExecutableDir() / name;
    if (std::filesystem::is_directory(local, ec)) {
        return local;
    }
    return build_dir;
}

}
