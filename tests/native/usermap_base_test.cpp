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

    if (failures) { std::printf("%d failure(s)\n", failures); return 1; }
    std::printf("usermap_base_test: ok\n");
    return 0;
}
