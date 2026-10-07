#pragma once
#include <charconv>
#include <cstdint>
#include <sstream>
#include <string>
#include <string_view>
namespace voice_capture_wire {
struct query {std::string nonce;std::uint64_t probe{};bool capture_version{};};
struct reply:query {std::string generation,map;bool safe{};unsigned slot{4};};
inline bool nonce(const std::string& value){return value.size()==32 && value.find_first_not_of("0123456789abcdef")==std::string::npos;}
template<class T>inline bool number(const std::string& s,T& out){const auto p=std::from_chars(s.data(),s.data()+s.size(),out);return !s.empty() && p.ec==std::errc{} && p.ptr==s.data()+s.size();}
inline bool parse_query(std::string_view wire,bool capture_server,query& result){
    if(wire.empty() || wire.size()>64)return false;
    query q;std::string first,probe,extra;std::istringstream input{std::string(wire)};
    if(!(input>>first))return false;q.capture_version=first=="capture1";
    if(q.capture_version){if(!capture_server || !(input>>q.nonce>>probe))return false;}
    else{q.nonce=first;if(!(input>>probe))return false;}
    if(input>>extra || !nonce(q.nonce) || !number(probe,q.probe) || !q.probe)return false;
    result=q;return true;
}
inline bool parse_reply(std::string_view wire,bool capture_client,std::string_view expected_nonce,reply& result){
    if(wire.empty() || wire.size()>(capture_client?180u:160u))return false;
    reply r;std::string first,probe,safe,slot,extra;std::istringstream input{std::string(wire)};
    if(!(input>>first))return false;r.capture_version=first=="capture1";
    if(r.capture_version!=capture_client)return false;
    if(capture_client){if(!(input>>r.nonce))return false;}else r.nonce=first;
    if(!(input>>probe>>r.generation>>safe>>r.map))return false;
    if(capture_client && (!(input>>slot) || !number(slot,r.slot) || r.slot>4))return false;
    if(input>>extra || r.nonce!=expected_nonce || !nonce(r.nonce) || !nonce(r.generation) || !number(probe,r.probe) ||
        (safe!="0" && safe!="1") || (capture_client && safe=="1" && r.slot>=4))return false;
    r.safe=safe=="1";result=r;return true;
}
inline std::string request(const std::string& nonce_value,std::uint64_t probe,bool capture_client){return (capture_client?"capture1 ":"")+nonce_value+" "+std::to_string(probe);}
inline std::string response(const query& q,const std::string& generation,bool safe,const std::string& map,unsigned slot){
    auto s=q.nonce+" "+std::to_string(q.probe)+" "+generation+" "+(safe?"1":"0")+" "+map;
    return q.capture_version?"capture1 "+s+" "+std::to_string(slot):s;
}
}
