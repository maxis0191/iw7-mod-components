#include "io.hpp"
#include "properties.hpp"
#include "flags.hpp"
#include <gsl/gsl>
#include <ShlObj.h>

namespace utils::properties
{
    std::filesystem::path get_appdata_path()
    {
        static const auto appdata = []() -> std::filesystem::path
        {
            // Explicit process opt-in: never use the owner's Aurora profile.
            if (utils::flags::has_flag("paris-isolated-lab"))
            {
                const auto root = std::filesystem::current_path() / "iw7-mod";
                std::string marker;
                if (!utils::io::read_file((root / "paris-isolated-lab.marker").string(), &marker) ||
                    marker != "iw7-paris-isolated-lab-v1")
                    throw std::runtime_error("Isolated lab marker missing; refusing shared AppData.");
                return root / "lab-appdata";
            }
            PWSTR path = nullptr;
            if (!SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &path)))
                throw std::runtime_error("Failed to read APPDATA path!");
            auto cleanup = gsl::finally([&path] { CoTaskMemFree(path); });
            return std::filesystem::path(path) / "auroramod/iw7-mod";
        }();
        return appdata;
    }
}
