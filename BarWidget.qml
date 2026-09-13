import QtQuick
import qs.Commons
import qs.Ui

// What is playing, in the bar, with a small live meter beside it. Click for the
// turntable.
BarWidget {
  id: root
  moduleName: "io.github.mfilm77.plexmusic"

  // A bar widget has to ask the shell for its plugin service; panels are handed
  // one directly.
  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor("io.github.mfilm77.plexmusic") : null

  readonly property bool showTrack: setting("showTrack", true)
  readonly property int maxTrackChars: setting("maxTrackChars", 28)
  readonly property bool showMeter: setting("showMeter", true)
  readonly property int meterBars: setting("meterBars", 40)
  readonly property bool playing: service ? service.playing : false
  readonly property bool paused: service ? service.paused : false

  // Computed in a function with a catch: while the shell reloads a plugin the
  // service is deleted under a live binding, and QML then reads its properties
  // as "of null" even past a null check.
  function trackText() {
    try {
      if (!root.service || !root.service.playing) return ""
      var t = root.service.trackTitle || ""
      var a = root.service.trackArtist || ""
      var s = a ? (t + " — " + a) : t
      if (s.length > root.maxTrackChars) s = s.substring(0, root.maxTrackChars - 1) + "…"
      return s
    } catch (e) {
      return ""
    }
  }

  function tooltip() {
    try {
      if (!root.service) return "Plex Music"
      if (!root.service.linked) return "Plex Music · not linked\nClick to link your account"
      if (!root.service.playing) {
        var n = root.service.artistCount
        return "Plex Music · " + (n > 0 ? n + " artists indexed" : "no index yet")
          + "\nClick for the turntable and your starred artists"
      }
      var lines = [root.service.trackTitle || "—"]
      if (root.service.trackArtist) lines.push(root.service.trackArtist)
      if (root.service.trackAlbum) lines.push(root.service.trackAlbum)
      return lines.join("\n") + (root.service.paused ? "\n(paused)" : "")
    } catch (e) {
      return "Plex Music"
    }
  }

  // The 64 cava bands folded down to a handful for the bar: each mini bar is
  // the mean of its share of the full band, so the shape is the same as the
  // panel's, just coarser.
  readonly property var mini: {
    try {
      var lv = root.service ? root.service.levels : []
      if (!lv || lv.length === 0) return []
      var n = Math.max(4, root.meterBars)
      var per = lv.length / n
      var out = []
      for (var i = 0; i < n; i++) {
        var a = Math.floor(i * per), b = Math.max(a + 1, Math.floor((i + 1) * per))
        var sum = 0
        for (var j = a; j < b && j < lv.length; j++) sum += lv[j]
        out.push(sum / (b - a))
      }
      return out
    } catch (e) {
      return []
    }
  }
  readonly property bool meterLive: root.showMeter && !root.vertical
    && root.playing && !root.paused && root.mini.length > 0

  implicitWidth: button.implicitWidth + (meter.visible ? meter.width + 2 : 0)
  implicitHeight: root.vertical ? button.implicitHeight : root.barSize

  WidgetButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    tooltipText: root.tooltip()
    dimmed: !root.playing
    fontSize: Style.font.body
    horizontalMargin: 6
    verticalPadding: 2

    text: {
      // A spinning-record glyph when playing, a still one when not: the bar
      // should say whether there is music without being read.
      var icon = root.playing ? (root.paused ? "󰏤" : "󰓃") : "󰎆"
      if (root.vertical) return icon
      var label = root.showTrack ? root.trackText() : ""
      return label ? icon + "  " + label : icon
    }

    // Middle-click pauses without opening anything, which is what you want when
    // a call starts.
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.service) root.service.control("play-pause")
        return
      }
      if (!bar || !bar.shell) return
      if (typeof bar.shell.toggle === "function")
        bar.shell.toggle(root.moduleName, "{}")
      else if (typeof bar.shell.summon === "function")
        bar.shell.summon(root.moduleName, "{}")
    }
  }

  // The mini meter. Sits inside the widget's own footprint so it opens the
  // panel like the text does, and disappears entirely when nothing is playing
  // rather than leaving a flat line in the bar.
  Item {
    id: meter
    anchors.left: button.right
    anchors.leftMargin: 2
    anchors.verticalCenter: parent.verticalCenter
    visible: root.meterLive
    readonly property int bars: root.mini.length
    readonly property real barW: 3
    readonly property real gap: 1
    width: bars > 0 ? bars * (barW + gap) - gap + 10 : 0
    height: Math.max(10, root.barSize - 8)

    // Same colour logic as the panel band: accent at the bass end walking to
    // urgent at the treble end, lifting toward the foreground when loud.
    function tone(pos, level) {
      var a = Color.accent, u = Color.urgent, f = Color.foreground
      var t = Math.max(0, Math.min(1, pos))
      var r = a.r + (u.r - a.r) * t, g = a.g + (u.g - a.g) * t, b = a.b + (u.b - a.b) * t
      var k = Math.max(0, Math.min(1, (level - 60) / 40)) * 0.6
      return Qt.rgba(r + (f.r - r) * k, g + (f.g - g) * k, b + (f.b - b) * k, 1)
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: 5
      anchors.rightMargin: 5
      spacing: meter.gap

      Repeater {
        model: meter.bars
        delegate: Item {
          width: meter.barW
          height: meter.height
          readonly property real v: index < root.mini.length ? root.mini[index] : 0
          readonly property color hue: meter.tone(meter.bars > 1 ? index / (meter.bars - 1) : 0, v)

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width + 2
            height: bar.height + 3
            radius: 1.5
            color: Qt.rgba(hue.r, hue.g, hue.b, 0.18)
            visible: v > 2
          }

          Rectangle {
            id: bar
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.max(1, parent.height * Math.min(1, v / 100))
            radius: 1
            color: hue
            opacity: 0.95
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        if (bar && bar.shell && typeof bar.shell.toggle === "function")
          bar.shell.toggle(root.moduleName, "{}")
      }
    }
  }
}
