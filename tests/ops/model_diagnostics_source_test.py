"""Source/serialized-log checks only; never compile or run the native observer."""
import ast
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src/native/paris_model_diagnostics.cpp").read_text(encoding="utf-8")
STRINGS = [ast.literal_eval(value) for value in re.findall(r'"(?:[^"\\]|\\.)*"', SOURCE)]
FORMATS = [value for value in STRINGS if value.startswith("[Paris model provenance]")]
SPEC = re.compile(r"%(?:016llx|llu|lu|u|s)")


def render(fmt, values):
    """Render the real source format with synthetic scalars, not native behavior."""
    values = iter(values)
    def replace(match):
        value = next(values)
        return f"{value:016x}" if match[0] == "%016llx" else str(value)
    result = SPEC.sub(replace, fmt)
    if next(values, None) is not None:
        raise AssertionError("extra synthetic format value")
    return result


class ModelDiagnosticsSourceTests(unittest.TestCase):
    def test_existing_surface_and_session_formats_are_unchanged(self):
        self.assertIn("[Paris model diagnostic] surface=%s readable=1 flags=%u vertices=%u triangles=%u rigid=%u cpu_vertices=%d cpu_indices=%d vb=%d vb_view=%d ib=%d ib_view=%d\n", STRINGS)
        self.assertIn("[Paris model diagnostic] pid=%lu nonce=%s generation=%s tick_ms=%llu protected=1 once_per_connection=1\n", STRINGS)
        self.assertEqual(sum(s.startswith("[Paris model diagnostic]") for s in STRINGS), 13)

    def test_original_gate_and_once_per_connection_precede_observation(self):
        start = SOURCE.index("if (game::environment::is_dedi()", SOURCE.index("void observe_client"))
        gate = SOURCE[start:SOURCE.index("const auto observation_tid = GetCurrentThreadId()", start)]
        for check in (
            'utils::flags::has_flag("paris-server-client-test")',
            'utils::flags::has_flag("paris-isolated-lab")',
            '!protected_now || !probe_tick || now < probe_tick || now - probe_tick > 500',
            'iw7::agent::nonce_valid(client_nonce)', 'iw7::agent::nonce_valid(server_generation)',
            'connection_challenge.empty()', 'exact_string_dvar("fs_game", "mods/paris_model_probe")',
            'game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP',
            '!game::CL_IsGameClientActive(0)', '!game::clientUIActives[0].cgameInitialized',
            'game::clientUIActives[0].connectionState != game::CA_ACTIVE',
            'observed_nonce == client_nonce && observed_generation == server_generation && observed_challenge == connection_challenge',
        ):
            self.assertIn(check, gate)
        self.assertLess(SOURCE.index(gate), SOURCE.index("const auto observation_tid = GetCurrentThreadId()"))
        self.assertIn("observation_sequence == std::numeric_limits<std::uint64_t>::max()", SOURCE)

    def test_new_record_uses_only_existing_copies_and_one_fixed_asset(self):
        body = SOURCE[SOURCE.index("void provenance("):SOURCE.index("        bool readable(")]
        for forbidden in ("snapshot(", "readable(", "DB_", "VirtualQuery", "GetDesc", "QueryInterface", "memcpy", "->"):
            self.assertNotIn(forbidden, body)
        self.assertIn('std::strcmp(key, "paris_model_probe") == 0', SOURCE)
        self.assertIn('selected ? &context : nullptr', SOURCE)
        self.assertIn('provenance(*context, pointer, &data)', SOURCE)
        self.assertEqual(SOURCE.count("name(mesh.name)"), 1)
        legacy = SOURCE[SOURCE.index("void surface("):SOURCE.index("void observe_client(")]
        self.assertEqual(legacy.count("snapshot(pointer, data)"), 1)
        self.assertEqual(legacy.count("game::DB_FindXAssetHeader("), 3)
        self.assertEqual(legacy.count("game::DB_IsXAssetDefault("), 3)
        self.assertNotRegex(body, r"\b(?:for|while)\s*\(")

    def test_invalid_provenance_is_refused_before_serializing_fields(self):
        body = SOURCE[SOURCE.index("void provenance("):SOURCE.index("        bool readable(")]
        for reason in ("default_model", "lod_missing", "mesh_unreadable", "mesh_name_mismatch",
                       "surface_count", "surface_relation", "surface_unreadable"):
            self.assertIn(f'"{reason}"', body)
        self.assertIn("pointer != mesh.surfs", body)
        self.assertIn("mesh.numsurfs != 1", body)
        self.assertIn("s % alignof(game::XSurface)", body)
        self.assertIn("max() - sizeof(game::XSurface)", body)
        self.assertLess(body.index("if (refused)"), body.index("const auto& data = *copied_surface"))
        self.assertIn("return;", body[body.index("if (refused)"):body.index("const auto& data")])

    def test_source_offsets_are_asserted_not_runtime_claims(self):
        for field, offset in (("blendVertSize", "0x18"), ("verts0", "0x20"),
                              ("rigidVertLists", "0x48"), ("blendVerts", "0x50"),
                              ("blendVertsBuffer", "0x58"), ("blendVertsView", "0x60")):
            self.assertIn(f"static_assert(offsetof(game::XSurface, {field}) == {offset});", SOURCE)
        self.assertEqual(len(FORMATS), 3)
        for fmt in FORMATS:
            for field in ("H_invocation_verified", "allocation_identity_verified",
                          "observation_tid_is_loader_tid", "atomic_snapshot_verified", "gpu_resource_verified"):
                self.assertIn(f"{field}=false", fmt)

    def test_real_success_format_keeps_distinct_addresses_and_bounded_scalars(self):
        fmt = next(s for s in FORMATS if "status=sampled" in s)
        values = [7, 123, 456, "a" * 32, "b" * 32, 0x10000, 0x20000, 0x30000, 1,
                  0x30000, 0x30058, 4, 8, 12, 1, 16, 0x40000, 0x50000, 0x60000, 0x70000, 0x80000]
        text = render(fmt, values)
        fields = dict(re.findall(r"(\w+)=([^\s]+)", text))
        self.assertEqual(fields["mesh_name"], "paris_model_probe_lod0")
        self.assertEqual(fields["observation_tid"], "123")
        self.assertEqual(fields["index"], "0")
        self.assertEqual(int(fields["S"], 16), int(fields["base"], 16))
        self.assertEqual(int(fields["P"], 16) - int(fields["S"], 16), 0x58)
        for field, expected in (("verts_20", 0x40000), ("rigid_48", 0x50000), ("blend_50", 0x60000),
                                ("buffer_58", 0x70000), ("view_60", 0x80000)):
            self.assertEqual(int(fields[field], 16), expected)
        maximum = ["f" * 32 if spec == "%s" else (2 ** 64 - 1) for spec in SPEC.findall(fmt)]
        self.assertLessEqual(len(render(fmt, maximum).encode("ascii")), 1536)
        self.assertEqual(text.count("\n"), 1)

    def test_success_printf_arguments_match_serialized_field_names(self):
        start = SOURCE.rfind("console::info(", 0, SOURCE.index("status=sampled")) + len("console::info(")
        depth, quoted, escaped, part, args = 1, False, False, start, []
        for index in range(start, len(SOURCE)):
            char = SOURCE[index]
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if not depth:
                    args.append(SOURCE[part:index].strip())
                    break
            elif char == "," and depth == 1:
                args.append(SOURCE[part:index].strip())
                part = index + 1
        fmt = ast.literal_eval(args.pop(0))
        fields = re.findall(r"(\w+)=(?:0x)?%(?:016llx|llu|lu|u|s)", fmt)
        self.assertEqual(len(fields), len(args))
        actual = dict(zip(fields, args))
        self.assertEqual(actual["observation_tid"], "context.observation_tid")
        for field, argument in (("mesh", "context.mesh"), ("mesh_name_address", "mesh.name"),
                                ("base", "mesh.surfs"), ("S", "pointer"), ("verts_20", "data.verts0.verts0"),
                                ("rigid_48", "data.rigidVertLists"), ("blend_50", "data.blendVerts"),
                                ("buffer_58", "data.blendVertsBuffer"), ("view_60", "data.blendVertsView")):
            self.assertEqual(actual[field], f"address_value({argument})")
        self.assertEqual(actual["blend_size_18"], "data.blendVertSize")
        self.assertEqual(actual["P"], "static_cast<unsigned long long>(s + offsetof(game::XSurface, blendVertsBuffer))")

    def test_existing_log_consumer_does_not_promote_provenance_to_acceptance(self):
        spec = importlib.util.spec_from_file_location("model_diagnostic_debugger", ROOT / "ops/iw7_debugger.py")
        debugger = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(debugger)
        rows = []
        for fmt in FORMATS:
            values = ["surface_unreadable" if item == "%s" else 1 for item in SPEC.findall(fmt)]
            rows.append(render(fmt, values))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "synthetic.log"
            path.write_text("".join(rows), encoding="utf-8")
            result = debugger.log_events(path)
        self.assertEqual(result["lines"], 3)
        self.assertEqual(result["events"], [])
        self.assertNotIn("ready", result)


