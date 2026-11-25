#include <cstdio>

#include "../../src/native/usermap_base_policy.hpp"

static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

int main() {
    using usermap_base::parse_base_list;
    using usermap_base::valid_zone_name;

    CHECK(parse_base_list("").empty());
    CHECK(parse_base_list("\n\n  \r\n").empty());

    auto one = parse_base_list("cp_zmb\r\n");
    CHECK(one.size() == 1 && one[0] == "cp_zmb");

    // order kept, comments and blanks dropped, repeats dropped, last line without newline kept
    auto many = parse_base_list("// stock zones\ncp_zmb\n\n  cp_town  \t\ncp_zmb\n// cp_rave\ncp_final");
    CHECK(many.size() == 3 && many[0] == "cp_zmb" && many[1] == "cp_town" && many[2] == "cp_final");

    // byte order mark
    auto bom = parse_base_list("\xEF\xBB\xBF" "cp_zmb\n");
    CHECK(bom.size() == 1 && bom[0] == "cp_zmb");

    // names that leave the zone folder, carry an extension or are empty of letters are rejected and reported
    std::vector<std::string> rejected;
    auto bad = parse_base_list("..\\evil\ncp_zmb.ff\nC:\\x\na/b\ncp_ok\n", &rejected);
    CHECK(bad.size() == 1 && bad[0] == "cp_ok");
    CHECK(rejected.size() == 4);

    CHECK(valid_zone_name("cp_zmb") && valid_zone_name("a-b_9"));
    CHECK(!valid_zone_name("") && !valid_zone_name("a b") && !valid_zone_name(std::string(64, 'a')));

    // the option `nopatch`: after the name, blanks or a tab between; an unknown option or a second one rejects the line
    std::vector<std::string> rej2;
    auto ent = usermap_base::parse_base_entries("techsets_x\ncp_zmb nopatch\ncp_town\t nopatch  \ncp_final fast\ncp_a nopatch nopatch\ncp_zmb\n", &rej2);
    CHECK(ent.size() == 3);
    CHECK(ent[0].name == "techsets_x" && !ent[0].no_patch);
    CHECK(ent[1].name == "cp_zmb" && ent[1].no_patch);
    CHECK(ent[2].name == "cp_town" && ent[2].no_patch);
    CHECK(rej2.size() == 2);
    // a repeat keeps the option on
    auto rep = usermap_base::parse_base_entries("cp_zmb\ncp_zmb nopatch\n");
    CHECK(rep.size() == 1 && rep[0].no_patch);
    // the names-only parser still drops the options
    auto names = parse_base_list("cp_zmb nopatch\ncp_town\n");
    CHECK(names.size() == 2 && names[0] == "cp_zmb" && names[1] == "cp_town");
    // the engine's own order for the zones it adds: techsets_ before cache_
    auto comp = usermap_base::companion_zones("cp_zmb");
    CHECK(comp.size() == 2 && comp[0] == "techsets_cp_zmb" && comp[1] == "cache_cp_zmb");

    // the option `resident` (loaded once per game process), alone or with `nopatch`, in either order; a repeated or unknown option rejects the line
    std::vector<std::string> rej3;
    auto res = usermap_base::parse_base_entries("cp_zmb resident\ncp_town nopatch resident\ncp_final resident\tnopatch\ncp_a resident resident\ncp_b resident fast\ncp_c nopatch nopatch\n", &rej3);
    CHECK(res.size() == 3);
    CHECK(res[0].name == "cp_zmb" && res[0].resident && !res[0].no_patch);
    CHECK(res[1].name == "cp_town" && res[1].resident && res[1].no_patch);
    CHECK(res[2].name == "cp_final" && res[2].resident && res[2].no_patch);
    CHECK(rej3.size() == 3);
    // a line with no option is not resident, and a repeat of a name turns the option on for the first one
    auto plain = usermap_base::parse_base_entries("cp_zmb\ncp_zmb resident\n");
    CHECK(plain.size() == 1 && plain[0].resident && !plain[0].no_patch);
    CHECK(!usermap_base::parse_base_entries("cp_zmb\n")[0].resident);
    // the flags of one load: the level's flags, the custom bit when asked, the permanent flag alone when asked
    const unsigned int custom_bit = 0x1000000u;
    usermap_base::load_mode none, custom, perm, both;
    custom.custom = true;
    perm.permanent = true;
    both.custom = true;
    both.permanent = true;
    CHECK(usermap_base::load_flags(0x80u, none, custom_bit) == 0x80u);
    CHECK(usermap_base::load_flags(0x80u, custom, custom_bit) == (0x80u | custom_bit));
    CHECK(usermap_base::load_flags(0x80u, perm, custom_bit) == 0x1u);                       // the level's bits are not kept: nothing for an unload to match
    CHECK(usermap_base::load_flags(0x80u, both, custom_bit) == (0x1u | custom_bit));
    // zone names are the same zone ignoring ASCII case; the engine's table has 373 slots
    CHECK(usermap_base::same_zone_name("cp_zmb", "CP_ZMB") && usermap_base::same_zone_name("techsets_cp_zmb", "techsets_cp_zmb"));
    CHECK(!usermap_base::same_zone_name("cp_zmb", "cp_zmb2") && !usermap_base::same_zone_name("cp_zmb2", "cp_zmb") && !usermap_base::same_zone_name("cp_zmb", ""));
    CHECK(!usermap_base::same_zone_name(nullptr, "cp_zmb") && !usermap_base::same_zone_name("cp_zmb", nullptr) && usermap_base::same_zone_name("", ""));
    int slots = usermap_base::zone_slots;
    CHECK(slots == 373);

    // a usermap's own patch zone: patch_<map>[.ff] resolves into the map's folder, nothing else does
    CHECK(usermap_base::patch_zone_path("patch_cp_iwz") == "usermaps\\cp_iwz\\patch_cp_iwz.ff");
    CHECK(usermap_base::patch_zone_path("patch_cp_iwz.ff") == "usermaps\\cp_iwz\\patch_cp_iwz.ff");
    CHECK(usermap_base::patch_zone_path("patch_cp_zmb").size() > 0);          // the name alone decides; the file must exist in the map's folder (the caller checks)
    CHECK(usermap_base::patch_zone_path("cp_iwz.ff").empty());
    CHECK(usermap_base::patch_zone_path("patch_").empty());
    CHECK(usermap_base::patch_zone_path("patch_.ff").empty());
    CHECK(usermap_base::patch_zone_path("techsets_cp_iwz").empty());
    CHECK(usermap_base::patch_zone_path("patch_..\\evil").empty());
    CHECK(usermap_base::patch_zone_path("patch_a/b.ff").empty());
    CHECK(usermap_base::patch_zone_path("").empty());

    if (failures) { std::printf("%d failure(s)\n", failures); return 1; }
    // F8: the base's own hint lists, and nothing else
    {
        const std::vector<std::string> bases = { "cp_zmb" };
        using usermap_base::is_base_hint_list;
        CHECK(is_base_hint_list("ncs_hnt_eng_cp_zmb", bases));
        CHECK(is_base_hint_list("ncs_hnt_eng_patch_cp_zmb", bases));
        CHECK(is_base_hint_list("ncs_hnt_fre_cp_zmb", bases));
        CHECK(!is_base_hint_list("ncs_hnt_level", bases));
        CHECK(!is_base_hint_list("ncs_hnt_eng_code_post_gfx", bases));
        CHECK(!is_base_hint_list("ncs_hnt_common_mp", bases));
        CHECK(!is_base_hint_list("ncs_loc_eng_cp_zmb", bases));
        CHECK(!is_base_hint_list("ncs_hnt_eng_cp_zmb2", bases));
        CHECK(!is_base_hint_list("ncs_hnt_eng_", bases));
        CHECK(!is_base_hint_list("ncs_hnt__cp_zmb", bases));
        CHECK(!is_base_hint_list("ncs_hnt_eng_cp_zmb", {}));
        CHECK(!is_base_hint_list(nullptr, bases));
        CHECK(is_base_hint_list("ncs_hnt_eng_patch_cp_town", { "cp_zmb", "cp_town" }));
    }

    // F9: map wins = the base loads after the map, as an ordinary level zone
    {
        using usermap_base::base_phase;
        CHECK(usermap_base::loads_in_phase(true, base_phase::after));
        CHECK(!usermap_base::loads_in_phase(true, base_phase::before));
        CHECK(usermap_base::loads_in_phase(false, base_phase::before));
        CHECK(!usermap_base::loads_in_phase(false, base_phase::after));
        usermap_base::load_mode resident;
        resident.permanent = true;
        resident.custom = true;
        const auto won = usermap_base::map_wins_mode(resident);
        CHECK(!won.permanent && won.custom);
        CHECK(usermap_base::is_map_own_zone("cp_iwz", "cp_iwz"));
        CHECK(usermap_base::is_map_own_zone("patch_cp_iwz", "cp_iwz"));
        CHECK(usermap_base::is_map_own_zone("PATCH_CP_IWZ", "cp_iwz"));
        CHECK(!usermap_base::is_map_own_zone("cp_zmb", "cp_iwz"));
        CHECK(!usermap_base::is_map_own_zone("patch_cp_zmb", "cp_iwz"));
        CHECK(!usermap_base::is_map_own_zone("techsets_cp_iwz", "cp_iwz"));
        CHECK(!usermap_base::is_map_own_zone(nullptr, "cp_iwz"));
        CHECK(!usermap_base::is_map_own_zone("cp_iwz", ""));
    }

    std::printf("usermap_base_test: ok\n");
    return 0;
}
