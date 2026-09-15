"""The record keeps turning after the panel is hidden and shown again.

Bug B1: the spin was a RotationAnimator. The panel is kept loaded and only
hidden, and hiding its window stopped the Animator's render-thread job while
`running` stayed true, so after a reopen the vinyl sat still with music playing.

Run from the repo root:  python3 -m unittest discover -s tests
The behaviour test needs PySide6 (pip install PySide6-Essentials) and runs
offscreen; without PySide6 it is skipped and only the source check runs. The
real Quickshell layer-shell window can only be checked on an Omarchy desktop.
"""

import os
import re
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))

COLOR_STUB = """pragma Singleton
import QtQuick
QtObject {
  property color accent: "#33aaff"
  property color foreground: "#f0f0f0"
  property color urgent: "#ff3366"
  property QtObject popups: QtObject { property color background: "#101014" }
}
"""

HARNESS = """import QtQuick
import QtQuick.Window
import "%s" as P
Window {
  id: win
  width: 420; height: 420
  visible: false
  P.Vinyl {
    id: rec
    objectName: "vinyl"
    anchors.fill: parent
    spinning: true
    shown: win.visible
  }
}
"""


class VinylSourceTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(REPO, "Vinyl.qml"), encoding="utf-8") as fh:
            self.vinyl = fh.read()
        with open(os.path.join(REPO, "Panel.qml"), encoding="utf-8") as fh:
            self.panel = fh.read()

    def test_no_render_thread_animator_on_the_record(self):
        code = "\n".join(l for l in self.vinyl.splitlines() if not l.strip().startswith("//"))
        self.assertIsNone(re.search(r"\bRotationAnimator\s*\{", code),
                          "Vinyl.qml spins the record with a RotationAnimator (bug B1)")

    def test_spin_runs_only_while_playing_and_shown(self):
        m = re.search(r"NumberAnimation\s*\{(?:[^{}]*)id:\s*spin(?:[^{}]*)\}", self.vinyl, re.S)
        self.assertIsNotNone(m, "the spin NumberAnimation is missing")
        self.assertRegex(m.group(0), r"running:\s*root\.spinning\s*&&\s*root\.shown")
        self.assertRegex(m.group(0), r'property:\s*"rotation"')

    def test_panel_passes_its_visibility(self):
        self.assertIsNotNone(re.search(r"shown:\s*root\.visible", self.panel),
                             "Panel.qml does not pass its visibility to the Vinyl (bug B1)")


class VinylSpinBehaviourTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from PySide6.QtCore import QUrl  # noqa: F401
            from PySide6.QtGui import QGuiApplication  # noqa: F401
            from PySide6.QtQml import QQmlApplicationEngine  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("PySide6 not installed")
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        from PySide6.QtGui import QGuiApplication
        cls.app = QGuiApplication.instance() or QGuiApplication([])

    def pump(self, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.app.processEvents()
            time.sleep(0.01)

    def test_spin_survives_hide_and_show(self):
        from PySide6.QtCore import QObject, QUrl
        from PySide6.QtQml import QQmlApplicationEngine

        with tempfile.TemporaryDirectory() as tmp:
            stub = os.path.join(tmp, "qs", "Commons")
            os.makedirs(stub)
            with open(os.path.join(stub, "qmldir"), "w") as fh:
                fh.write("module qs.Commons\nsingleton Color 1.0 Color.qml\n")
            with open(os.path.join(stub, "Color.qml"), "w") as fh:
                fh.write(COLOR_STUB)
            harness = os.path.join(tmp, "harness.qml")
            with open(harness, "w") as fh:
                fh.write(HARNESS % QUrl.fromLocalFile(REPO + "/").toString())

            engine = QQmlApplicationEngine()
            engine.addImportPath(tmp)
            engine.load(QUrl.fromLocalFile(harness))
            self.assertTrue(engine.rootObjects(), "harness failed to load")
            win = engine.rootObjects()[0]
            vinyl = win.findChild(QObject, "vinyl")
            self.assertIsNotNone(vinyl, "Vinyl not found in the harness")
            spin = [c for c in vinyl.findChildren(QObject)
                    if c.metaObject().className().startswith("QQuickNumberAnimation")
                    and c.property("property") == "rotation"]
            self.assertEqual(len(spin), 1, "exactly one rotation animation on the record")
            spin = spin[0]
            target = spin.property("target")

            def angles(n=3, gap=0.15):
                out = []
                for _ in range(n):
                    self.pump(gap)
                    out.append(round(float(target.property("rotation")), 2))
                return out

            win.setProperty("visible", True)
            self.pump(0.2)
            self.assertTrue(spin.property("running"), "should spin while playing and shown")
            first = angles()
            self.assertGreater(len(set(first)), 1, f"record not turning when first shown: {first}")

            # The panel auto-hides and is shown again, several times over.
            for cycle in range(3):
                win.setProperty("visible", False)
                self.pump(0.2)
                self.assertFalse(spin.property("running"), f"cycle {cycle}: still running while hidden")
                win.setProperty("visible", True)
                self.pump(0.2)
                self.assertTrue(spin.property("running"), f"cycle {cycle}: not running after show")
                again = angles()
                self.assertGreater(len(set(again)), 1,
                                   f"cycle {cycle}: record static after reopen: {again}")

            # Paused music: the record stops even while shown.
            vinyl.setProperty("spinning", False)
            self.pump(0.2)
            self.assertFalse(spin.property("running"))
            still = angles()
            self.assertEqual(len(set(still)), 1, f"record turning while paused: {still}")
            engine.deleteLater()


if __name__ == "__main__":
    unittest.main()