class SceneBoundarySourceTests(unittest.TestCase):
    def test_renderer_cannot_call_main_engine_or_publish(self):
        body = SOURCE[SOURCE.index("void renderer_scene("):SOURCE.index("bool request_scene(")]
        for forbidden in ("console::", "DB_", "client_protection(", "Dvar_", "Com_", "CL_",
                          "environment::", "sceneDObj[", "entry.obj->", "GetDesc", "QueryInterface"):
            self.assertNotIn(forbidden, body)
        copy = body[body.index("const auto copy ="):body.index("// The scene symbol")]
        self.assertLess(copy.index("scene_admitted("), copy.index("readable(source"))
        self.assertLess(copy.index("bytes > budget"), copy.index("copy_leaf("))

    def test_output_preserves_unknowns_and_privacy(self):
        formats = [s for s in STRINGS if s.startswith("[Paris rig scene snapshot]")]
        self.assertEqual(len(formats), 5)
        for fmt in formats:
            for private in ("pid=", "nonce=", "generation=", "challenge=", "0x", "%p"):
                self.assertNotIn(private, fmt)
        header = next(s for s in formats if "count_before=" in s)
        for unknown in ("atomic_snapshot_verified=0", "entity_replication=unmeasured", "entity_dobj=unmeasured",
                        "gpu_resource_verified=0", "draw_verified=0", "table=sceneModel"):
            self.assertIn(unknown, header)
        self.assertIn('publish ? "SceneModelTableObserved" : "NoSceneObservation"', SOURCE)
        self.assertIn('publish && stock_enabled ? static_cast<int>(result.matches[2]) : -1', SOURCE)
        self.assertNotIn('"NoEntity"', SOURCE)
        self.assertTrue(any("absence_scope=not_observed_in_this_scene_model_table" in s for s in formats))

    def test_stock_lookup_is_closed_and_separate(self):
        body = SOURCE[SOURCE.index("bool request_scene("):SOURCE.index("void surface(")]
        self.assertIn('has_flag("paris-rig-scene-stock-witness") ? 3 : 2', body)
        self.assertIn('exact_name(model.name, scene_keys[i]) != 1', body)
        self.assertIn('!= default_status::nondefault', body)
        keys = re.search(r'constexpr const char\* scene_keys\[\]\{([^}]+)\}', SOURCE)[1]
        self.assertEqual(re.findall(r'"([^"]+)"', keys),
                         ["paris_doom_skin_two_bone_first_a", "paris_doom_skin_two_bone_second_a", "zmb_coin_alien"])

    def test_capture_follows_arm_and_teardown_avoids_engine(self):
        fixture = (ROOT / "src/native/paris_test_fixture.cpp").read_text(encoding="utf-8")
        action = fixture[fixture.index('if (action == "capture")'):fixture.index('else if (vote_input)')]
        self.assertIn("observe_scene_capture(agent_runtime.client && agent_runtime.client->active(), rig_scene_arm", action)
        self.assertNotIn("active() && rig_scene_arm", action)
        self.assertIn("rig_scene_arm = request.sequence", fixture)
        cancellation = SOURCE[SOURCE.index("// Teardown cancellation"):SOURCE.index("try { maintain_scene(")]
        for forbidden in ("game::", "console::", "client_protection("):
            self.assertNotIn(forbidden, cancellation)


