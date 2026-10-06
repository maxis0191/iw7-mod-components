#include "RenderWave.hpp"
#include <iostream>
void require(bool c) { if (!c) throw std::runtime_error("render fixture regression"); }
std::vector<unsigned char> wave()
{
    std::vector<unsigned char> b(48);std::memcpy(b.data(),"RIFF",4);b[4]=40;std::memcpy(b.data()+8,"WAVEfmt ",8);b[16]=16;b[20]=1;b[22]=1;b[24]=0x80;b[25]=0x3e;b[28]=0;b[29]=0x7d;b[32]=2;b[34]=16;std::memcpy(b.data()+36,"data",4);b[40]=4;b[44]=0;b[45]=0x40;b[46]=0;b[47]=0xc0;return b;
}
int main()
{
    try {
        const auto pcm=voice_render::parse(wave());require(pcm.size()==2 && pcm[0]==16384 && pcm[1]==-16384);
        require(voice_render::frames(pcm.size(),48000,2,32,true)==6);
        float out[12]{};voice_render::fill(reinterpret_cast<unsigned char*>(out),6,0,pcm,48000,2,true);
        require(out[0]==.5f && out[1]==.5f && std::abs(out[2]-1.f/6)<.0001f && out[6]==-.5f);
        for (const auto offset:{0u,4u,8u,20u,22u,24u,28u,32u,34u,40u}) { auto b=wave();b[offset]^=1;bool refused=false;try {voice_render::parse(b);}catch(...){refused=true;}require(refused); }
        auto b=wave();b.pop_back();bool refused=false;try{voice_render::parse(b);}catch(...){refused=true;}require(refused);
        for (unsigned channels:{0u,3u}) {refused=false;try{voice_render::frames(2,48000,channels,32,true);}catch(...){refused=true;}require(refused);}
        refused=false;try{voice_render::frames(240001,48000,2,32,true);}catch(...){refused=true;}require(refused);
        std::cout<<"PASS render source RIFF/PCM/frame bounds and explicit mono-to-stereo linear conversion; no stream activated.\n";return 0;
    } catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
