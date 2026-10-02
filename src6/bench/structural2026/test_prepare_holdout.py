import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("holdout", Path(__file__).with_name("prepare_holdout.py"))
holdout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(holdout)


def token(identifier, form):
    return identifier + b"\t" + form + b"\t_\tNOUN\t_\t_\t0\troot\t_\t_\n"


class ProjectionTests(unittest.TestCase):
    def test_exact_unicode_and_official_tokenization(self):
        text = "e\u0301\u2028字\u00a0 !".encode()
        raw = b"# text = " + text + b"\n" + token(b"1-2", b"combined")
        raw += token(b"1", "e\u0301".encode()) + token(b"2", "字".encode())
        raw += token(b"2.1", b"empty-node") + b"\n"
        prose, forms, annotations, sentences, count = holdout.project_ud(raw)
        self.assertEqual(prose, text + b"\n")
        self.assertEqual(forms, "e\u0301 字\n".encode())
        self.assertEqual((sentences, count), (1, 2))
        self.assertEqual(annotations[0][0][1], "e\u0301")

    def test_no_missing_sentence_or_token_repair(self):
        for raw in (token(b"1", b"a"), b"# text = a\n\n",
                    b"# text = a\n" + token(b"2", b"a"),
                    b"# text = a\n" + token(b"-1", b"a")):
            with self.assertRaises(ValueError):
                holdout.project_ud(raw)

    def test_duplicate_text_and_invalid_utf8_rejected(self):
        with self.assertRaises(ValueError):
            holdout.project_ud(b"# text = a\n# text = b\n" + token(b"1", b"a"))
        with self.assertRaises(UnicodeDecodeError):
            holdout.project_ud(b"# text = \xff\n" + token(b"1", b"a"))


if __name__ == "__main__":
    unittest.main()
