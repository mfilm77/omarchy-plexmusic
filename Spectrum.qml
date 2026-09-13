import QtQuick
import qs.Commons

// The meter band: every frequency from low on the left to high on the right,
// fed by cava. Peak caps hang at the loudest point each bar has reached and
// sink back slowly, the way the LEDs on a hardware meter bridge do.
//
// Colours come entirely from the active Omarchy theme, so the meters belong to
// whatever the desktop is wearing instead of being a green strip bolted on.
Item {
  id: root

  property var levels: []             // 0-100 per bar, straight from cava
  property bool live: false
  property int gap: 2

  readonly property int count: levels && levels.length > 0 ? levels.length : 64

  // Peak caps, kept in plain arrays and pushed to the repeater on each frame.
  property var peaks: []

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

        readonly property real value: {
          if (!root.live || !root.levels || index >= root.levels.length) return 0
          return Math.max(0, Math.min(100, root.levels[index]))
        }
        readonly property real peak: {
          if (!root.live || !root.peaks || index >= root.peaks.length) return 0
          return Math.max(0, Math.min(100, root.peaks[index]))
        }

        // The floor: a bar is always visible so the band reads as an instrument
        // at rest rather than as empty space.
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(1.5, parent.height * 0.012)
          radius: width > 3 ? 1 : 0
          color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                         Color.foreground.b, 0.16)
        }

        Rectangle {
          id: bar
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(0, parent.height * (slot.value / 100))
          radius: width > 3 ? 1.5 : 0
          gradient: Gradient {
            // Quiet passages sit in the accent colour; only the loud peaks
            // reach the theme's urgent colour, so clipping is visible.
            GradientStop { position: 0.0; color: Color.urgent }
            GradientStop { position: 0.45; color: Color.accent }
            GradientStop {
              position: 1.0
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
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
          opacity: 0.75
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
