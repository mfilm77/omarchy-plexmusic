import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The turntable. A record with the real cover on the label on the left; on the
// right a browser over the library — starred artists, everything A-Z, an
// artist's albums, an album's tracks, and your Plex playlists — with a search
// box over all of it; and the meter band along the bottom.
//
// Clicking a row opens it; the play button on the row plays it; the plus adds
// it to a Plex playlist. Playlists are the real ones on the server, so what is
// built here shows up in every other Plex app.
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
      if (service.view === "playlists") service.refreshPlaylists()
    }
    searchField.forceActiveFocus()
    // Come back to where you were, with the playing song in view.
    Qt.callLater(function () { side.revealCurrent() })
  }

  function close() {
    if (service) { service.spectrumWanted = false; service.addOpen = false }
    root.visible = false
  }

  function dismiss() {
    if (service) { service.spectrumWanted = false; service.addOpen = false }
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else root.visible = false
  }

  // Escape peels back one layer at a time: the add popup, then a search, then
  // the browse depth, and only then the panel.
  function closeStep() {
    if (!service) { dismiss(); return }
    if (service.addOpen) { service.addOpen = false; return }
    if (service.view === "settings") { service.view = "artists"; searchField.forceActiveFocus(); return }
    if (searchField.text !== "") { searchField.text = ""; return }
    if (service.view !== "artists" && service.view !== "playlists") { service.back(); return }
    dismiss()
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
  function fmtMs(ms) { return fmt((ms || 0) / 1000) }

  function dim(a) { return Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, a) }
  function acc(a) { return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, a) }

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
    Keys.onEscapePressed: root.closeStep()
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(1140, parent.width - 80)
    height: Math.min(740, parent.height - 80)
    radius: 16
    // The desktop shows through the card — it is 80% opaque — so it sits on
    // the screen rather than covering it.
    color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                   Color.popups.background.b, 0.80)
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
      z: 2

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
        color: root.dim(0.45)
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        IconToggle {
          glyph: "󰒝"
          tip: "Shuffle when playing an artist, album or playlist"
          on: root.service ? root.service.shuffle : true
          onTapped: if (root.service) root.service.shuffle = !root.service.shuffle
        }

        IconToggle {
          glyph: "󰒓"
          tip: "Settings — account, server address, library"
          on: root.service ? root.service.view === "settings" : false
          onTapped: {
            if (!root.service) return
            if (root.service.view === "settings") { root.service.view = "artists"; searchField.forceActiveFocus() }
            else { root.service.openSettings(); addressField.forceActiveFocus() }
          }
        }

        IconToggle {
          glyph: "󰑐"
          tip: "Rescan the library"
          on: root.service ? root.service.indexing : false
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
          color: root.dim(0.6)
        }

        Rectangle {
          width: parent.width
          height: 62
          radius: 10
          visible: root.service && root.service.linkCode !== ""
          color: root.acc(0.12)
          border.width: 1
          border.color: root.acc(0.5)

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
        width: parent.width * 0.40

        Vinyl {
          id: vinyl
          anchors.horizontalCenter: parent.horizontalCenter
          // The platter fills the left 80% of the turntable box (the arm has
          // the rest), so the box is shifted right by that difference to put
          // the label's centre under the centred title.
          anchors.horizontalCenterOffset: width * 0.10
          anchors.top: parent.top
          // Leave the title block real room under the record.
          width: Math.max(0, Math.min(parent.width - 20, parent.height - 185))
          height: width
          spinning: root.service ? (root.service.playing && !root.service.paused) : false
          // Paused or stopped, the arm goes back to its rest, off the record.
          engaged: root.service ? (root.service.playing && !root.service.paused) : false
          volume: root.service ? root.service.volume : 100
          art: root.service ? root.service.artPath : ""
          // The arm reads the whole side, not the track: first song at the outer
          // groove, last song by the label, creeping inward as each one plays.
          progress: {
            if (!root.service || !root.service.playing) return 0
            var within = root.service.duration > 0 ? root.service.position / root.service.duration : 0
            var n = root.service.queueCount, i = root.service.queuePos
            if (n > 0 && i > 0) return Math.max(0, Math.min(1, ((i - 1) + within) / n))
            return within
          }
        }

        // The volume fader stands beside the arm, above the timeline.
        Fader {
          anchors.right: parent.right
          anchors.rightMargin: -12
          // Top stays level with the arm rest; the extra length runs downward.
          anchors.bottom: vinyl.bottom
          anchors.bottomMargin: -50
          value: root.service ? root.service.volume : 100
          enabled: root.service ? root.service.playing : false
          onMoved: function (v) { if (root.service) root.service.setVolume(v) }
          onDraggingChanged: if (root.service) root.service.volumeDragging = dragging
        }

        Column {
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.bottomMargin: 14
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
            color: root.dim(0.55)
          }

          Item {
            width: parent.width
            height: 14
            visible: root.service && root.service.playing

            Text {
              id: elapsed
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmt(timeline.scrubbing && root.service
                ? timeline.scrubFrac * root.service.duration
                : (root.service ? root.service.position : 0))
              font.pixelSize: 10
              color: root.dim(0.45)
            }

            Text {
              id: total
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmt(root.service ? root.service.duration : 0)
              font.pixelSize: 10
              color: root.dim(0.45)
            }

            // The timeline. Click or drag anywhere on it to seek; while the
            // hand is down the bar follows the hand, not the player.
            Item {
              id: timeline
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: elapsed.right
              anchors.right: total.left
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              height: 14
              property bool scrubbing: false
              property real scrubFrac: 0
              readonly property real frac: scrubbing ? scrubFrac
                : (root.service && root.service.duration > 0
                   ? Math.min(1, root.service.position / root.service.duration) : 0)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: tlHover.hovered || timeline.scrubbing ? 5 : 3
                radius: height / 2
                color: root.dim(0.15)
                Behavior on height { NumberAnimation { duration: 80 } }
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                  width: parent.width * timeline.frac
                }
              }
              // The knob only appears when the pointer is near, or while scrubbing.
              Rectangle {
                x: timeline.width * timeline.frac - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11; height: 11; radius: 5.5
                color: Color.foreground
                border.width: 2
                border.color: Color.accent
                visible: tlHover.hovered || timeline.scrubbing
                antialiasing: true
              }
              HoverHandler { id: tlHover }
              MouseArea {
                anchors.fill: parent
                anchors.topMargin: -6
                anchors.bottomMargin: -6
                onPressed: function (m) {
                  timeline.scrubbing = true
                  timeline.scrubFrac = Math.max(0, Math.min(1, m.x / timeline.width))
                }
                onPositionChanged: function (m) {
                  if (timeline.scrubbing)
                    timeline.scrubFrac = Math.max(0, Math.min(1, m.x / timeline.width))
                }
                onReleased: function (m) {
                  if (root.service && root.service.duration > 0)
                    root.service.seek(timeline.scrubFrac * root.service.duration)
                  timeline.scrubbing = false
                }
                onCanceled: timeline.scrubbing = false
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
              glyph: root.service && root.service.playing && !root.service.paused ? "󰏤" : "󰐊"
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
                + (root.service.queueShuffled ? "  ·  shuffled" : "")
              : ""
            font.pixelSize: 10
            color: root.dim(0.35)
          }
        }
      }

      // ---- right: the browser -----------------------------------------------
      Item {
        id: side
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        width: parent.width - deck.width - 22

        readonly property string view: root.service ? root.service.view : "artists"
        readonly property bool searchingNow: root.service ? root.service.query !== "" : false
        readonly property bool showingAll: view === "artists" && !searchingNow
          && root.service && root.service.browseAll
        readonly property bool inArtists: view === "artists" && !searchingNow
        readonly property bool inSongs: view === "songs" && !searchingNow

        readonly property bool inSettings: view === "settings"

        Rectangle {
          id: searchBox
          anchors { top: parent.top; left: parent.left; right: parent.right }
          visible: !side.inSettings
          height: 34
          radius: 8
          color: root.dim(0.06)
          border.width: 1
          border.color: searchField.activeFocus ? root.acc(0.7) : root.dim(0.12)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            font.pixelSize: 13
            color: root.dim(0.45)
          }

          TextField {
            id: searchField
            anchors.fill: parent
            anchors.leftMargin: 32
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            placeholderText: "Search artists or titles…"
            font.pixelSize: 12
            color: Color.foreground
            placeholderTextColor: root.dim(0.35)
            background: Item {}
            onTextChanged: if (root.service) root.service.search(text)
            // The search field keeps focus the whole time, so the keyboard
            // drives the list from here: up/down move, Enter opens, Ctrl+Enter
            // plays, Left goes back, Ctrl+P adds to a playlist.
            Keys.onPressed: function (event) {
              var list = side.activeList
              if (!list) return
              switch (event.key) {
              case Qt.Key_Down:
                list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1)
                event.accepted = true; break
              case Qt.Key_Up:
                list.currentIndex = Math.max(0, list.currentIndex - 1)
                event.accepted = true; break
              case Qt.Key_PageDown:
                list.currentIndex = Math.min(list.count - 1, list.currentIndex + 12)
                event.accepted = true; break
              case Qt.Key_PageUp:
                list.currentIndex = Math.max(0, list.currentIndex - 12)
                event.accepted = true; break
              case Qt.Key_Return:
              case Qt.Key_Enter:
                if (event.modifiers & Qt.ControlModifier) side.playCurrent()
                else side.openCurrent()
                event.accepted = true; break
              case Qt.Key_Left:
              case Qt.Key_Backspace:
                if (searchField.text === "" && root.service) {
                  if (root.service.view !== "artists" && root.service.view !== "playlists") {
                    root.service.back(); event.accepted = true
                  }
                }
                break
              case Qt.Key_P:
                if (event.modifiers & Qt.ControlModifier) { side.addCurrent(); event.accepted = true }
                break
              case Qt.Key_Escape:
                root.closeStep(); event.accepted = true; break
              case Qt.Key_Comma:
                if (event.modifiers & Qt.ControlModifier) {
                  root.service.openSettings(); addressField.forceActiveFocus(); event.accepted = true
                }
                break
              }
            }
          }
        }

        // Which list the keyboard is steering, and what Enter does to its row.
        readonly property var activeList: {
          if (side.inSettings) return null
          if (side.searchingNow) return searchList
          if (side.inSongs) return songsList
          if (side.inArtists) return artistList
          if (side.view === "albums") return albumList
          if (side.view === "tracks") return trackList
          if (side.view === "playlists") return playlistList
          return null
        }
        // Opening an artist ends the search: the field is cleared so the albums
        // view is not hidden behind "6 matches", and Escape then means "back".
        function openArtistRow(item) {
          if (!root.service || !item) return
          if (searchField.text !== "") searchField.text = ""
          root.service.openArtist(item)
        }
        // Scroll whichever list is showing to the song that is playing and
        // put the keyboard highlight on it.
        function revealCurrent() {
          if (!root.service || !root.service.playing || !root.service.trackKey) return
          var key = root.service.trackKey
          var list = side.activeList
          if (!list || !list.model) return
          var m = list.model
          for (var i = 0; i < m.length; i++) {
            if (m[i] && String(m[i].key) === key) {
              list.currentIndex = i
              list.positionViewAtIndex(i, ListView.Center)
              return
            }
          }
        }
        function currentItem() {
          var list = side.activeList
          if (!list || list.currentIndex < 0 || !list.model) return null
          return list.model[list.currentIndex] || null
        }
        function openCurrent() {
          var item = currentItem()
          if (!root.service) return
          if (!item) {
            // Nothing highlighted while searching: Enter takes the top hit.
            if (side.searchingNow && root.service.searchItems.length > 0) item = root.service.searchItems[0]
            else return
          }
          if (side.searchingNow || side.inSongs) {
            if (item.kind === "artist") { side.openArtistRow(item); return }
            root.service.playAlbum(item.albumKey, item.key); return
          }
          if (side.inArtists) side.openArtistRow(item)
          else if (side.view === "albums") root.service.openAlbum(item)
          else if (side.view === "playlists") root.service.openPlaylist(item)
          else if (side.view === "tracks") {
            if (trackList.isPlaylist) root.service.playPlaylist(trackList.head.key, item.key)
            else root.service.playAlbum(trackList.head.key, item.key)
          }
        }
        function playCurrent() {
          var item = currentItem()
          if (!root.service) return
          if (!item) {
            if (side.searchingNow && root.service.searchItems.length > 0) item = root.service.searchItems[0]
            else return
          }
          if (side.searchingNow || side.inSongs) {
            if (item.kind === "artist") root.service.playArtist(item.key)
            else root.service.playAlbum(item.albumKey, item.key)
            return
          }
          if (side.inArtists) root.service.playArtist(item.key)
          else if (side.view === "albums") root.service.playAlbum(item.key, "")
          else if (side.view === "playlists") root.service.playPlaylist(item.key, "")
          else if (side.view === "tracks") {
            if (trackList.isPlaylist) root.service.playPlaylist(trackList.head.key, item.key)
            else root.service.playAlbum(trackList.head.key, item.key)
          }
        }
        function addCurrent() {
          var item = currentItem()
          if (!root.service) return
          if (side.view === "tracks") {
            root.service.requestAdd(item ? [item.key] : trackList.allKeys())
          } else if (side.view === "albums" && item) {
            root.service.requestAddAlbum(item.key)
          } else if ((side.searchingNow || side.inSongs) && item && item.kind !== "artist") {
            root.service.requestAdd([item.key])
          }
        }

        // ---- nav: tabs at the top level, a breadcrumb once drilled in --------
        Item {
          id: nav
          anchors { top: searchBox.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: 12
          height: 24
          visible: !side.inSettings

          Row {
            spacing: 6
            visible: !side.searchingNow && (side.view === "artists" || side.view === "playlists" || side.view === "songs")

            ModeTab {
              label: "Starred" + (root.service && root.service.favourites.length > 0
                ? "  " + root.service.favourites.length : "")
              on: side.view === "artists" && root.service && !root.service.browseAll
              onTapped: if (root.service) root.service.showTab("starred")
            }
            ModeTab {
              label: "All artists" + (root.service ? "  " + root.service.artistCount : "")
              on: side.showingAll
              onTapped: if (root.service) root.service.showTab("all")
            }
            ModeTab {
              label: "Songs" + (root.service && root.service.trackCount > 0 ? "  " + root.service.trackCount : "")
              on: side.view === "songs"
              onTapped: if (root.service) root.service.showTab("songs")
            }
            ModeTab {
              label: "Playlists" + (root.service && root.service.playlists.length > 0
                ? "  " + root.service.playlists.length : "")
              on: side.view === "playlists"
              onTapped: if (root.service) root.service.showTab("playlists")
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: side.searchingNow
            text: root.service ? (root.service.searchResults.length + " artists  ·  " + root.service.trackResults.length + " songs") : ""
            font.pixelSize: 10
            font.letterSpacing: 1.2
            color: root.dim(0.4)
          }

          Row {
            spacing: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: !side.searchingNow && (side.view === "albums" || side.view === "tracks")

            RowBtn {
              glyph: "󰁍"
              tip: "Back"
              onTapped: if (root.service) root.service.back()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (!root.service) return ""
                var parts = []
                if (root.service.selectedPlaylist && side.view === "tracks") {
                  parts.push("Playlists")
                  parts.push(root.service.selectedPlaylist.title)
                } else {
                  parts.push(root.service.selectedArtist ? root.service.selectedArtist.title : "Artist")
                  if (side.view === "tracks" && root.service.selectedAlbum)
                    parts.push(root.service.selectedAlbum.title)
                }
                return parts.join("   ›   ")
              }
              font.pixelSize: 12
              font.bold: true
              elide: Text.ElideMiddle
              width: Math.min(implicitWidth, side.width - 60)
              color: Color.foreground
            }
          }
        }

        // ---- the A-Z strip (full artist list only) --------------------------
        Column {
          id: alphabet
          anchors { top: nav.bottom; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          width: 16
          visible: side.showingAll || side.inSongs
          readonly property var letters: ["#","A","B","C","D","E","F","G","H","I","J","K","L","M",
                                          "N","O","P","Q","R","S","T","U","V","W","X","Y","Z"]
          readonly property real slot: Math.max(1, height / letters.length)

          Repeater {
            model: alphabet.letters
            delegate: Item {
              width: alphabet.width
              height: alphabet.slot
              readonly property bool present: root.service
                && ((side.inSongs ? root.service.trackLetterIndex : root.service.letterIndex)[modelData] !== undefined)

              Text {
                anchors.centerIn: parent
                text: modelData
                font.pixelSize: Math.min(10, alphabet.slot * 0.8)
                font.bold: jump.containsMouse
                color: jump.containsMouse ? Color.accent : root.dim(present ? 0.5 : 0.15)
              }

              MouseArea {
                id: jump
                anchors.fill: parent
                hoverEnabled: true
                enabled: present
                onClicked: {
                  if (side.inSongs) {
                    var j = root.service.trackLetterIndex[modelData]
                    if (j !== undefined) songsList.positionViewAtIndex(j, ListView.Beginning)
                  } else {
                    var i = root.service.letterIndex[modelData]
                    if (i !== undefined) artistList.positionViewAtIndex(i, ListView.Beginning)
                  }
                }
              }
            }
          }
        }

        // ---- artists ---------------------------------------------------------
        ListView {
          id: artistList
          currentIndex: -1
          highlightFollowsCurrentItem: true
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          anchors { top: nav.bottom; left: parent.left; bottom: parent.bottom }
          anchors.topMargin: 8
          anchors.right: side.showingAll ? alphabet.left : parent.right
          anchors.rightMargin: side.showingAll ? 6 : 0
          visible: side.inArtists
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          cacheBuffer: 400
          model: {
            if (!root.service) return []
            return root.service.browseAll ? root.service.artists : root.service.favourites
          }

          section.property: side.showingAll ? "letter" : ""
          section.criteria: ViewSection.FullString
          section.labelPositioning: ViewSection.InlineLabels | ViewSection.CurrentLabelAtStart
          section.delegate: Item {
            width: artistList.width
            height: 26
            Rectangle { anchors.fill: parent; color: Color.popups.background }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: section
              font.pixelSize: 11
              font.bold: true
              font.letterSpacing: 1.5
              color: Color.accent
            }
            Rectangle {
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              anchors.leftMargin: 10
              height: 1
              color: root.acc(0.25)
            }
          }

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            width: artistList.width
            height: 34
            radius: 7
            readonly property string itemKey: modelData && modelData.key ? String(modelData.key) : ""
            readonly property string itemTitle: modelData && modelData.title ? modelData.title : ""
            readonly property bool starred: root.service ? root.service.isFavourite(itemKey) : false
            readonly property bool isCurrent: root.service && root.service.playing
              && root.service.trackArtist !== ""
              && root.service.trackArtist.toLowerCase() === itemTitle.toLowerCase()

            color: rowHoverH.hovered ? root.dim(0.08)
                 : (isCurrent ? root.acc(0.12) : "transparent")

            HoverHandler { id: rowHoverH }
            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              onClicked: side.openArtistRow({ key: itemKey, title: itemTitle })
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: actions.left
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: itemTitle
              font.pixelSize: 12
              font.bold: isCurrent
              color: isCurrent ? Color.accent : Color.foreground
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              RowBtn {
                glyph: "󰐊"
                tip: "Play " + itemTitle
                strong: true
                visible: rowHoverH.hovered || isCurrent
                onTapped: if (root.service) root.service.playArtist(itemKey)
              }

              // The star is how the curated list gets built: search, star, done.
              RowBtn {
                glyph: starred ? "★" : "☆"
                tip: starred ? "Remove from starred" : "Star this artist"
                accentOn: starred
                onTapped: if (root.service) root.service.toggleFavourite(itemKey, itemTitle)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: artistList.count === 0 && !side.searchingNow && root.service && !root.service.browseAll
            text: "Tap the star on any artist to keep them here."
            font.pixelSize: 11
            color: root.dim(0.35)
          }

          Text {
            anchors.centerIn: parent
            visible: artistList.count === 0 && side.showingAll
            text: root.service && root.service.indexing ? "Indexing the library…"
                                                        : "No index yet — press the rescan button above."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // ---- search results: artists then songs -------------------------------
        ListView {
          id: searchList
          anchors { top: nav.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          visible: side.searchingNow && !side.inSettings
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          cacheBuffer: 400
          currentIndex: -1
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          model: root.service ? root.service.searchItems : []
          section.property: "kind"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            width: searchList.width
            height: 24
            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: section === "artist" ? "ARTISTS" : "SONGS"
              font.pixelSize: 10
              font.letterSpacing: 1.6
              color: root.dim(0.4)
            }
          }
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Item {
            width: searchList.width
            height: modelData && modelData.kind === "artist" ? 34 : 38
            readonly property var item: modelData

            // artist row
            Rectangle {
              anchors.fill: parent
              visible: item && item.kind === "artist"
              radius: 7
              readonly property bool starred: root.service && item ? root.service.isFavourite(item.key) : false
              color: aH.hovered ? root.dim(0.08) : "transparent"
              HoverHandler { id: aH }
              MouseArea { anchors.fill: parent; onClicked: side.openArtistRow(item) }
              Text {
                anchors.left: parent.left; anchors.leftMargin: 10
                anchors.right: aActs.left; anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: item ? item.title : ""
                font.pixelSize: 12
                color: Color.foreground
              }
              Row {
                id: aActs
                anchors.right: parent.right; anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                RowBtn { glyph: "󰐊"; tip: "Play this artist"; strong: true; visible: aH.hovered
                         onTapped: if (root.service) root.service.playArtist(item.key) }
                RowBtn { glyph: parent.parent.starred ? "★" : "☆"; tip: "Star"; accentOn: parent.parent.starred
                         onTapped: if (root.service) root.service.toggleFavourite(item.key, item.title) }
              }
            }

            TrackRow {
              anchors.fill: parent
              visible: item && item.kind === "track"
              track: item
            }
          }

          Text {
            anchors.centerIn: parent
            visible: searchList.count === 0
            text: "Nothing matches that."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // ---- every song, A-Z ---------------------------------------------------
        ListView {
          id: songsList
          anchors { top: nav.bottom; left: parent.left; bottom: parent.bottom }
          anchors.topMargin: 8
          anchors.right: alphabet.left
          anchors.rightMargin: 6
          visible: side.inSongs
          clip: true
          spacing: 1
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          cacheBuffer: 600
          currentIndex: -1
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          model: root.service ? root.service.allTracks : []
          section.property: "letter"
          section.criteria: ViewSection.FullString
          section.labelPositioning: ViewSection.InlineLabels | ViewSection.CurrentLabelAtStart
          section.delegate: Item {
            width: songsList.width
            height: 26
            Rectangle { anchors.fill: parent; color: Color.popups.background }
            Text {
              anchors.left: parent.left; anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: section
              font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.5
              color: Color.accent
            }
            Rectangle {
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              anchors.leftMargin: 10
              height: 1
              color: root.acc(0.25)
            }
          }
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: TrackRow { width: songsList.width; height: 38; track: modelData }

          Text {
            anchors.centerIn: parent
            visible: songsList.count === 0
            text: root.service && root.service.indexing ? "Indexing the library…" : "No song index yet — press the rescan button above."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // ---- albums of an artist ---------------------------------------------
        ListView {
          id: albumList
          currentIndex: -1
          highlightFollowsCurrentItem: true
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          anchors { top: nav.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          visible: !side.searchingNow && side.view === "albums"
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          model: root.service ? root.service.albums : []
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          header: Item {
            width: albumList.width
            height: 44
            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              TextBtn {
                label: "󰐊  Play all"
                accent: true
                onTapped: if (root.service && root.service.selectedArtist)
                  root.service.playArtist(root.service.selectedArtist.key)
              }
              RowBtn {
                glyph: "★"
                tip: "Star this artist"
                accentOn: root.service && root.service.selectedArtist
                  && root.service.isFavourite(root.service.selectedArtist.key)
                onTapped: if (root.service && root.service.selectedArtist)
                  root.service.toggleFavourite(root.service.selectedArtist.key,
                                               root.service.selectedArtist.title)
              }
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.service
                ? (root.service.loadingAlbums ? "loading…"
                   : root.service.albums.length + (root.service.albums.length === 1 ? " album" : " albums"))
                : ""
              font.pixelSize: 10
              font.letterSpacing: 1.2
              color: root.dim(0.4)
            }
          }

          delegate: Rectangle {
            width: albumList.width
            height: 52
            radius: 8
            readonly property var album: modelData
            color: albumHoverH.hovered ? root.dim(0.08) : "transparent"

            HoverHandler { id: albumHoverH }
            MouseArea {
              id: albumHover
              anchors.fill: parent
              hoverEnabled: true
              onClicked: if (root.service) root.service.openAlbum(album)
            }

            CoverThumb {
              id: albumArt
              anchors.left: parent.left
              anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              size: 40
              source: album && album.artUrl ? album.artUrl : ""
            }

            Column {
              anchors.left: albumArt.right
              anchors.leftMargin: 10
              anchors.right: albumActions.left
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: album ? album.title : ""
                font.pixelSize: 12
                font.bold: true
                color: Color.foreground
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: album
                  ? [album.year ? String(album.year) : "",
                     album.tracks ? album.tracks + " tracks" : ""].filter(Boolean).join("  ·  ")
                  : ""
                font.pixelSize: 10
                color: root.dim(0.5)
              }
            }

            Row {
              id: albumActions
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              visible: albumHoverH.hovered
              RowBtn {
                glyph: "󰐊"; tip: "Play this album"; strong: true
                onTapped: if (root.service) root.service.playAlbum(album.key, "")
              }
              RowBtn {
                glyph: "󰐕"; tip: "Add this album to a playlist"
                onTapped: if (root.service) root.service.requestAddAlbum(album.key)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: albumList.count === 0 && root.service && !root.service.loadingAlbums
            text: "No albums here."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // ---- tracks of an album or playlist ----------------------------------
        ListView {
          id: trackList
          currentIndex: -1
          highlightFollowsCurrentItem: true
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          anchors { top: nav.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          visible: !side.searchingNow && side.view === "tracks"
          clip: true
          spacing: 1
          boundsBehavior: Flickable.StopAtBounds
          model: root.service ? root.service.tracks : []
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          readonly property bool isPlaylist: root.service && root.service.selectedPlaylist !== null
          readonly property var head: root.service
            ? (isPlaylist ? root.service.selectedPlaylist : root.service.selectedAlbum) : null

          function allKeys() {
            var t = root.service ? root.service.tracks : []
            var out = []
            for (var i = 0; i < t.length; i++) out.push(t[i].key)
            return out
          }

          header: Item {
            width: trackList.width
            height: 96

            CoverThumb {
              id: headArt
              anchors.left: parent.left
              anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              size: 72
              source: trackList.head && trackList.head.artUrl ? trackList.head.artUrl : ""
            }

            Column {
              anchors.left: headArt.right
              anchors.leftMargin: 12
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: trackList.head ? trackList.head.title : ""
                font.pixelSize: 14
                font.bold: true
                color: Color.foreground
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: {
                  if (!root.service) return ""
                  var n = root.service.tracks.length
                  var bits = []
                  if (!trackList.isPlaylist && root.service.selectedArtist)
                    bits.push(root.service.selectedArtist.title)
                  if (trackList.head && trackList.head.year) bits.push(String(trackList.head.year))
                  bits.push(root.service.loadingTracks ? "loading…" : n + (n === 1 ? " track" : " tracks"))
                  return bits.join("  ·  ")
                }
                font.pixelSize: 11
                color: root.dim(0.5)
              }
              Row {
                spacing: 6
                TextBtn {
                  label: "󰐊  Play"
                  accent: true
                  onTapped: {
                    if (!root.service || !trackList.head) return
                    if (trackList.isPlaylist) root.service.playPlaylist(trackList.head.key, "")
                    else root.service.playAlbum(trackList.head.key, "")
                  }
                }
                TextBtn {
                  label: "󰐕  Add all to playlist"
                  onTapped: if (root.service) root.service.requestAdd(trackList.allKeys())
                }
              }
            }
          }

          delegate: Rectangle {
            width: trackList.width
            height: 32
            radius: 6
            readonly property var track: modelData
            readonly property bool isCurrent: root.service && root.service.playing && track
              && (root.service.trackKey ? String(track.key) === root.service.trackKey
                  : (root.service.trackTitle === track.title))
            color: trackHoverH.hovered ? root.dim(0.08) : (isCurrent ? root.acc(0.12) : "transparent")

            HoverHandler { id: trackHoverH }
            MouseArea {
              id: trackHover
              anchors.fill: parent
              hoverEnabled: true
              // Clicking a track plays the album or playlist from that track on.
              onClicked: {
                if (!root.service || !trackList.head) return
                if (trackList.isPlaylist) root.service.playPlaylist(trackList.head.key, track.key)
                else root.service.playAlbum(trackList.head.key, track.key)
              }
            }

            Text {
              id: num
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              width: 22
              horizontalAlignment: Text.AlignRight
              text: track ? (trackList.isPlaylist ? String(index + 1) : String(track.index || index + 1)) : ""
              font.pixelSize: 10
              color: isCurrent ? Color.accent : root.dim(0.4)
            }

            Text {
              anchors.left: num.right
              anchors.leftMargin: 10
              anchors.right: dur.left
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: track
                ? (trackList.isPlaylist && track.artist ? track.title + "  —  " + track.artist : track.title)
                : ""
              font.pixelSize: 12
              font.bold: isCurrent
              color: isCurrent ? Color.accent : Color.foreground
            }

            Text {
              id: dur
              anchors.right: trackActions.left
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              text: track ? root.fmtMs(track.duration) : ""
              font.pixelSize: 10
              color: root.dim(0.4)
              visible: !trackHoverH.hovered
            }

            Row {
              id: trackActions
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              width: trackHoverH.hovered ? implicitWidth : 0
              clip: true
              RowBtn {
                glyph: "󰐊"; tip: "Play from here"; strong: true
                visible: trackHoverH.hovered
                onTapped: {
                  if (!root.service || !trackList.head) return
                  if (trackList.isPlaylist) root.service.playPlaylist(trackList.head.key, track.key)
                  else root.service.playAlbum(trackList.head.key, track.key)
                }
              }
              RowBtn {
                glyph: "󰐕"; tip: "Add to a playlist"
                visible: trackHoverH.hovered
                onTapped: if (root.service) root.service.requestAdd([track.key])
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: trackList.count === 0 && root.service && !root.service.loadingTracks
            text: "No tracks here."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // ---- playlists ---------------------------------------------------------
        ListView {
          id: playlistList
          currentIndex: -1
          highlightFollowsCurrentItem: true
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            z: -1
          }
          onModelChanged: currentIndex = -1
          anchors { top: nav.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.topMargin: 8
          visible: !side.searchingNow && side.view === "playlists"
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          model: root.service ? root.service.playlists : []
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          header: Item {
            width: playlistList.width
            height: 30
            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: "Your Plex playlists. Use the  󰐕  on any track or album to add to one, or to start a new one."
              font.pixelSize: 10
              color: root.dim(0.4)
              width: parent.width - 20
              elide: Text.ElideRight
            }
          }

          delegate: Rectangle {
            width: playlistList.width
            height: 48
            radius: 8
            readonly property var pl: modelData
            color: plHoverH.hovered ? root.dim(0.08) : "transparent"

            HoverHandler { id: plHoverH }
            MouseArea {
              id: plHover
              anchors.fill: parent
              hoverEnabled: true
              onClicked: if (root.service) root.service.openPlaylist(pl)
            }

            CoverThumb {
              id: plArt
              anchors.left: parent.left
              anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              size: 36
              source: pl && pl.artUrl ? pl.artUrl : ""
              fallbackGlyph: "󰲸"
            }

            Column {
              anchors.left: plArt.right
              anchors.leftMargin: 10
              anchors.right: plActions.left
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: pl ? pl.title : ""
                font.pixelSize: 12
                font.bold: true
                color: Color.foreground
              }
              Text {
                width: parent.width
                text: pl ? pl.tracks + (pl.tracks === 1 ? " track" : " tracks")
                           + (pl.duration ? "  ·  " + root.fmtMs(pl.duration) : "") : ""
                font.pixelSize: 10
                color: root.dim(0.5)
              }
            }

            Row {
              id: plActions
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              visible: plHoverH.hovered
              RowBtn {
                glyph: "󰐊"; tip: "Play this playlist"; strong: true
                onTapped: if (root.service) root.service.playPlaylist(pl.key, "")
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: playlistList.count === 0 && root.service && !root.service.loadingPlaylists
            text: "No playlists yet — add a track to start one."
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }
      }
    }

    // ---- settings ------------------------------------------------------------
    //
    // Everything a stranger needs to get the plugin talking to their own Plex,
    // with or without a VPN: who is linked, which address to use (the ones
    // plex.tv reports, plus any they type), and which music library.

    Flickable {
      id: settingsPane
      anchors { top: header.bottom; right: parent.right; bottom: meters.top }
      anchors.margins: 18
      anchors.topMargin: 18
      width: body.width - deck.width - 22
      visible: root.service ? (root.service.linked && root.service.view === "settings") : false
      contentHeight: settingsCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      property bool confirmUnlink: false
      onVisibleChanged: confirmUnlink = false

      Column {
        id: settingsCol
        width: settingsPane.width
        spacing: 18

        // -- account
        Column {
          width: parent.width
          spacing: 8
          Text { text: "ACCOUNT"; font.pixelSize: 10; font.letterSpacing: 1.6; color: root.dim(0.4) }
          Row {
            spacing: 10
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var a = root.service ? root.service.account : {}
                if (!a || !a.username) return "Linked to Plex"
                return a.valid === false
                  ? "Linked as " + a.username + " — Plex no longer accepts the token; unlink and link again"
                  : "Linked as " + a.username
              }
              font.pixelSize: 12
              color: Color.foreground
            }
            TextBtn {
              label: settingsPane.confirmUnlink ? "Really unlink — wipes the token and index" : "Unlink…"
              accent: settingsPane.confirmUnlink
              enabled: root.service ? !root.service.settingsBusy : false
              onTapped: {
                if (!settingsPane.confirmUnlink) { settingsPane.confirmUnlink = true; return }
                if (root.service) root.service.unlink()
              }
            }
          }
        }

        // -- server
        Column {
          width: parent.width
          spacing: 8
          Text { text: "SERVER"; font.pixelSize: 10; font.letterSpacing: 1.6; color: root.dim(0.4) }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Addresses plex.tv reports for your account, local ones first, Plex's relay last. "
                  + "Click one to use it. If your server is somewhere Plex cannot see — a VPN such as "
                  + "Tailscale, a reverse proxy, a LAN name — add the address yourself; typed addresses "
                  + "are tried before anything else."
            font.pixelSize: 11
            color: root.dim(0.55)
          }

          Repeater {
            model: root.service ? root.service.servers : []
            delegate: Rectangle {
              width: settingsCol.width
              height: 36
              radius: 7
              readonly property var srv: modelData
              readonly property bool active: root.service && srv && root.service.server === srv.uri
              // Dead addresses stay listed (they are what plex.tv claims) but
              // recede, so the ones that answer are what the eye lands on.
              opacity: (srv && srv.reachable) || active ? 1 : 0.5
              color: active ? root.acc(0.12) : (srvH.hovered ? root.dim(0.08) : "transparent")
              border.width: active ? 1 : 0
              border.color: root.acc(0.5)
              HoverHandler { id: srvH }
              MouseArea {
                anchors.fill: parent
                enabled: root.service ? !root.service.settingsBusy : false
                onClicked: if (root.service && srv) root.service.useServer(srv.uri)
              }
              Rectangle {
                id: dot
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: srv && srv.reachable ? Color.accent : Color.urgent
                opacity: srv && srv.reachable ? 1 : 0.7
              }
              Text {
                anchors.left: dot.right
                anchors.leftMargin: 10
                anchors.right: srvMeta.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideMiddle
                text: (srv && srv.uri) ? String(srv.uri) : ""
                font.pixelSize: 12
                color: active ? Color.accent : Color.foreground
              }
              Row {
                id: srvMeta
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    if (!srv) return ""
                    var bits = []
                    if (srv.source === "manual") bits.push("yours")
                    else if (srv.relay) bits.push("relay")
                    else if (srv.local) bits.push("local")
                    else bits.push("remote")
                    if (srv.ms !== null && srv.ms !== undefined) bits.push(srv.ms + " ms")
                    else bits.push("no answer")
                    if (active) bits.push("in use")
                    return bits.join("  ·  ")
                  }
                  font.pixelSize: 10
                  color: root.dim(0.45)
                }
                RowBtn {
                  glyph: "󰅖"
                  tip: "Forget this address"
                  visible: srv && srv.source === "manual"
                  onTapped: if (root.service && srv) root.service.removeServer(srv.uri)
                }
              }
            }
          }

          Text {
            visible: root.service && root.service.loadingServers && root.service.servers.length === 0
            text: "Looking for servers…"
            font.pixelSize: 11
            color: root.dim(0.4)
          }

          Item {
            width: parent.width
            height: 36
            Rectangle {
              anchors { left: parent.left; right: addBtn.left; top: parent.top; bottom: parent.bottom }
              anchors.rightMargin: 8
              radius: 8
              color: root.dim(0.06)
              border.width: 1
              border.color: addressField.activeFocus ? root.acc(0.7) : root.dim(0.12)
              TextField {
                id: addressField
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 6
                verticalAlignment: TextInput.AlignVCenter
                placeholderText: "http://plex.local:32400   or   http://10.0.0.5:32400   or   https://plex.example.com"
                font.pixelSize: 12
                color: Color.foreground
                placeholderTextColor: root.dim(0.3)
                background: Item {}
                Keys.onReturnPressed: if (root.service && text.trim() !== "") { root.service.useServer(text.trim()); text = "" }
                Keys.onEscapePressed: root.closeStep()
              }
            }
            TextBtn {
              id: addBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: "Add and use"
              accent: true
              enabled: addressField.text.trim() !== "" && root.service && !root.service.settingsBusy
              onTapped: if (root.service) { root.service.useServer(addressField.text.trim()); addressField.text = "" }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.service && root.service.settingsNote !== ""
            text: root.service ? root.service.settingsNote : ""
            font.pixelSize: 11
            color: Color.accent
          }
        }

        // -- library
        Column {
          width: parent.width
          spacing: 8
          visible: root.service && root.service.sections.length > 1
          Text { text: "MUSIC LIBRARY"; font.pixelSize: 10; font.letterSpacing: 1.6; color: root.dim(0.4) }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This server has more than one music library. Pick the one to browse; the index is rebuilt when you switch."
            font.pixelSize: 11
            color: root.dim(0.55)
          }
          Repeater {
            model: root.service ? root.service.sections : []
            delegate: Rectangle {
              width: settingsCol.width
              height: 32
              radius: 7
              readonly property var sec: modelData
              color: sec && sec.active ? root.acc(0.12) : (secH.hovered ? root.dim(0.08) : "transparent")
              border.width: sec && sec.active ? 1 : 0
              border.color: root.acc(0.5)
              HoverHandler { id: secH }
              MouseArea {
                anchors.fill: parent
                enabled: root.service ? !root.service.settingsBusy : false
                onClicked: if (root.service && sec && !sec.active) root.service.useSection(sec.key)
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: sec ? sec.title : ""
                font.pixelSize: 12
                color: sec && sec.active ? Color.accent : Color.foreground
              }
              Text {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                visible: sec && sec.active
                text: "in use"
                font.pixelSize: 10
                color: root.dim(0.45)
              }
            }
          }
        }

        // -- index
        Column {
          width: parent.width
          spacing: 8
          Text { text: "INDEX"; font.pixelSize: 10; font.letterSpacing: 1.6; color: root.dim(0.4) }
          Row {
            spacing: 10
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.service
                ? (root.service.indexing ? "Indexing…"
                   : root.service.artistCount + " artists indexed. Rescan after adding music to Plex.")
                : ""
              font.pixelSize: 12
              color: Color.foreground
            }
            TextBtn {
              label: "Rescan"
              enabled: root.service ? !root.service.indexing : false
              onTapped: if (root.service) root.service.reindex()
            }
          }
        }

        // -- shortcuts
        Column {
          width: parent.width
          spacing: 8
          Text { text: "KEYBOARD"; font.pixelSize: 10; font.letterSpacing: 1.6; color: root.dim(0.4) }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Type to search  ·  ↑ ↓ move  ·  Enter open  ·  Ctrl+Enter play  ·  ← back  ·  "
                  + "Ctrl+P add to playlist  ·  Ctrl+, settings  ·  Esc back / close. "
                  + "Middle-click the bar widget to pause."
            font.pixelSize: 11
            color: root.dim(0.55)
          }
        }
      }
    }

    // ---- the meter band -----------------------------------------------------

    Item {
      id: meters
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      anchors.margins: 18
      height: 132
      visible: root.service ? root.service.linked : false

      Text {
        id: metersLabel
        anchors.top: parent.top
        anchors.left: parent.left
        text: "LOW"
        font.pixelSize: 9
        font.letterSpacing: 1.4
        color: root.dim(0.3)
      }

      Text {
        anchors.top: parent.top
        anchors.right: parent.right
        text: "HIGH"
        font.pixelSize: 9
        font.letterSpacing: 1.4
        color: root.dim(0.3)
      }

      Spectrum {
        anchors { top: metersLabel.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.topMargin: 6
        levels: root.service ? root.service.levels : []
        live: root.service ? (root.service.levels && root.service.levels.length > 0) : false
      }
    }

    // ---- toast ----------------------------------------------------------------

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: meters.top
      anchors.bottomMargin: 8
      visible: root.service && root.service.toast !== ""
      width: toastText.implicitWidth + 28
      height: 30
      radius: 15
      color: root.acc(0.18)
      border.width: 1
      border.color: root.acc(0.55)
      Text {
        id: toastText
        anchors.centerIn: parent
        text: root.service ? root.service.toast : ""
        font.pixelSize: 11
        color: Color.foreground
      }
    }

    // ---- add to playlist --------------------------------------------------------

    Item {
      id: addLayer
      anchors.fill: parent
      visible: root.service ? root.service.addOpen : false
      // When the popup closes, the keyboard must come back to the search
      // field, or the arrows keep going to a name field nobody can see.
      onVisibleChanged: if (!visible && root.visible) searchField.forceActiveFocus()

      MouseArea {
        anchors.fill: parent
        onClicked: if (root.service) root.service.addOpen = false
      }
      Rectangle { anchors.fill: parent; radius: card.radius; color: Qt.rgba(0, 0, 0, 0.45) }

      Rectangle {
        id: addPopup
        anchors.centerIn: parent
        width: 380
        height: Math.min(460, card.height - 80)
        radius: 12
        color: Color.popups.background
        border.width: 1
        border.color: root.acc(0.6)
        MouseArea { anchors.fill: parent }

        onVisibleChanged: if (visible) { newName.text = ""; newName.forceActiveFocus() }

        Text {
          id: addTitle
          anchors { top: parent.top; left: parent.left; right: parent.right }
          anchors.margins: 16
          text: {
            var n = root.service ? root.service.pendingAdd.length : 0
            return "Add " + n + (n === 1 ? " track" : " tracks") + " to…"
          }
          font.pixelSize: 14
          font.bold: true
          color: Color.foreground
        }

        ListView {
          id: addList
          currentIndex: -1
          highlightMoveDuration: 80
          highlight: Rectangle {
            radius: 7
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
            z: -1
          }
          onModelChanged: currentIndex = -1
          anchors { top: addTitle.bottom; left: parent.left; right: parent.right; bottom: newRow.top }
          anchors.margins: 10
          anchors.topMargin: 12
          clip: true
          spacing: 2
          model: root.service ? root.service.playlists : []
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            width: addList.width
            height: 36
            radius: 7
            color: addHoverH.hovered ? root.acc(0.14) : "transparent"
            HoverHandler { id: addHoverH }
            MouseArea {
              id: addHover
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.service ? !root.service.addBusy : false
              onClicked: if (root.service) root.service.addToPlaylist(modelData.key)
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: cnt.left
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: modelData ? modelData.title : ""
              font.pixelSize: 12
              color: Color.foreground
            }
            Text {
              id: cnt
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: modelData ? modelData.tracks : ""
              font.pixelSize: 10
              color: root.dim(0.4)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: addList.count === 0
            text: root.service && root.service.loadingPlaylists ? "loading…" : "No playlists yet"
            font.pixelSize: 11
            color: root.dim(0.35)
          }
        }

        // A new playlist is made from the pending tracks, so it is never empty.
        Item {
          id: newRow
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.margins: 12
          height: 40

          Rectangle {
            anchors { left: parent.left; right: createBtn.left; top: parent.top; bottom: parent.bottom }
            anchors.rightMargin: 8
            radius: 8
            color: root.dim(0.06)
            border.width: 1
            border.color: newName.activeFocus ? root.acc(0.7) : root.dim(0.12)
            TextField {
              id: newName
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 6
              verticalAlignment: TextInput.AlignVCenter
              placeholderText: "New playlist name…"
              font.pixelSize: 12
              color: Color.foreground
              placeholderTextColor: root.dim(0.35)
              background: Item {}
              // Arrows pick an existing playlist, Enter adds to it; with
              // nothing picked, Enter creates the named one.
              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Down) {
                  addList.currentIndex = Math.min(addList.count - 1, addList.currentIndex + 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  addList.currentIndex = Math.max(-1, addList.currentIndex - 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (!root.service) return
                  if (addList.currentIndex >= 0 && addList.model[addList.currentIndex])
                    root.service.addToPlaylist(addList.model[addList.currentIndex].key)
                  else root.service.createPlaylist(text)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.closeStep(); event.accepted = true
                }
              }
            }
          }

          TextBtn {
            id: createBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            label: root.service && root.service.addBusy ? "…" : "Create"
            accent: true
            enabled: newName.text.trim() !== "" && root.service && !root.service.addBusy
            onTapped: if (root.service) root.service.createPlaylist(newName.text)
          }
        }
      }
    }
  }

  // ---- small shared bits ---------------------------------------------------

  // A mixing-desk fader: a recessed slot, a brushed-metal cap with an index
  // line riding it, scale ticks, and the lit run below the cap. Small — it is
  // a volume control, not a feature.
  component Fader: Item {
    id: fader
    property real value: 100          // 0-100
    property bool dragging: false
    signal moved(real v)

    width: 30
    height: 168
    opacity: enabled ? 1 : 0.45

    readonly property real capH: 14
    readonly property real padTop: 6
    readonly property real travel: height - 30
    readonly property real frac: Math.max(0, Math.min(100, value)) / 100
    readonly property real capY: padTop + travel * (1 - frac)
    readonly property color metal: Qt.rgba(Color.foreground.r * 0.85 + 0.10,
                                           Color.foreground.g * 0.85 + 0.10,
                                           Color.foreground.b * 0.85 + 0.10, 1)

    // Scale: ticks at every 10, longer at 0/50/100, "dB"-style.
    Repeater {
      model: 11
      Rectangle {
        x: fader.width / 2 + 8
        y: fader.padTop + fader.capH / 2 + fader.travel * (index / 10) - 0.5
        width: index % 5 === 0 ? 6 : 3
        height: 1
        color: root.dim(index % 5 === 0 ? 0.45 : 0.22)
      }
    }

    // The slot: recessed, with the lit run from the bottom up to the cap.
    Rectangle {
      id: slot
      anchors.horizontalCenter: parent.horizontalCenter
      y: fader.padTop + fader.capH / 2
      width: 5
      height: fader.travel
      radius: 2.5
      color: Qt.rgba(0, 0, 0, 0.55)
      border.width: 1
      border.color: root.dim(0.14)
      Rectangle {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 1
        anchors.horizontalCenter: parent.horizontalCenter
        width: 2
        height: Math.max(0, (parent.height - 2) * fader.frac)
        radius: 1
        color: Color.accent
        opacity: 0.85
      }
    }

    // Cap shadow.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      y: fader.capY + 2
      width: 20; height: fader.capH; radius: 3
      color: Qt.rgba(0, 0, 0, 0.45)
    }
    // The cap.
    Rectangle {
      id: cap
      anchors.horizontalCenter: parent.horizontalCenter
      y: fader.capY
      width: 20
      height: fader.capH
      radius: 3
      antialiasing: true
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.lighter(fader.metal, 1.25) }
        GradientStop { position: 0.5; color: fader.metal }
        GradientStop { position: 1.0; color: Qt.darker(fader.metal, 1.9) }
      }
      border.width: 1
      border.color: fader.dragging || fHover.hovered ? Color.accent : Qt.rgba(0, 0, 0, 0.7)
      // Grip lines either side of the accent index.
      Rectangle { anchors.centerIn: parent; anchors.verticalCenterOffset: -3; width: parent.width - 6; height: 1; color: Qt.rgba(0, 0, 0, 0.35) }
      Rectangle { anchors.centerIn: parent; width: parent.width - 4; height: 2; color: Color.accent }
      Rectangle { anchors.centerIn: parent; anchors.verticalCenterOffset: 3; width: parent.width - 6; height: 1; color: Qt.rgba(0, 0, 0, 0.35) }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      text: fader.dragging || fHover.hovered ? Math.round(fader.value) : "VOL"
      font.pixelSize: 8
      font.letterSpacing: 1
      color: fader.dragging ? Color.accent : root.dim(0.45)
    }

    HoverHandler { id: fHover }
    MouseArea {
      anchors.fill: parent
      anchors.leftMargin: -6
      anchors.rightMargin: -6
      enabled: fader.enabled
      function setFromY(y) {
        var v = 100 * (1 - (y - fader.padTop - fader.capH / 2) / fader.travel)
        fader.moved(Math.max(0, Math.min(100, v)))
      }
      onPressed: function (m) { fader.dragging = true; setFromY(m.y) }
      onPositionChanged: function (m) { if (fader.dragging) setFromY(m.y) }
      onReleased: fader.dragging = false
      onCanceled: fader.dragging = false
      onWheel: function (w) { fader.moved(Math.max(0, Math.min(100, fader.value + (w.angleDelta.y > 0 ? 3 : -3)))) }
    }
  }

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
    color: on ? root.acc(0.18) : (hover.containsMouse ? root.dim(0.10) : "transparent")
    border.width: 1
    border.color: on ? root.acc(0.55) : root.dim(0.14)

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

  // A song row: title, artist · album, duration; click plays its album from
  // that song; hover buttons play and add to a playlist.
  component TrackRow: Rectangle {
    id: trow
    property var track: null
    radius: 7
    readonly property bool isCurrent: root.service && root.service.playing && track
      && (root.service.trackKey ? String(track.key) === root.service.trackKey
          : (root.service.trackTitle === track.title && root.service.trackArtist === track.artist))
    color: tH.hovered ? root.dim(0.08) : (isCurrent ? root.acc(0.12) : "transparent")
    HoverHandler { id: tH }
    MouseArea {
      anchors.fill: parent
      onClicked: if (root.service && trow.track) root.service.playAlbum(trow.track.albumKey, trow.track.key)
    }
    Column {
      anchors.left: parent.left; anchors.leftMargin: 10
      anchors.right: tDur.left; anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: trow.track ? trow.track.title : ""
        font.pixelSize: 12
        font.bold: trow.isCurrent
        color: trow.isCurrent ? Color.accent : Color.foreground
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: trow.track ? [trow.track.artist, trow.track.album].filter(Boolean).join("  ·  ") : ""
        font.pixelSize: 10
        color: root.dim(0.5)
      }
    }
    Text {
      id: tDur
      anchors.right: tActs.left; anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      text: trow.track ? root.fmtMs(trow.track.duration) : ""
      font.pixelSize: 10
      color: root.dim(0.4)
      visible: !tH.hovered
    }
    Row {
      id: tActs
      anchors.right: parent.right; anchors.rightMargin: 6
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      width: tH.hovered ? implicitWidth : 0
      clip: true
      RowBtn { glyph: "󰐊"; tip: "Play from this song"; strong: true; visible: tH.hovered
               onTapped: if (root.service && trow.track) root.service.playAlbum(trow.track.albumKey, trow.track.key) }
      RowBtn { glyph: "󰐕"; tip: "Add to a playlist"; visible: tH.hovered
               onTapped: if (root.service && trow.track) root.service.requestAdd([trow.track.key]) }
    }
  }

  // A small round button for list rows.
  component RowBtn: Rectangle {
    id: rb
    property string glyph: ""
    property string tip: ""
    property bool strong: false
    property bool accentOn: false
    signal tapped()

    width: 26
    height: 26
    radius: 13
    color: rbHover.containsMouse ? root.acc(strong ? 0.28 : 0.14) : (strong ? root.acc(0.12) : "transparent")
    border.width: strong ? 1 : 0
    border.color: root.acc(0.5)

    Text {
      anchors.centerIn: parent
      text: rb.glyph
      font.pixelSize: 13
      color: rb.accentOn || rb.strong ? Color.accent : root.dim(rbHover.containsMouse ? 0.9 : 0.4)
    }

    MouseArea {
      id: rbHover
      anchors.fill: parent
      hoverEnabled: true
      onClicked: function (mouse) { mouse.accepted = true; rb.tapped() }
    }

    ToolTip.visible: rbHover.containsMouse && rb.tip !== ""
    ToolTip.text: rb.tip
    ToolTip.delay: 500
  }

  // Album or playlist artwork, square with rounded corners, straight from Plex.
  component CoverThumb: Rectangle {
    id: ct
    property int size: 40
    property string source: ""
    property string fallbackGlyph: "󰃽"
    width: size
    height: size
    radius: 5
    color: root.dim(0.08)
    clip: true

    Image {
      anchors.fill: parent
      source: ct.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      smooth: true
      sourceSize.width: ct.size * 2
      sourceSize.height: ct.size * 2
      visible: status === Image.Ready
    }
    Text {
      anchors.centerIn: parent
      text: ct.fallbackGlyph
      font.pixelSize: ct.size * 0.45
      color: root.dim(0.3)
      visible: ct.source === ""
    }
  }

  component ModeTab: Rectangle {
    id: tab
    property string label: ""
    property bool on: false
    signal tapped()

    implicitWidth: tabText.implicitWidth + 20
    implicitHeight: 24
    radius: 12
    color: on ? root.acc(0.16) : (tabHover.containsMouse ? root.dim(0.08) : "transparent")
    border.width: 1
    border.color: on ? root.acc(0.5) : root.dim(0.12)

    Text {
      id: tabText
      anchors.centerIn: parent
      text: tab.label
      font.pixelSize: 11
      color: tab.on ? Color.accent : root.dim(0.6)
    }

    MouseArea {
      id: tabHover
      anchors.fill: parent
      hoverEnabled: true
      onClicked: tab.tapped()
    }
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
    color: accent ? root.acc(btnHover.containsMouse ? 0.28 : 0.18)
                  : (btnHover.containsMouse ? root.dim(0.12) : root.dim(0.06))
    border.width: 1
    border.color: accent ? root.acc(0.6) : root.dim(0.16)

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
