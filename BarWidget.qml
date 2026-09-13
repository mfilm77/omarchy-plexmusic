import QtQuick
import qs.Commons
import qs.Ui

// What is playing, in the bar. Click for the turntable.
BarWidget {
  id: root
  moduleName: "io.github.mfilm77.plexmusic"

  // A bar widget has to ask the shell for its plugin service; panels are handed
  // one directly.
  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor("io.github.mfilm77.plexmusic") : null

  readonly property bool showTrack: setting("showTrack", true)
  readonly property int maxTrackChars: setting("maxTrackChars", 28)
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

  implicitWidth: button.implicitWidth
  implicitHeight: root.vertical ? button.implicitHeight : root.barSize

  WidgetButton {
    id: button
    anchors.fill: parent
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
}
