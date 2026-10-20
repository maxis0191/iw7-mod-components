#pragma once
#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>

namespace auto_capacity {
enum class layout { unknown, standard, expanded };
inline layout parse_wire(std::string_view wire) noexcept {
    if (wire.empty() || wire == "24") return layout::standard;
    return wire == "64-v2" ? layout::expanded : layout::unknown;
}
inline bool switch_allowed(bool expanded, std::string_view wire, int mode) noexcept {
    const auto wanted=parse_wire(wire);
    return wanted!=layout::unknown && (mode==2 || mode==3) &&
        (wanted!=layout::expanded || mode==3) &&
        expanded!=(wanted==layout::expanded);
}
inline bool endpoint(std::wstring_view text) noexcept {
    const auto colon=text.find(L':');
    if (colon==text.npos || text.find(L':',colon+1)!=text.npos) return false;
    unsigned octets{}, value{}, digits{};
    for (std::size_t i=0;i<=colon;++i) {
        const auto c=i==colon ? L'.' : text[i];
        if(c>=L'0' && c<=L'9') {if(++digits>3) return false;value=value*10+unsigned(c-L'0');}
        else if(c==L'.') {if(!digits || value>255) return false;++octets;value=digits=0;}
        else return false;
    }
    if(octets!=4 || colon+1==text.size()) return false;
    value=digits=0;
    for(auto c:text.substr(colon+1)) {if(c<L'0'||c>L'9'||++digits>5) return false;value=value*10+unsigned(c-L'0');}
    return value>0 && value<=65535;
}
// Windows CommandLineToArgvW inverse: no shell, command interpolation or eval.
inline std::wstring quote(std::wstring_view value) {
    std::wstring result=L"\"";std::size_t slashes{};
    for(auto c:value) {
        if(c==L'\\') {++slashes;continue;}
        if(c==L'\"') {result.append(slashes*2+1,L'\\');result+=c;}
        else {result.append(slashes,L'\\');result+=c;}
        slashes=0;
    }
    result.append(slashes*2,L'\\');return result+L'\"';
}
inline bool controlled(std::wstring_view s) {
    std::wstring lower(s);
    for(auto& c:lower)if(c>=L'A' && c<=L'Z')c=static_cast<wchar_t>(c+L'a'-L'A');
    return lower==L"-cpmode" || lower==L"-zombies" || lower==L"-paris-capacity-64" ||
        lower==L"-paris-capacity-production" || lower==L"-paris-capacity-client-probe" ||
        lower.substr(0,12)==L"-paris-auto-";
}
inline std::vector<std::wstring> arguments(const std::vector<std::wstring>& current,
    std::wstring_view target,int mode,bool expanded,std::wstring_view parent) {
    if(!endpoint(target) || (mode!=2 && mode!=3) || (expanded && mode!=3))
        throw std::runtime_error("Invalid automatic profile request");
    std::vector<std::wstring> out;
    for(std::size_t i=1;i<current.size();++i) {
        if(controlled(current[i])) continue;
        if(current[i]==L"+connect") {if(i+1<current.size())++i;continue;}
        if(current[i]==L"+set" && i+2<current.size() &&
            (current[i+1]==L"password" || current[i+1]==L"fs_game")) {i+=2;continue;}
        out.push_back(current[i]);
    }
    out.push_back(L"-noupdate");
    if(mode==3) out.push_back(L"-cpMode");
    if(expanded) {out.push_back(L"-paris-capacity-64");out.push_back(L"-paris-capacity-production");}
    out.emplace_back(L"-paris-auto-target="+std::wstring(target));
    out.emplace_back(L"-paris-auto-mode="+std::to_wstring(mode));
    out.emplace_back(expanded?L"-paris-auto-required=64-v2":L"-paris-auto-required=24");
    out.emplace_back(L"-paris-auto-parent="+std::wstring(parent));
    return out;
}
}
