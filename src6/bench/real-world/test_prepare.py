#!/usr/bin/env python3
"""Small parser regressions for the real-world projection policy."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare  # noqa: E402


class ProjectionPolicyTests(unittest.TestCase):
    def test_mixed_content_tails_and_qualified_attribute_are_preserved(self) -> None:
        root = ET.fromstring(
            '<entry xmlns:x="urn:x" xml:lang="ja"><form><orth>語<hi>彙</hi></orth></form>'
            '<sense><x:label x:k="v">a<hi> </hi>b</x:label></sense></entry>'
        )
        rendered = prepare.xml_fragment(root)
        self.assertIn("a<hi> </hi>b", rendered)
        self.assertIn("xmlns:ns0=\"urn:x\"", rendered)
        self.assertIn("ns0:k=\"v\"", rendered)
        self.assertIn("xml:lang=\"ja\"", rendered)

    def test_freedict_nested_orth_and_duplicate_forms_are_not_dropped(self) -> None:
        root = ET.fromstring(
            '<TEI><entry xml:id="e1">'
            '<form><orth>a<hi>b</hi></orth><orth>a<hi>b</hi></orth></form>'
            '<sense><def>one</def><def>two</def></sense></entry></TEI>'
        )
        forms = ["".join(orth.itertext()) for form in prepare.iter_children(root.find("entry"), "form") for orth in form.iter() if prepare.local_name(orth.tag) == "orth"]
        self.assertEqual(forms, ["ab", "ab"])
        self.assertIn("<form>", prepare.xml_fragment(root.find("entry")))
        self.assertEqual(prepare.xml_fragment(root.find("entry")).count("<def>"), 2)

    def test_projection_retains_key_order_duplicates_and_empty_content(self) -> None:
        row = prepare.Row(
            row_id="row-1",
            source_entry_id="source-1",
            source_ordinal=0,
            source_file="fixture",
            keys=["z", "a", "z"],
            content="",
            native_record_bytes=0,
            extra={},
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            report = prepare.write_projection(
                [row], output, corpus="fixture", source_manifest={}, stats={}
            )
            fields = (output / "projection.tsv").read_text(encoding="ascii").splitlines()[0].split("\t")
            self.assertEqual(bytes.fromhex(fields[0]), b"row-1")
            self.assertEqual(fields[1], "7a,61,7a")
            self.assertEqual(fields[2], "")
            self.assertEqual(report["key_hits"], 3)
            self.assertEqual(report["unique_keys"], 2)
            self.assertEqual(report["duplicate_key_hits"], 1)

    def test_gcide_aliases_are_one_record_with_all_ent_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
                body = "<p><ent>primary</ent><br/\n<ent>alias</ent><br/\n<hw>primary</hw><def>full</def></p>\n" if letter == "A" else "<p><ent>k</ent><def>v</def></p>\n"
                (root / f"CIDE.{letter}").write_text(body, encoding="utf-8")
            rows, stats = prepare.parse_gcide(root)
            self.assertEqual(rows[0].keys, ["primary", "alias"])
            self.assertIn("<ent>alias</ent>", rows[0].content)
            self.assertEqual(stats["parse_failures"], 0)

    def test_omw_shared_synset_expands_once_per_lexical_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "omw-ja.xml").write_text(
                '<LexicalResource><Lexicon language="jpn">'
                '<LexicalEntry id="e1"><Lemma writtenForm="語"/><Sense id="s1" synset="syn1"/><Sense id="s2" synset="syn1"/></LexicalEntry>'
                '<LexicalEntry id="e2"><Lemma writtenForm="語彙"/><Sense id="s3" synset="syn1"/></LexicalEntry>'
                '<Synset id="syn1" ili="i1"><Definition>def</Definition><Example>ex</Example><Relation relType="near" target="syn2"/></Synset>'
                '</Lexicon></LexicalResource>',
                encoding="utf-8",
            )
            rows, stats = prepare.parse_omw(root)
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0].extra["unique_synset_count"], 1)
            self.assertEqual(rows[0].content.count("<Synset"), 1)
            self.assertEqual(stats["synset_references"], 3)
            self.assertEqual(stats["unique_synsets_referenced"], 1)
            self.assertGreater(stats["expanded_synset_serialized_bytes"], stats["unique_synset_serialized_bytes"])


if __name__ == "__main__":
    unittest.main()
