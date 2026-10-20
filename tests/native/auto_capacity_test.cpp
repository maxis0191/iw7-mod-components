#include "../../src/native/auto_capacity_policy.hpp"
#include <cassert>
#include <iostream>
#ifdef _WIN32
#include <Windows.h>
#include <shellapi.h>
#endif
int main() {
    using namespace auto_capacity;
    assert(parse_wire("")==layout::standard && parse_wire("24")==layout::standard);
    assert(parse_wire("64-v2")==layout::expanded && parse_wire("64-v1")==layout::unknown);
    assert(switch_allowed(false,"64-v2",3));
    assert(switch_allowed(true,"",2) && switch_allowed(true,"24",3));
    assert(!switch_allowed(false,"64-v2",2) && !switch_allowed(true,"64-v2",3));
    assert(!switch_allowed(false,"64-v1",3) && !switch_allowed(true,"unknown",3));
    for(auto bad:{L"127.0.0.1:0",L"127.0.0.1:65536",L"256.0.0.1:27016",L"127.0.0.1:27016 +quit",L"server:27016",L"../bad",L"127.0.0.1:1:2"}) assert(!endpoint(bad));
    assert(endpoint(L"127.0.0.1:27946") && endpoint(L"1.2.3.4:27016"));
    const std::vector<std::wstring> initial={L"C:\\game path\\iw7.exe",L"-nosteam",L"+set",L"name",L"a b\\\"",L"-paris-auto-target=127.0.0.1:27946",L"-PARIS-CAPACITY-64",L"+set",L"password",L"old password"};
    auto expanded=arguments(initial,L"127.0.0.1:27946",3,true,L"123:456");
    std::vector<std::wstring> next={initial[0]};next.insert(next.end(),expanded.begin(),expanded.end());
    const auto standard=arguments(next,L"127.0.0.1:27947",3,false,L"124:457");
    unsigned targets{},capacity{},parent{};
    for(const auto& arg:standard) {targets+=arg.find(L"-paris-auto-target=")==0;capacity+=arg==L"-paris-capacity-64";parent+=arg.find(L"-paris-auto-parent=")==0;}
    assert(targets==1 && capacity==0 && parent==1 && standard[3]==L"a b\\\"");
#ifdef _WIN32
    for(const auto& values:{initial,next,standard}) {
        std::wstring line;
        for(const auto& arg:values) {if(!line.empty())line+=L' ';line+=quote(arg);}
        int count{};const auto parsed=CommandLineToArgvW(line.c_str(),&count);assert(parsed && count==static_cast<int>(values.size()));
        for(int i=0;i<count;++i)assert(values[static_cast<std::size_t>(i)]==parsed[i]);LocalFree(parsed);
    }
#endif
    std::cout<<"Automatic profiles: wire negotiation, CP/MP, unknown refusal, endpoint parsing, restart argument isolation and Windows quoting PASS\n";
}
