"""Nothing a server sends is trusted to be small.

Plex JSON and artwork bodies were read to EOF with no byte cap, and the
persistent Quickshell process then read whole generated indexes, so one
oversized reply could take the shell down with it. Every body is now capped
before it is buffered, and the index is bounded in both item count and string
length on the way out and again on the way in.

Run from the repo root:  python3 -m unittest discover -s tests
No Plex server and no token: the responses are fakes.
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HELPER = os.path.join(REPO, "bin", "plexmusic")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("plexmusic_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


plexmusic = load_helper()


class ResponseCapTests(unittest.TestCase):
    class FakeResponse:
        def __init__(self, body, declared=None, chunk=4096):
            self.body = body
            self.pos = 0
            self.chunk = chunk
            self.headers = {} if declared is None else {
                "Content-Length": str(declared)}

        def read(self, n=-1):
            if n is None or n < 0:
                n = len(self.body) - self.pos
            n = min(n, self.chunk)
            out = self.body[self.pos:self.pos + n]
            self.pos += len(out)
            return out

    def test_normal_body_passes(self):
        resp = self.FakeResponse(b"x" * 1000, declared=1000)
        self.assertEqual(len(plexmusic.read_capped(resp, 10000, "json")), 1000)

    def test_oversized_content_length_is_rejected_up_front(self):
        resp = self.FakeResponse(b"x" * 10, declared=10_000_000)
        with self.assertRaises(plexmusic.ResponseTooLarge):
            plexmusic.read_capped(resp, 1000, "json")
        self.assertEqual(resp.pos, 0, "nothing should have been read")

    def test_lying_content_length_is_caught_while_streaming(self):
        """Chunked, or simply lying: the cap is enforced on the bytes too."""
        resp = self.FakeResponse(b"x" * 50_000, declared=None)
        with self.assertRaises(plexmusic.ResponseTooLarge):
            plexmusic.read_capped(resp, 1000, "json")
        self.assertLessEqual(resp.pos, 1001 + 4096,
                             "more than the cap was buffered")

    def test_artwork_cap_is_separate_and_smaller(self):
        self.assertLess(plexmusic.MAX_ART_BYTES, plexmusic.MAX_JSON_BYTES)
        resp = self.FakeResponse(b"\xff\xd8" + b"j" * 5000, declared=5002)
        self.assertEqual(
            len(plexmusic.read_capped(resp, plexmusic.MAX_ART_BYTES, "art")),
            5002)


class IndexBoundTests(unittest.TestCase):
    def test_field_lengths_are_bounded(self):
        self.assertEqual(len(plexmusic.bounded_text("a" * 10_000)),
                         plexmusic.MAX_FIELD_CHARS)
        self.assertEqual(plexmusic.bounded_text(None), "")
        self.assertEqual(plexmusic.bounded_text(12345), "12345")

    def test_qml_mirrors_the_helper_limits(self):
        qml = open(os.path.join(REPO, "Service.qml")).read()
        self.assertIn("maxIndexItems: %d" % plexmusic.MAX_INDEX_ITEMS, qml)
        self.assertIn("maxFieldChars: %d" % plexmusic.MAX_FIELD_CHARS, qml)
        self.assertIn("boundedIndexList", qml)

    def test_helper_refuses_an_over_cardinality_library(self):
        src = open(HELPER).read()
        self.assertIn("refusing to build an index that large", src)
        self.assertEqual(src.count("refusing to build an index that large"), 2,
                         "both artists and tracks must be capped")


class QmlIndexGuardTests(unittest.TestCase):
    """The shell side must refuse an index it should not load.

    Service.qml cannot be instantiated here (it imports Quickshell), so the
    two guard functions are lifted out of the file verbatim and run in node.
    They are plain JavaScript, so this is the real shipped code, not a copy.
    """

    @staticmethod
    def extract(qml, name):
        start = qml.index("function %s(" % name)
        depth, i = 0, qml.index("{", start)
        while True:
            if qml[i] == "{":
                depth += 1
            elif qml[i] == "}":
                depth -= 1
                if depth == 0:
                    return qml[start:i + 1]
            i += 1

    def run_js(self, body):
        import shutil
        import subprocess
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("node not installed")
        with open(os.path.join(REPO, "Service.qml"), encoding="utf-8") as fh:
            qml = fh.read()
        harness = """
var console_warn = [];
var root = {
  maxIndexItems: 250000, maxFieldChars: 512, maxIndexBytes: 96*1024*1024,
  indexError: "",
  parse: function (t) { try { return JSON.parse(t) } catch (e) { return null } },
};
var console = { warn: function () { console_warn.push(1) } };
root.parseIndex = %s;
root.boundedIndexList = %s;
%s
""" % (self.extract(qml, "parseIndex").replace("function parseIndex", "function"),
            self.extract(qml, "boundedIndexList").replace(
                "function boundedIndexList", "function"),
            body)
        out = subprocess.run([node, "-e", harness], capture_output=True,
                             text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_a_normal_index_loads(self):
        body = """
var d = root.parseIndex(JSON.stringify({artists: [{title: "Kate Bush",
  fold: "kate bush", letter: "K", key: "1"}]}), "artist");
var list = root.boundedIndexList(d.artists, "artist");
process.stdout.write(list === null ? "REFUSED" : String(list.length));
"""
        self.assertEqual(self.run_js(body), "1")

    def test_over_cardinality_index_is_refused(self):
        body = """
var big = new Array(root.maxIndexItems + 1);
process.stdout.write(root.boundedIndexList(big, "track") === null
  ? "REFUSED:" + (root.indexError.indexOf("over the") >= 0) : "LOADED");
"""
        self.assertEqual(self.run_js(body), "REFUSED:true")

    def test_oversized_index_file_is_not_even_parsed(self):
        body = """
var huge = new Array(root.maxIndexBytes + 2).join("x");
process.stdout.write(root.parseIndex(huge, "artist") === null
  ? "REFUSED:" + (root.indexError.indexOf("too large") >= 0) : "PARSED");
"""
        self.assertEqual(self.run_js(body), "REFUSED:true")

    def test_long_strings_are_clamped(self):
        body = """
var list = [{title: new Array(5000).join("t"), fold: "x", letter: "T"}];
var out = root.boundedIndexList(list, "track");
process.stdout.write(String(out[0].title.length));
"""
        self.assertEqual(self.run_js(body), "512")


if __name__ == "__main__":
    unittest.main()
