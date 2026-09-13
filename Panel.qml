import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The turntable. A record with the real cover on the label, your starred
// artists down the side, a search box over the whole library, and the meter
// band along the bottom.
//
// Clicking an artist plays them — that is the entire interaction. Everything
// else on this panel is there to tell you what is happening.
PanelWindow {
  id: root

  property var service
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id
    ? manifest.id : "io.github.mfilm77.plexmusic"

  function open(payloadJson) {
    root.visible = true
    if (service) {
      service.spectrumWanted = true
      service.refreshStatus()
      service.refreshFavourites()
      service.refreshNow()
    }
    searchField.forceActiveFocus()
  }

  function close() {
    if (service) service.spectrumWanted = false
    root.visible = false
  }

  function dismiss() {
    if (service) service.spectrumWanted = false
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else root.visible = false
  }

  visible: false
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-plexmusic"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  function fmt(seconds) {
    if (!seconds || seconds < 0) return "0:00"
    var s = Math.floor(seconds)
    var m = Math.floor(s / 60)
    var r = s % 60
    return m + ":" + (r < 10 ? "0" + r : r)
  }

  // Click-away closes, as every other Omarchy panel does.
  MouseArea {
    anchors.fill: parent
    onClicked: root.dismiss()
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.72)
  }

  // Escape has to hang off a real Item — a PanelWindow is not one, and Qt
  // silently drops the Keys attachment with only a warning in the shell log.
  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: root.dismiss()
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(940, parent.width - 80)
    height: Math.min(660, parent.height - 80)
    radius: 16
    color: Color.popups.background
    border.width: 1
    border.color: Qt.rgba(Color.popups.border.r, Color.popups.border.g,
                          Color.popups.border.b, 0.6)

    // Swallow clicks so they do not reach the dismiss layer underneath.
    MouseArea { anchors.fill: parent }

    // ---- header -------------------------------------------------------------

    Item {
      id: header
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 18
      height: 30

      Text {
        id: heading
        anchors.verticalCenter: parent.verticalCenter
        text: "󰎆  Plex Music"
        font.pixelSize: 15
        font.bold: true
        color: Color.foreground
      }

      Text {
        anchors.left: heading.right
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (!root.service) return ""
          if (!root.service.linked) return "not linked"
          var n = root.service.artistCount
          return (n > 0 ? n + " artists" : "no index yet")
            + (root.service.server ? " · " + root.service.server.replace(/^https?:\/\//, "") : "")
        }
        font.pixelSize: 11
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        // Shuffle is on by default: starring an artist is a mood, not a
        // request to hear their first album in order.
        IconToggle {
          glyph: "󰒝"
          tip: "Shuffle the artist"
          on: root.service ? root.service.shuffle : true
          onTapped: if (root.service) root.service.shuffle = !root.service.shuffle
        }

        IconToggle {
          glyph: "󰑐"
          tip: "Rescan the library"
          on: false
          onTapped: if (root.service) root.service.reindex()
        }

        IconToggle {
          glyph: "󰅖"
          tip: "Close"
          on: false
          onTapped: root.dismiss()
        }
      }
    }

    // ---- not linked ---------------------------------------------------------

    Item {
      id: linkPane
      anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
      anchors.margins: 18
      visible: root.service ? !root.service.linked : false

      Column {
        anchors.centerIn: parent
        width: Math.min(420, parent.width - 40)
        spacing: 14

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Link your Plex account"
          font.pixelSize: 17
          font.bold: true
          color: Color.foreground
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "Open plex.tv/link in a browser and type the code below. "
                + "Your password never passes through this plugin — Plex hands "
                + "back a token, which is stored on this machine only."
          font.pixelSize: 12
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)
        }

        Rectangle {
          width: parent.width
          height: 62
          radius: 10
          visible: root.service && root.service.linkCode !== ""
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
          border.width: 1
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)

          Text {
            anchors.centerIn: parent
            text: root.service ? root.service.linkCode : ""
            font.pixelSize: 30
            font.bold: true
            font.letterSpacing: 8
            color: Color.accent
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 10

          TextBtn {
            label: root.service && root.service.linking ? "Waiting for Plex…" : "Get a code"
            accent: true
            enabled: root.service ? !root.service.linking : false
            onTapped: if (root.service) root.service.startLink()
          }

          TextBtn {
            label: "Open plex.tv/link"
            onTapped: openLink.running = true
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: root.service && root.service.lastError !== ""
          text: root.service ? root.service.lastError : ""
          font.pixelSize: 11
          color: Color.urgent
        }
      }

      Process { id: openLink; command: ["xdg-open", "https://plex.tv/link"] }
    }

    // ---- main ---------------------------------------------------------------

    Item {
      id: body
      anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: meters.top }
      anchors.margins: 18
      visible: root.service ? root.service.linked : false

      // ---- left: the record -------------------------------------------------
      Item {
        id: deck
        anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
        width: parent.width * 0.46

        Vinyl {
          id: vinyl
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          width: Math.max(0, Math.min(parent.width, parent.height - 130))
          height: width
          spinning: root.service ? (root.service.playing && !root.service.paused) : false
          art: root.service ? root.service.artPath : ""
          progress: root.service && root.service.duration > 0
            ? root.service.position / root.service.duration : 0
        }

        Column {
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          spacing: 8

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.service && root.service.playing
              ? (root.service.trackTitle || "—") : "Nothing playing"
            font.pixelSize: 14
            font.bold: true
            color: Color.foreground
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            visible: root.service && root.service.playing
            text: root.service
              ? [root.service.trackArtist, root.service.trackAlbum].filter(Boolean).join("  ·  ")
              : ""
            font.pixelSize: 11
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)
          }

          // Progress, with the times either side of it.
          Item {
            width: parent.width
            height: 14
            visible: root.service && root.service.playing

            Text {
              id: elapsed
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmt(root.service ? root.service.position : 0)
              font.pixelSize: 10
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
            }

            Text {
              id: total
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmt(root.service ? root.service.duration : 0)
              font.pixelSize: 10
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: elapsed.right
              anchors.right: total.left
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              height: 3
              radius: 1.5
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: Color.accent
                width: parent.width * (root.service && root.service.duration > 0
                  ? Math.min(1, root.service.position / root.service.duration) : 0)
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 14

            IconToggle {
              glyph: "󰒮"; tip: "Previous"; on: false; big: true
              onTapped: if (root.service) root.service.control("prev")
            }

            IconToggle {
              glyph: root.service && root.service.playing && !root.service.paused
                ? "󰏤" : "󰐊"
              tip: "Play / pause"
              on: root.service ? (root.service.playing && !root.service.paused) : false
              big: true
              onTapped: if (root.service) root.service.control("play-pause")
            }

            IconToggle {
              glyph: "󰒭"; tip: "Next"; on: false; big: true
              onTapped: if (root.service) root.service.control("next")
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: root.service && root.service.playing && root.service.queueCount > 0
            text: root.service
              ? root.service.queuePos + " of " + root.service.queueCount
                + (root.service.shuffle ? "  ·  shuffled" : "")
              : ""
            font.pixelSize: 10
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
          }
        }
      }

      // ---- right: search and the starred list -------------------------------
      Item {
        id: side
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        anchors.leftMargin: 18
        width: parent.width - deck.width - 18

        Rectangle {
          id: searchBox
          anchors { top: parent.top; left: parent.left; right: parent.right }
          height: 34
          radius: 8
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
          border.width: 1
          border.color: searchField.activeFocus
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
            : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

          Text {
            id: searchIcon
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            font.pixelSize: 13
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
          }

          TextField {
            id: searchField
            anchors.fill: parent
            anchors.leftMargin: 32
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            placeholderText: "Search artists…"
            font.pixelSize: 12
            color: Color.foreground
            placeholderTextColor: Qt.rgba(Color.foreground.r, Color.foreground.g,
                                          Color.foreground.b, 0.35)
            background: Item {}
            onTextChanged: if (root.service) root.service.search(text)
            Keys.onEscapePressed: {
              if (text !== "") { text = "" } else { root.dismiss() }
            }
            // Enter plays the top hit, so a search never needs the mouse.
            Keys.onReturnPressed: {
              var list = root.service ? root.service.searchResults : []
              if (list && list.length > 0) root.service.playArtist(list[0].key)
            }
          }
        }

        Text {
          id: listLabel
          anchors { top: searchBox.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: 14
          text: {
            if (!root.service) return ""
            if (root.service.query !== "")
              return root.service.searchResults.length + " matches"
            var n = root.service.favourites.length
            return n > 0 ? "Starred" : "No starred artists yet"
          }
          font.pixelSize: 10
          font.letterSpacing: 1.2
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.4)
        }

        ListView {
          id: list
          anchors { top: listLabel.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          model: root.service
            ? (root.service.query !== "" ? root.service.searchResults : root.service.favourites)
            : []

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            width: list.width
            height: 34
            radius: 7
            readonly property string itemKey: modelData && modelData.key ? String(modelData.key) : ""
            readonly property string itemTitle: modelData && modelData.title ? modelData.title : ""
            readonly property bool starred: root.service ? root.service.isFavourite(itemKey) : false
            readonly property bool isCurrent: root.service && root.service.playing
              && root.service.trackArtist !== ""
              && root.service.trackArtist.toLowerCase() === itemTitle.toLowerCase()

            color: rowHover.containsMouse
              ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
              : (isCurrent
                 ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
                 : "transparent")

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              onClicked: if (root.service) root.service.playArtist(itemKey)
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: star.left
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: itemTitle
              font.pixelSize: 12
              font.bold: isCurrent
              color: isCurrent ? Color.accent : Color.foreground
            }

            // The star is how the curated list gets built: search, star, done.
            Text {
              id: star
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: starred ? "󰓎" : "󰓏"
              font.pixelSize: 14
              color: starred
                ? Color.accent
                : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b,
                          starHover.containsMouse ? 0.7 : 0.25)

              MouseArea {
                id: starHover
                anchors.centerIn: parent
                width: 26
                height: 26
                hoverEnabled: true
                onClicked: if (root.service) root.service.toggleFavourite(itemKey, itemTitle)
              }
            }
          }

          // An empty starred list needs to say what to do about it.
          Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: list.count === 0 && root.service && root.service.query === ""
            text: "Search for an artist above, then tap the star to keep them here."
            font.pixelSize: 11
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
          }

          Text {
            anchors.centerIn: parent
            visible: list.count === 0 && root.service && root.service.query !== ""
              && !root.service.searching
            text: "Nothing matches that."
            font.pixelSize: 11
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
          }
        }
      }
    }

    // ---- the meter band -----------------------------------------------------

    Item {
      id: meters
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      anchors.margins: 18
      height: 92
      visible: root.service ? root.service.linked : false

      Text {
        id: metersLabel
        anchors.top: parent.top
        anchors.left: parent.left
        text: "LOW"
        font.pixelSize: 9
        font.letterSpacing: 1.4
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)
      }

      Text {
        anchors.top: parent.top
        anchors.right: parent.right
        text: "HIGH"
        font.pixelSize: 9
        font.letterSpacing: 1.4
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)
      }

      Spectrum {
        anchors { top: metersLabel.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.topMargin: 6
        levels: root.service ? root.service.levels : []
        live: root.service ? (root.service.levels && root.service.levels.length > 0) : false
      }
    }
  }

  // ---- small shared bits ---------------------------------------------------

  component IconToggle: Rectangle {
    id: toggle
    property string glyph: ""
    property string tip: ""
    property bool on: false
    property bool big: false
    signal tapped()

    width: big ? 38 : 26
    height: big ? 38 : 26
    radius: width / 2
    color: on
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
      : (hover.containsMouse
         ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
         : "transparent")
    border.width: 1
    border.color: on
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)

    Text {
      anchors.centerIn: parent
      text: toggle.glyph
      font.pixelSize: toggle.big ? 16 : 12
      color: toggle.on ? Color.accent : Color.foreground
    }

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      onClicked: toggle.tapped()
    }

    ToolTip.visible: hover.containsMouse && toggle.tip !== ""
    ToolTip.text: toggle.tip
    ToolTip.delay: 450
  }

  component TextBtn: Rectangle {
    id: btn
    property string label: ""
    property bool accent: false
    property bool enabled: true
    signal tapped()

    implicitWidth: caption.implicitWidth + 28
    implicitHeight: 32
    radius: 8
    opacity: enabled ? 1 : 0.45
    color: accent
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b,
                btnHover.containsMouse ? 0.28 : 0.18)
      : (btnHover.containsMouse
         ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
         : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06))
    border.width: 1
    border.color: accent
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.6)
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)

    Text {
      id: caption
      anchors.centerIn: parent
      text: btn.label
      font.pixelSize: 12
      color: btn.accent ? Color.accent : Color.foreground
    }

    MouseArea {
      id: btnHover
      anchors.fill: parent
      hoverEnabled: true
      enabled: btn.enabled
      onClicked: btn.tapped()
    }
  }
}
