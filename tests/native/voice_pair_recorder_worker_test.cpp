// Pure lifecycle worker. It never loads audio APIs, connects or reads devices.
#define NOMINMAX
#include <windows.h>
#include <fstream>
#include <iostream>
#include <string>
#include <array>
#include <cstdint>
int main(int argc,char** argv) {
    if(argc!=8 || std::string(argv[1])!="--record")return 2;
    std::cout<<"WASAPI recording ready: scope=process_tree pid="<<argv[3]<<" creation="<<argv[4]
        <<" format=pcm16 rate=48000 channels=2 tick_ms="<<GetTickCount64()<<" fallback=0\n"<<std::flush;
    if(std::string(argv[2])=="3"){Sleep(5000);return 0;}
    // The parent acknowledges readiness explicitly; metadata/JIT speed must
    // not decide whether this lifecycle test observes a live or exited child.
    if(std::string(argv[2])!="4") {
        const std::string release=std::string(argv[7])+".release";
        const auto deadline=GetTickCount64()+10000;
        while(GetFileAttributesA(release.c_str())==INVALID_FILE_ATTRIBUTES) {
            if(GetTickCount64()>=deadline)return 4;
            Sleep(10);
        }
    }
    std::array<unsigned char,44> h{};
    const auto tag=[&](size_t p,const char* s){for(size_t i=0;i<4;++i)h[p+i]=static_cast<unsigned char>(s[i]);};
    const auto u16=[&](size_t p,std::uint16_t x){h[p]=static_cast<unsigned char>(x);h[p+1]=static_cast<unsigned char>(x>>8);};
    const auto u32=[&](size_t p,std::uint32_t x){for(unsigned i=0;i<4;++i)h[p+i]=static_cast<unsigned char>(x>>(i*8));};
    tag(0,"RIFF");u32(4,40);tag(8,"WAVE");tag(12,"fmt ");u32(16,16);u16(20,1);u16(22,2);
    u32(24,48000);u32(28,192000);u16(32,4);u16(34,16);tag(36,"data");u32(40,4);
    std::ofstream out(argv[7],std::ios::binary);out.write(reinterpret_cast<const char*>(h.data()),h.size());
    if(std::string(argv[2])=="1" || std::string(argv[2])=="4"){const char pcm[4]{};out.write(pcm,4);}
    return out.good()?0:3;
}
