"""Host-scaffold tests; no native LEX5 adapter or benchmark is exercised."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import replace
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from bench4.oracle import FIXTURE_NAMES, Operation, Oracle, expected, make_fixture
from bench5.contracts import (
    comparison_entrypoints,
    coverage_contract,
    has_releasefast_before_each_module,
    protocol_contract,
    releasefast_module_command,
)
from bench5.host import ReadinessError, _file_record, build_readiness, control_artifact_ledger, external_profile_snapshot, fixture_matrix
from bench5.lowering import (
    LoweringError,
    NeutralRef,
    SENSE_ENTRY_PREDICATE,
    lower_fixture_json,
    validate_neutral,
)
from bench5.native import _native_result


class ContractTests(unittest.TestCase):
    def test_releasefast_is_attached_to_each_module(self):
        command = releasefast_module_command(
            root_source="root.zig",
            library_source="src5/root.zig",
            output="lex5-bench",
        )
        self.assertTrue(has_releasefast_before_each_module(command))
        broken = list(command)
        first_mode = broken.index("-O")
        del broken[first_mode : first_mode + 2]
        self.assertFalse(has_releasefast_before_each_module(broken))

    def test_protocol_has_no_expected_answers_or_schedule_input(self):
        contract = protocol_contract()
        server = contract["server_contract"]
        self.assertEqual("LEX5-BENCH/1", contract["protocol"])
        self.assertIn("expected", server["request_forbidden"])
        self.assertIn("query_schedule", server["request_forbidden"])
        self.assertIn("sample", server["request_required"])
        self.assertEqual("LEX5", contract["identity"]["candidate_label"])
        self.assertEqual("immutable accepted LEX4", contract["identity"]["control_label"])
        surface = coverage_contract()["src5_public_surface_pending"]
        self.assertEqual("lookup(prefix)", surface["dependent_query"][0])
        self.assertEqual("source.bindings(kind, attached)", surface["binding_projection"]["attached"])
        self.assertEqual("source.bindings(kind, within)", surface["binding_projection"]["within"])
        self.assertIn("uniqueRecords", surface["binding_projection"]["deduplication"])

    def test_ready_reports_materialized_relation_scratch(self):
        ready = protocol_contract()["server_contract"]["ready_event"]
        self.assertIn("scratch_relation_text", ready)
        self.assertIn("materialized relation text bytes", ready["scratch_relation_text"])

    def test_comparison_commands_are_nix_wrapped_and_unrun(self):
        value = comparison_entrypoints("/workspace")
        self.assertEqual("entrypoints_documented_not_run", value["status"])
        for name in ("source2", "external", "accepted_lex4_control"):
            self.assertEqual(["nix", "develop", ".#", "--command"], value[name]["command"][:4])

    def test_prefix_enumerate_bounds_must_come_from_native_response(self):
        fixture = make_fixture("flat", 16)
        oracle = Oracle(fixture)
        operation = Operation("prefix_enumerate", key="", sample=0)
        expected_value = expected(oracle, operation)
        native_value = _native_result(
            operation,
            {
                "ids": expected_value["ids"],
                "lo": 999,
                "hi": 1000,
                "cardinality": expected_value["cardinality"],
            },
        )
        self.assertEqual(999, native_value["lo"])
        self.assertEqual(1000, native_value["hi"])
        self.assertNotEqual(expected_value, native_value)


class HostReadinessTests(unittest.TestCase):
    def test_fixture_matrix_reuses_all_five_oracle_fixtures_and_expected_answers(self):
        matrix = fixture_matrix(records=16, repetitions=40)
        self.assertEqual(
            ["flat", "repeated", "prose_heavy", "pathological_prefix", "rich"],
            [row["fixture"] for row in matrix["fixtures"]],
        )
        for row in matrix["fixtures"]:
            self.assertEqual(40, row["operation_count"])
            self.assertTrue(row["expected_answer_digest"])
            self.assertFalse(row["schedule_retained"])
            self.assertIn("exact", row["operation_counts"])
            self.assertIn("render", row["operation_counts"])
        self.assertIn("expected-answer", matrix["expected_answers"])

    def test_accepted_control_artifact_ledger_is_complete_and_immutable(self):
        ledger = control_artifact_ledger()
        self.assertEqual("verified_read_only", ledger["status"])
        self.assertEqual(5, len(ledger["artifacts"]))
        self.assertEqual(270184, ledger["total_bytes"])
        self.assertEqual(
            [64848, 36104, 35240, 59080, 74912],
            [row["bytes"] for row in ledger["artifacts"]],
        )
        self.assertTrue(all(len(row["sha256"]) == 64 for row in ledger["artifacts"]))

    def test_readiness_is_explicitly_not_a_benchmark_result(self):
        value = build_readiness(records=8, repetitions=32)
        self.assertIn(value["status"], {"ready_for_native_correctness", "candidate_correctness_passed_root_review_pending"})
        self.assertEqual("not_run", value["measurement_status"]["status"])
        self.assertFalse(value["measurement_status"]["fake_results_emitted"])
        self.assertEqual("shape_recorded_not_executed", value["build_contract"]["status"])
        self.assertTrue(value["build_contract"]["releasefast_before_each_module"])
        self.assertIn("LEX5 artifacts" if value["native_correctness"].get("missing") is not True else "none produced", value["artifact_policy"]["candidate_artifacts"])
        self.assertEqual("experiments/frontier/lex5-20260909/benchmark/semantic-mapping-ledger.md", value["semantic_mapping_ledger"]["path"])
        self.assertEqual(64, len(value["semantic_mapping_ledger"]["sha256"]))
        self.assertEqual("experiments/frontier/lex5-20260909/benchmark/input-lowering-contract.md", value["input_lowering_contract"]["path"])
        self.assertEqual(64, len(value["input_lowering_contract"]["sha256"]))

    def test_file_record_rejects_hostile_symlink_path(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            real_dir = root / "real"
            real_dir.mkdir()
            payload = real_dir / "payload.txt"
            payload.write_text("controlled\n", encoding="utf-8")

            parent_link = root / "parent-link"
            parent_link.symlink_to(real_dir, target_is_directory=True)
            with self.assertRaises(ReadinessError):
                _file_record(parent_link / "payload.txt")

            file_link = root / "file-link"
            file_link.symlink_to(payload)
            with self.assertRaises(ReadinessError):
                _file_record(file_link)

    def test_external_factory_is_discovered_without_building_or_querying(self):
        value = external_profile_snapshot()
        labels = {row["label"] for row in value["flat_profiles"]}
        self.assertIn("stardict/adapter", labels)
        self.assertIn("dict-index/adapter", labels)
        self.assertIn("slob/adapter", labels)
        self.assertIn("slob/adapter-lzma2", labels)
        self.assertIn("rich comparisons", value["rich_profile_rule"])

    def test_pure_lowering_retains_all_five_fixture_fields_without_source_nodes(self):
        for name in FIXTURE_NAMES:
            lowered = lower_fixture_json(make_fixture(name, 16).canonical())
            self.assertEqual(name, lowered.fixture)
            self.assertFalse(lowered.documents)
            self.assertFalse(lowered.bindings)
            self.assertTrue(any(value.kind == "product" for value in lowered.values))
            self.assertTrue(all(key.entry_external_id == lowered.records[key.entry_ordinal].external_id for key in lowered.keys))
            if name != "rich":
                self.assertFalse(lowered.facts)
            else:
                self.assertIn(SENSE_ENTRY_PREDICATE, {fact.predicate for fact in lowered.facts})
                self.assertEqual(1, lowered.predicates.count(SENSE_ENTRY_PREDICATE))
                self.assertIn("membership", {fact.kind for fact in lowered.facts})

    def test_lowering_rejects_independent_hostile_mutations(self):
        original = make_fixture("rich", 16).canonical()

        unknown_field = deepcopy(original)
        unknown_field["unlowered"] = True
        with self.assertRaises(LoweringError):
            lower_fixture_json(unknown_field)

        wrong_schema = deepcopy(original)
        wrong_schema["schema"] = 2
        with self.assertRaises(LoweringError):
            lower_fixture_json(wrong_schema)

        outside_i64 = deepcopy(original)
        outside_i64["entries"][0]["id"] = 1 << 64
        with self.assertRaises(LoweringError):
            lower_fixture_json(outside_i64)

        missing_concept = deepcopy(original)
        missing_concept["senses"][0]["concept"] = 999999999
        missing_concept["entries"][0]["concepts"] = [999999999]
        with self.assertRaises(LoweringError):
            lower_fixture_json(missing_concept)

        lowered = lower_fixture_json(original)
        product = next(item for item in lowered.values if item.kind == "product")
        product_fields = list(product.payload)
        product_fields[0] = (product_fields[0][0], len(lowered.values) + 100)
        bad_product = replace(product, payload=tuple(product_fields))
        bad_values = list(lowered.values)
        bad_values[product.value_id] = bad_product

        boolean_value = next(item for item in lowered.values if item.kind == "boolean")
        bad_boolean_values = list(lowered.values)
        bad_boolean_values[boolean_value.value_id] = replace(boolean_value, payload="not-a-boolean")

        first_record = next(record for record in lowered.records if record.kind == "entry")
        bad_features = replace(first_record, features_value=len(lowered.values) + 1)
        bad_feature_records = list(lowered.records)
        bad_feature_records[first_record.ordinal] = bad_features

        relation = next(fact for fact in lowered.facts if fact.origin == "legacy.relation")
        bad_properties = replace(relation, properties_value=len(lowered.values) + 2)
        bad_property_facts = list(lowered.facts)
        bad_property_facts[relation.ordinal] = bad_properties

        missing_predicate = replace(
            lowered,
            predicates=tuple(predicate for predicate in lowered.predicates if predicate != SENSE_ENTRY_PREDICATE),
        )

        membership = next(fact for fact in lowered.facts if fact.kind == "membership")
        entry = next(record for record in lowered.records if record.kind == "entry")
        wrong_membership = replace(
            membership,
            object=NeutralRef("entry", entry.ordinal, entry.external_id, entry.book_kind_namespace),
        )
        bad_membership_facts = list(lowered.facts)
        bad_membership_facts[membership.ordinal] = wrong_membership

        malformed_fact = replace(membership, kind="unknown")
        bad_kind_facts = list(lowered.facts)
        bad_kind_facts[membership.ordinal] = malformed_fact

        mutations = {
            "value-id-contiguity": replace(
                lowered,
                values=(replace(lowered.values[0], value_id=99),) + lowered.values[1:],
            ),
            "product-member-bound": replace(lowered, values=tuple(bad_values)),
            "atom-payload-type": replace(lowered, values=tuple(bad_boolean_values)),
            "feature-value-bound": replace(lowered, records=tuple(bad_feature_records)),
            "property-value-bound": replace(lowered, facts=tuple(bad_property_facts)),
            "dropped-key-row": replace(lowered, keys=lowered.keys[:-1]),
            "predicate-catalogue": missing_predicate,
            "membership-endpoints": replace(lowered, facts=tuple(bad_membership_facts)),
            "fact-kind": replace(lowered, facts=tuple(bad_kind_facts)),
        }
        for name, mutation in mutations.items():
            with self.subTest(mutation=name):
                with self.assertRaises(LoweringError):
                    validate_neutral(mutation)


if __name__ == "__main__":
    unittest.main()
