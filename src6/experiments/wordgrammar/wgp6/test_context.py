#!/usr/bin/env python3
"""Private forward-DAG/context-tiler integrity tests, not archive hardening."""
import json
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def array(values):
    return struct.pack("<I", len(values)) + struct.pack("<" + "I" * len(values), *values)


def graph(bodies, blocks):
    off, children = [0], []
    for body in bodies:
        children.extend(body)
        off.append(len(children))
    boff, roots = [0], []
    for block in blocks:
        roots.extend(block)
        boff.append(len(roots))
    return b"P6F1" + b"".join(array(x) for x in (off, children, boff, roots))


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, executable, *args, success=True):
        result = subprocess.run([str(HERE / executable), *map(str, args)],
                                capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def fixture(self):
        # A long macro omitted from the bounded match trie, exact multilingual
        # and arbitrary bytes, and a valid forward definition reference.
        spelling = ("東京 Straße العربية e\u0301\n".encode() + bytes(range(256))) * 2
        bodies = [list(spelling), [256, 256], [259, 259], list(b"affix")]
        blocks = [[257, 258, 256, 0], [256, 258, 257, 255]]
        data = ((spelling * 2) + b"affixaffix" + spelling + b"\0" +
                spelling + b"affixaffix" + (spelling * 2) + b"\xff")
        raw, parsed, frame, prices = (self.root / name for name in
                                     ("raw", "input.forward", "base.frame", "base.prices"))
        raw.write_bytes(data)
        parsed.write_bytes(graph(bodies, blocks))
        metrics = self.run_tool("native_forward", "compile", parsed, frame, 0, prices)
        return raw, parsed, frame, prices, metrics

    def test_all_modes_exact_deterministic_and_fresh_restarts(self):
        raw, parsed, _, prices, _ = self.fixture()
        for mode in ("payload", "spelling", "both"):
            for prune in (0, 1):
                with self.subTest(mode=mode, prune=prune):
                    output, repeat = self.root / "out.forward", self.root / "repeat.forward"
                    self.run_tool("reparse_context", raw, parsed, prices, output, mode, prune)
                    self.run_tool("reparse_context", raw, parsed, prices, repeat, mode, prune)
                    self.assertEqual(output.read_bytes(), repeat.read_bytes())
                    frame, decoded = self.root / "out.frame", self.root / "decoded"
                    metrics = self.run_tool("native_forward", "compile", output, frame, 0)
                    self.run_tool("native_forward", "decode", frame, decoded)
                    self.assertEqual(decoded.read_bytes(), raw.read_bytes())
                    position = 0
                    for index, length in enumerate(metrics["block_raw_lengths"]):
                        block = self.root / "block"
                        self.run_tool("native_forward", "extract", frame, block, index)
                        self.assertEqual(block.read_bytes(), raw.read_bytes()[position:position + length])
                        position += length
                    self.assertEqual(position, raw.stat().st_size)

    def test_forward_cycle_and_out_of_range_rejected_before_fit(self):
        invalids = (graph([[257], [256]], [[256]]),
                    graph([[999999]], [[256]]))
        for data in invalids:
            parsed = self.root / "bad.forward"
            parsed.write_bytes(data)
            self.run_tool("native_forward", "compile", parsed, self.root / "frame", 0, success=False)

    def test_corrupt_prices_and_source_mismatch_rejected(self):
        raw, parsed, _, prices, _ = self.fixture()
        data = prices.read_bytes()
        for altered in (data[:11], data[:-1], data + b"x",
                        data[:12] + struct.pack("<f", float("nan")) + data[16:]):
            prices.write_bytes(altered)
            self.run_tool("reparse_context", raw, parsed, prices, self.root / "out", "both", 0, success=False)
        prices.write_bytes(data)
        raw.write_bytes(b"x" + raw.read_bytes()[1:])
        self.run_tool("reparse_context", raw, parsed, prices, self.root / "out", "both", 0, success=False)

    def test_truncated_graph_and_invalid_policy_rejected(self):
        raw, parsed, _, prices, _ = self.fixture()
        data = parsed.read_bytes()
        for offset in (0, 3, 4, 8, len(data) - 1):
            parsed.write_bytes(data[:offset])
            self.run_tool("native_forward", "compile", parsed, self.root / "frame", 0, success=False)
            self.run_tool("reparse_context", raw, parsed, prices, self.root / "out", "both", 0, success=False)
        parsed.write_bytes(data)
        self.run_tool("reparse_context", raw, parsed, prices, self.root / "out", "both", 2, success=False)


if __name__ == "__main__":
    unittest.main()
