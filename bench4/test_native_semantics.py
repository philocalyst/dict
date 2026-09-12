"""Native semantic ownership probes for the bench4 compiler/reader.

The probe deliberately does not use ``oracle.py`` to calculate answers.  It
feeds a small, independently written semantic document to the native build,
deletes both source projections before opening the artifact, and checks the
reopened answers directly.  Set ``LEX4_BENCH_EXECUTABLE`` (or
``LEX4_NATIVE_EXECUTABLE``) to run the integration test; source-only test
runs skip it when the root executable is unavailable.
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

try:
    from .adapter import AdapterError, SubprocessAdapter
    from .oracle import Entry, Fixture
except ImportError:  # direct ``python bench4/test_native_semantics.py``
    from adapter import AdapterError, SubprocessAdapter
    from oracle import Entry, Fixture


SEED = 0x4C45583400040001
FIXTURE = "ownership-probe"


def _semantic(*, relations: bool = True) -> dict[str, object]:
    # IDs intentionally include zero, a negative value, and large sparse
    # values.  None of them may be interpreted as a rank sentinel.
    entries = [
        {"id": 0, "key": "alpha", "definition_hex": b"zero entry definition".hex()},
        {"id": -11, "key": "delta", "definition_hex": b"negative entry definition".hex()},
        {"id": 41, "key": "alpha", "definition_hex": b"homograph entry definition".hex()},
        {"id": 9001, "key": "omega", "definition_hex": b"sparse entry definition".hex()},
    ]
    senses = [
        {"id": -7, "entry": -11, "language": "en", "concept": 0},
        {"id": 0, "entry": 0, "language": "fr", "concept": 0},
        {"id": 100003, "entry": 41, "language": "de", "concept": -7},
        {"id": 5000009, "entry": 9001, "language": "ja", "concept": 9001},
    ]
    concepts = [
        {"id": 0, "label": "zero concept", "members": [-7, 0]},
        {"id": -7, "label": "negative concept", "members": [100003]},
        {"id": 9001, "label": "sparse concept", "members": [5000009]},
    ]
    rows = [
        {"source": -7, "predicate": "translation", "target": 0, "asserted_by": "0", "certainty": "candidate"},
        {"source": 0, "predicate": "near_synonym", "target": 100003, "asserted_by": "-5", "certainty": "disputed"},
        {"source": 100003, "predicate": "hypernym", "target": -7, "asserted_by": "9001", "certainty": "certain"},
        {"source": 5000009, "predicate": "see_also", "target": -7, "asserted_by": "source-sparse", "certainty": "asserted"},
    ]
    return {
        "schema": 1,
        "fixture": FIXTURE,
        "seed": SEED,
        "entries": entries,
        "senses": senses,
        "concepts": concepts,
        "relations": rows if relations else [],
        "metadata": {"purpose": "native ownership probe"},
    }


def _write_sources(root: Path, semantic: dict[str, object]) -> tuple[Path, Path]:
    semantic_path = root / "semantic.json"
    corpus_path = root / "projection.tsv"
    semantic_path.write_text(json.dumps(semantic, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    lines = [
        f"# fixture={FIXTURE}\n",
        f"# seed={SEED:016x}\n",
    ]
    for entry in semantic["entries"]:  # type: ignore[index]
        definition = bytes.fromhex(entry["definition_hex"]).decode("utf-8")  # type: ignore[index]
        lines.append(f"{entry['id']}\t{entry['key']}\t{definition}\n")  # type: ignore[index]
    corpus_path.write_text("".join(lines), encoding="utf-8")
    return semantic_path, corpus_path


class NativeOwnershipTests(unittest.TestCase):
    def _executable(self) -> Path:
        raw = os.environ.get("LEX4_BENCH_EXECUTABLE") or os.environ.get("LEX4_NATIVE_EXECUTABLE")
        if not raw:
            self.skipTest("set LEX4_BENCH_EXECUTABLE to run native ownership integration")
        executable = Path(raw).expanduser().resolve()
        if not executable.is_file():
            self.skipTest(f"native executable is unavailable: {executable}")
        return executable

    @staticmethod
    def _fixture(semantic: dict[str, object]) -> Fixture:
        entries = tuple(
            Entry(int(row["id"]), str(row["key"]), bytes.fromhex(str(row["definition_hex"])))
            for row in semantic["entries"]  # type: ignore[index]
        )
        return Fixture(FIXTURE, entries)

    def _run_variant(self, executable: Path, semantic: dict[str, object]) -> dict[str, object]:
        with tempfile.TemporaryDirectory(prefix="lex4-native-ownership-") as name:
            root = Path(name)
            semantic_path, corpus_path = _write_sources(root, semantic)
            artifact = root / "artifact.lex4"
            adapter = SubprocessAdapter(
                self._fixture(semantic),
                [str(executable)],
                corpus=corpus_path,
                fixture_json=semantic_path,
            )
            try:
                adapter.build(artifact)
                # The reopened artifact must not depend on either source file.
                semantic_path.unlink()
                corpus_path.unlink()
                adapter.verify()
                adapter.open(artifact)
                return {
                    "concept_zero": adapter.concept_members(0),
                    "concept_negative": adapter.concept_members(-7),
                    "translation_fr": adapter.translations(-7, "fr"),
                    "translation_unknown": adapter.translations(-7, "xx-never-seen"),
                    "relations_translation": adapter.relations(-7, "translation"),
                    "relations_synonym": adapter.relations(0, "near_synonym"),
                    "relations_hypernym": adapter.relations(100003, "hypernym"),
                }
            finally:
                adapter.close()

    def test_fact_ownership_survives_reopen_and_source_removal(self):
        executable = self._executable()
        base = _semantic()
        baseline = self._run_variant(executable, base)

        self.assertEqual([-7, 0], baseline["concept_zero"])
        self.assertEqual([100003], baseline["concept_negative"])
        self.assertEqual([0], baseline["translation_fr"])
        self.assertEqual([], baseline["translation_unknown"])
        self.assertEqual(
            [{"source": -7, "predicate": "translation", "target": 0, "asserted_by": "0", "certainty": "candidate"}],
            baseline["relations_translation"],
        )
        self.assertEqual(
            [{"source": 0, "predicate": "near_synonym", "target": 100003, "asserted_by": "-5", "certainty": "disputed"}],
            baseline["relations_synonym"],
        )
        self.assertEqual(
            [{"source": 100003, "predicate": "hypernym", "target": -7, "asserted_by": "9001", "certainty": "certain"}],
            baseline["relations_hypernym"],
        )

        changed_concept = copy.deepcopy(base)
        changed_concept["senses"][1]["concept"] = -7  # type: ignore[index]
        changed_concept["concepts"][0]["members"] = [-7]  # type: ignore[index]
        changed_concept["concepts"][1]["members"] = [0, 100003]  # type: ignore[index]
        moved = self._run_variant(executable, changed_concept)
        self.assertEqual([-7], moved["concept_zero"])
        self.assertEqual([0, 100003], moved["concept_negative"])
        self.assertEqual([], moved["translation_fr"])

        changed_language = copy.deepcopy(base)
        changed_language["senses"][1]["language"] = "de"  # type: ignore[index]
        changed_language_result = self._run_variant(executable, changed_language)
        self.assertEqual([], changed_language_result["translation_fr"])

        without_relations = _semantic(relations=False)
        no_graph = self._run_variant(executable, without_relations)
        self.assertEqual([0], no_graph["translation_fr"])
        self.assertEqual([], no_graph["relations_translation"])

    def test_conflicting_membership_and_unsupported_sense_domains_fail_build(self):
        executable = self._executable()
        missing = _semantic()
        missing["concepts"][0]["members"] = [-7]
        duplicate = _semantic()
        duplicate["concepts"][0]["members"] = [-7, 0, 0]
        misplaced = _semantic()
        misplaced["concepts"][0]["members"] = [-7, 100003]
        wrong_owner = _semantic()
        wrong_owner["senses"][1]["entry"] = -11
        for malformed in (missing, duplicate, misplaced, wrong_owner):
            with self.subTest(semantic=malformed), tempfile.TemporaryDirectory(prefix="lex4-invalid-ownership-") as name:
                root = Path(name)
                semantic_path, corpus_path = _write_sources(root, malformed)
                adapter = SubprocessAdapter(self._fixture(malformed), [str(executable)], corpus=corpus_path, fixture_json=semantic_path)
                try:
                    with self.assertRaises(AdapterError):
                        adapter.build(root / "artifact.lex4")
                    self.assertFalse((root / "artifact.lex4").exists())
                finally:
                    adapter.close()


if __name__ == "__main__":
    unittest.main()
