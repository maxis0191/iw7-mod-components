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

    if (failures) { std::printf("%d failure(s)\n", failures); return 1; }
    std::printf("usermap_base_test: ok\n");
    return 0;
}
