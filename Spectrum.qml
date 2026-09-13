import QtQuick
import qs.Commons

// The meter band: every frequency from low on the left to high on the right,
// fed by cava. Peak caps hang at the loudest point each bar has reached and
// sink back slowly, the way the LEDs on a hardware meter bridge do.
//
// Colour is still entirely the theme's, but used in two directions at once:
// the hue walks from the accent colour at the bass end to the urgent colour at
// the treble end, and each bar brightens with level, with a soft glow behind
// it. So the band reads as one instrument rather than a row of identical
// sticks, and it re-skins with the theme.
Item {
  id: root

  property var levels: []             // 0-100 per bar, straight from cava
  property bool live: false
  property int gap: 2

  readonly property int count: levels && levels.length > 0 ? levels.length : 64

  // Peak caps, kept in plain arrays and pushed to the repeater on each frame.
  property var peaks: []

  // Mix two theme colours, then brighten with level.
  function tone(pos, level) {
    var a = Color.accent, u = Color.urgent, f = Color.foreground
    var t = Math.max(0, Math.min(1, pos))
    var r = a.r + (u.r - a.r) * t, g = a.g + (u.g - a.g) * t, b = a.b + (u.b - a.b) * t
    // Loud bars lift toward the foreground colour so peaks look hot.
    var k = Math.max(0, Math.min(1, (level - 60) / 40)) * 0.55
    return Qt.rgba(r + (f.r - r) * k, g + (f.g - g) * k, b + (f.b - b) * k, 1)
  }

  onLevelsChanged: {
    if (!levels || levels.length === 0) return
    var next = peaks.slice()
    if (next.length !== levels.length) {
      next = []
      for (var i = 0; i < levels.length; i++) next.push(0)
    }
    for (var j = 0; j < levels.length; j++)
      if (levels[j] > next[j]) next[j] = levels[j]
    peaks = next
  }

  // Caps fall at a fixed rate rather than tracking the signal down, which is
  // what makes them readable.
  Timer {
    interval: 50
    running: root.live
    repeat: true
    onTriggered: {
      if (!root.peaks || root.peaks.length === 0) return
      var next = root.peaks.slice()
      for (var i = 0; i < next.length; i++)
        next[i] = Math.max(0, next[i] - 2.2)
      root.peaks = next
    }
  }

  onLiveChanged: if (!live) peaks = []

  Row {
    id: row
    anchors.fill: parent
    spacing: root.gap

    Repeater {
      model: root.count

      delegate: Item {
        id: slot
        width: (root.width - root.gap * (root.count - 1)) / root.count
        height: root.height

        readonly property real pos: root.count > 1 ? index / (root.count - 1) : 0
        readonly property real value: {
          if (!root.live || !root.levels || index >= root.levels.length) return 0
          return Math.max(0, Math.min(100, root.levels[index]))
        }
        readonly property real peak: {
          if (!root.live || !root.peaks || index >= root.peaks.length) return 0
          return Math.max(0, Math.min(100, root.peaks[index]))
        }
        readonly property color hue: root.tone(pos, value)

        // The floor: a bar is always visible so the band reads as an instrument
        // at rest rather than as empty space.
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(1.5, parent.height * 0.012)
          radius: width > 3 ? 1 : 0
          color: Qt.rgba(slot.hue.r, slot.hue.g, slot.hue.b, root.live ? 0.35 : 0.18)
        }

        // Glow: the same bar, wider and translucent, behind the solid one.
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width + root.gap * 2
          height: bar.height + 6
          radius: 3
          color: Qt.rgba(slot.hue.r, slot.hue.g, slot.hue.b, 0.16)
          visible: slot.value > 2
        }

        Rectangle {
          id: bar
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(0, parent.height * (slot.value / 100))
          radius: width > 3 ? 1.5 : 0
          gradient: Gradient {
            GradientStop { position: 0.0; color: slot.hue }
            GradientStop {
              position: 1.0
              color: Qt.rgba(slot.hue.r, slot.hue.g, slot.hue.b, 0.45)
            }
          }
        }

        Rectangle {
          id: cap
          width: parent.width
          height: Math.max(1.5, parent.height * 0.014)
          radius: height / 2
          y: Math.max(0, parent.height - parent.height * (slot.peak / 100) - height)
          visible: slot.peak > 1
          color: Color.foreground
          opacity: 0.8
        }
      }
    }
  }

  // Said plainly rather than left as a dead band the user has to wonder about.
  Text {
    anchors.centerIn: parent
    visible: !root.live
    text: "spectrum idle"
    font.pixelSize: 10
    font.letterSpacing: 1.5
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
  }
}