class SceneAdmissionSourceTests(unittest.TestCase):
    def test_one_admission_record_has_clock_domain_and_no_private_identity(self):
        formats = [s for s in STRINGS if s.startswith("[Paris rig scene admission]")]
        self.assertEqual(len(formats), 1)
        fmt = formats[0]
        for field in ("capture_request_id=", "observation_id=", "scene_arm=", "status=", "reason=",
                      "input_query_tick_ms=", "query_tick_ms=", "capture_tick_ms=", "checked_tick_ms=",
                      "query_age_ms=", "age_measured=", "flags_mask=", "mode=", "active_arm="):
            self.assertIn(field, fmt)
        for private in ("nonce=", "generation=", "challenge=", "%p", "0x"):
            self.assertNotIn(private, fmt)
        body = SOURCE[SOURCE.index("void report_capture("):SOURCE.index("struct provenance_context")]
        self.assertLess(body.index("if (value.reported) return"), body.index("console::info"))
        self.assertLess(body.index("value.reported = true"), body.index("console::info"))

    def test_refusal_cannot_schedule_retry_or_claim_renderer_publication(self):
        body = SOURCE[SOURCE.index("void observe_scene_capture("):SOURCE.index("void observe_client(")]
        for forbidden in ("sleep", "scheduler::", "renderer_scene(", "SceneModelTableObserved", "draw_verified=1"):
            self.assertNotIn(forbidden, body)
        self.assertIn('report_capture(admission, admitted ? "admitted" : "refused"', body)
        self.assertIn('"observer_exception"', body)
        self.assertIn("state->pending = false", body)
        request = SOURCE[SOURCE.index("bool request_scene("):SOURCE.index("void surface(")]
        self.assertIn("scene_query_refusal(current.query_tick, now, 250)", request)
        self.assertIn("state->requested_tick + 1000", request)
        self.assertIn("current.query_tick + 250", request)
        self.assertEqual(request.count("scheduler::once("), 1)
        self.assertIn('return refuse("request_pending")', request)
        self.assertIn('return refuse("arm_consumed")', request)


if __name__ == "__main__":
    unittest.main()
