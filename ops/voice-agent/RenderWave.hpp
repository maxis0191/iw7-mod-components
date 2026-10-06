#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
#include <stdexcept>
#include <algorithm>
#include <cmath>
namespace voice_render
{
inline std::uint16_t u16(const unsigned char* p) { return static_cast<std::uint16_t>(p[0] | p[1]<<8); }
inline std::uint32_t u32(const unsigned char* p) { return p[0] | std::uint32_t(p[1])<<8 | std::uint32_t(p[2])<<16 | std::uint32_t(p[3])<<24; }
inline std::vector<std::int16_t> parse(const std::vector<unsigned char>& bytes)
{
    if (bytes.size()<44 || bytes.size()>480102 || std::memcmp(bytes.data(),"RIFF",4) || std::memcmp(bytes.data()+8,"WAVE",4) || u32(bytes.data()+4)!=bytes.size()-8) throw std::runtime_error("Bounded exact RIFF/WAVE required");
    bool fmt=false,data=false;std::vector<std::int16_t> pcm;
    for (std::size_t i=12;i<bytes.size();)
    {
        if (bytes.size()-i<8) throw std::runtime_error("Truncated RIFF chunk");
        const auto size=u32(bytes.data()+i+4);const auto* payload=bytes.data()+i+8;
        if (size>bytes.size()-i-8) throw std::runtime_error("Chunk exceeds RIFF");
        if (!std::memcmp(bytes.data()+i,"fmt ",4))
        {
            if (fmt || (size!=16 && size!=18) || u16(payload)!=1 || u16(payload+2)!=1 || u32(payload+4)!=16000 || u32(payload+8)!=32000 || u16(payload+12)!=2 || u16(payload+14)!=16 || (size==18 && u16(payload+16))) throw std::runtime_error("Only mono PCM16 16000Hz source supported");
            fmt=true;
        }
        else if (!std::memcmp(bytes.data()+i,"data",4))
        {
            if (!fmt || data || !size || size%2 || size>480000) throw std::runtime_error("Invalid bounded source frames");
            pcm.resize(size/2);for (std::size_t j=0;j<pcm.size();++j) pcm[j]=static_cast<std::int16_t>(u16(payload+2*j));data=true;
        }
        const std::size_t next=i+8+size+(size&1u);if (next>bytes.size()) throw std::runtime_error("Chunk pad missing");i=next;
    }
    if (!fmt || !data) throw std::runtime_error("Source format/data missing");return pcm;
}
inline std::uint64_t frames(std::size_t source,unsigned rate,unsigned channels,unsigned bits,bool floating)
{
    if (!source || source>240000 || rate<8000 || rate>192000 || channels<1 || channels>2 || (floating ? bits!=32 : bits!=16)) throw std::runtime_error("Unsupported negotiated format or source bound");
    return (source*static_cast<std::uint64_t>(rate)+15999)/16000;
}
inline float sample(const std::vector<std::int16_t>& pcm,std::uint64_t frame,unsigned rate)
{
    const double pos=static_cast<double>(frame)*16000/rate;const auto i=static_cast<std::size_t>(pos);
    if (i>=pcm.size()) return 0;const auto next=std::min(i+1,pcm.size()-1);
    return static_cast<float>((pcm[i]+(pcm[next]-pcm[i])*(pos-static_cast<double>(i)))/32768.0);
}
inline void fill(unsigned char* output,unsigned count,std::uint64_t start,const std::vector<std::int16_t>& pcm,unsigned rate,unsigned channels,bool floating)
{
    for (unsigned i=0;i<count;++i) for (unsigned c=0;c<channels;++c)
    {
        const float value=sample(pcm,start+i,rate);
        if (floating) std::memcpy(output+(i*channels+c)*4,&value,4);
        else { const auto v=static_cast<std::int16_t>(std::clamp(value,-1.0f,32767.0f/32768)*32768);std::memcpy(output+(i*channels+c)*2,&v,2); }
    }
}
}
