#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include "../../src/native/owner_cheats_policy.hpp"
#include "../../src/native/owner_cheats_crypto.hpp"

using namespace owner_cheats;
std::string read(const std::filesystem::path& path)
{ std::ifstream file(path, std::ios::binary); return {std::istreambuf_iterator<char>(file), {}}; }
int main(int argc, char** argv)
{
    assert(argc == 2);
    struct mock_client { unsigned marker; char padding[127]; } clients[18]{};
    for (unsigned slot=0; slot<18; ++slot) assert(policy::client_at(clients,18,slot)==&clients[slot]);
    assert(!policy::client_at(clients,18,18));
    assert(!policy::client_at(clients,99,18));
    assert(policy::target_slot("#8",{{7,"Eight"}})==7);
    assert(policy::target_slot("#18",{{17,"Last"}})==17);
    assert(policy::target_slot("18",{{17,"Last"}})==17);
    assert(policy::target_slot("#19",{{18,"Invalid"}})==-1);
    assert(policy::target_slot("#08",{{7,"Eight"}})==-1);
    assert(!policy::client_at(clients,4,4));
    assert(!policy::client_at(clients,1,1));
    assert(!policy::client_at(clients,-1,0));
    assert(!policy::client_at<mock_client>(nullptr,4,0));
    const std::vector<std::pair<int, std::string>> roster{{0,"Owner"},{2,"^2Unknown ^7Soldier"},{3,"Unknown Friend"}};
    assert(policy::target_slot("#3",roster)==2);
    assert(policy::target_slot("3",roster)==2);
    assert(policy::target_slot("#2",roster)==-1);
    assert(policy::target_slot("#0",roster)==-1);
    assert(policy::target_slot("UNKNOWN SOLDIER",roster)==2);
    assert(policy::target_slot("Soldier",roster)==2);
    assert(policy::target_slot("unknown",roster)==-1);
    assert(policy::target_slot("#3x",roster)==-1);
    assert(policy::target_slot("",roster)==-1);
    assert(policy::target_slot("Owner",{{0,"Owner"},{1,"Owner"}})==-1);
    assert(policy::customizable_give("iw7_ar57_zm"));
    assert(policy::customizable_give("iw7_ar57_zm+reflex+xmags"));
    for (const auto* keyword : {"ammo", "allammo", "health", "all", "", "x;quit", "IW7_AR57_ZM", "iw7_ar57_zm+", "+reflex", "ar57", "iw7 ar57"})
        assert(!policy::customizable_give(keyword));
    assert(policy::safe_target("Unknown Soldier"));
    assert(!policy::safe_target("x;quit"));
    assert(!policy::safe_target("x\nquit"));
    assert(!policy::safe_target("x\"quit"));
    // Persistent moderation bans: tolerant parsing, stable round trip, lookup.
    auto bans=policy::parse_bans("123456789abcdef0\t^2Bad \"Guy\";\r\nnot-hex\tx\n123456789abcdef0\tdup\n\nabc\n00000000000000001\ttoo long\n");
    assert(bans.size()==2);
    assert(bans[0].identity=="123456789abcdef0" && bans[0].name=="^2Bad Guy");
    assert(bans[1].identity=="abc" && bans[1].name=="Unknown Soldier");
    assert(policy::parse_bans(policy::serialize_bans(bans)).size()==2);
    assert(policy::serialize_bans(bans)=="123456789abcdef0\t^2Bad Guy\nabc\tUnknown Soldier\n");
    assert(policy::banned(bans,"abc") && !policy::banned(bans,"abd") && !policy::banned(bans,""));
    assert(policy::ban_index(bans,"#1")==0 && policy::ban_index(bans,"2")==1);
    assert(policy::ban_index(bans,"123456789abcdef0")==0 && policy::ban_index(bans,"abc")==1);
    assert(policy::ban_index(bans,"#3")==-1 && policy::ban_index(bans,"0")==-1 && policy::ban_index(bans,"")==-1 && policy::ban_index(bans,"#")==-1);
    assert(policy::display_name(std::string(40,'a')).size()==31);
    assert(policy::display_name("\"\\;")=="Unknown Soldier");
    const std::filesystem::path root(argv[1]);
    crypto::key owner, owner_public, server, server_public, malformed;
    assert(owner.load(read(root/"client/iw7-mod/owner-cheats/client-private.blob"), true));
    assert(owner_public.load(read(root/"server/iw7-mod/owner-cheats/owner-public.blob"), false));
    assert(server.load(read(root/"server/iw7-mod/owner-cheats/server-private.blob"), true));
    assert(server_public.load(read(root/"client/iw7-mod/owner-cheats/trusted-server-public.blob"), false));
    assert(!malformed.load(std::string(104, 'x'), true));
    assert(!malformed.load(read(root/"client/iw7-mod/owner-cheats/client-private.blob"), false));
    const std::string c(64,'a'), s(64,'b'), id="123456789abcdef0";
    const auto challenge=policy::message('S',id,c,s), proof=policy::message('P',id,c,s);
    const auto server_signature=server.sign(challenge), owner_signature=owner.sign(proof);
    assert(server_public.verify(challenge, server_signature));
    assert(owner_public.verify(proof, owner_signature));
    assert(!owner_public.verify(proof, server.sign(proof))); // Another private key cannot impersonate the owner.
    assert(!owner_public.verify(policy::message('P',"0",c,s),owner_signature));
    assert(!owner_public.verify(policy::message('A',id,c,s),owner_signature));
    assert(!owner_public.verify(policy::message('P',id,s,c),owner_signature));
    assert(!server_public.verify(challenge,owner_signature));
    assert(owner_public.sign(proof).empty());
    assert(!owner_public.verify(proof, "short"));
    policy::proof p{c,s,10000,0,false};
    assert(!p.allowed(1));
    assert(!p.consume(c,std::string(64,'c'),1,true));
    assert(p.consume(c,s,1,owner_public.verify(proof,owner_signature)));
    assert(p.allowed(45000)); assert(!p.allowed(45001));
    assert(!p.consume(c,s,2,true)); // One-time proof, including a previously valid signature.
    policy::proof expired{c,s,10000,0,false}; assert(!expired.consume(c,s,10000,true));
    policy::proof rejected{c,s,10000,0,false}; assert(!rejected.consume(c,s,1,false));
    assert(!rejected.consume(c,s,2,true)); assert(!rejected.allowed(2));
    p={}; assert(!p.allowed(2)); // Disconnect/reconnect cannot inherit a grant.
    assert(policy::hex(policy::unhex(c,32))==c);
    assert(policy::unhex("A0",1).empty());
    assert(policy::words("H "+id+" "+c).size()==3);
    assert(policy::words("H  "+id).empty());
    assert(policy::words(std::string(513,'a')).empty());
    assert(policy::words("H x\ny").empty());
    std::cout << "Owner key, mutual server proof, impersonation, nonce, replay, expiry and malformed-input checks pass.\n";
}
