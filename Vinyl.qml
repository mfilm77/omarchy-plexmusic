import QtQuick
import QtQuick.Effects
import qs.Commons

// A record on a platter: black disc, cut grooves, the album cover as the label.
//
// It turns at 33 1/3 rpm — 1.8 seconds a revolution — because a record that
// spins at some arbitrary speed looks wrong to anyone who owns one. Pausing
// stops it where it is rather than snapping back to zero.
Item {
  id: root

  property bool spinning: false
  property string art: ""
  property real labelRatio: 0.36      // label diameter as a share of the disc

  // Never negative: the panel's arithmetic can go below zero mid-layout and
  // every radius below depends on this.
  readonly property real size: Math.max(0, Math.min(width, height))
  readonly property real labelSize: size * labelRatio

  // ---- the disc ------------------------------------------------------------

  Item {
    id: platter
    width: root.size
    height: root.size
    anchors.centerIn: parent

    // Everything that must turn with the record lives in here.
    Item {
      id: turning
      anchors.fill: parent

      // The vinyl itself. Not flat black: a record picks up a sheen from the
      // room, and without it the disc reads as a hole in the panel.
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        gradient: Gradient {
          GradientStop { position: 0.0; color: "#22242a" }
          GradientStop { position: 0.45; color: "#0e0f13" }
          GradientStop { position: 1.0; color: "#05060a" }
        }
      }

      // The grooves. Drawn once into a canvas — a Repeater of 90 circles is the
      // obvious way and it costs 90 nodes that never change.
      Canvas {
        id: grooves
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
          // Canvas paints once before the panel has been laid out, when the
          // width can still be 0 or briefly negative. A negative radius is a
          // hard error in Qt's 2D context, so bail out rather than draw.
          if (!(width > 0) || !(height > 0)) return
          var c = width / 2
          var outer = Math.max(0, c * 0.985)
          var inner = Math.max(0, c * (root.labelRatio / 2) * 1.08)
          // Math.max(0, NaN) is NaN, and a NaN radius is the same hard error.
          if (!isFinite(outer) || !isFinite(inner) || inner > outer) return
          var ctx = getContext("2d")
          ctx.reset()
          // Groove pitch is not uniform on a real record; a slight variation
          // stops the rings reading as a moiré pattern on a screen.
          var rings = 78
          for (var i = 0; i < rings; i++) {
            var t = i / (rings - 1)
            var r = outer - (outer - inner) * t
            ctx.beginPath()
            ctx.arc(c, c, r, 0, Math.PI * 2)
            ctx.lineWidth = (i % 9 === 0) ? 1.4 : 0.7
            ctx.strokeStyle = (i % 9 === 0)
              ? "rgba(255,255,255,0.075)" : "rgba(255,255,255,0.035)"
            ctx.stroke()
          }
          // The run-out band nearest the label reads as smooth vinyl.
          ctx.beginPath()
          ctx.arc(c, c, inner * 0.94, 0, Math.PI * 2)
          ctx.lineWidth = 2
          ctx.strokeStyle = "rgba(255,255,255,0.05)"
          ctx.stroke()
        }
      }

      // The label: the real album cover, cropped to a circle. This is the whole
      // point of the thing, so it gets the accent ring rather than a grey edge.
      Item {
        id: label
        width: root.labelSize
        height: root.labelSize
        anchors.centerIn: parent

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Qt.darker(Color.popups.background, 1.4)
        }

        Image {
          id: cover
          anchors.fill: parent
          source: root.art ? "file://" + root.art : ""
          fillMode: Image.PreserveAspectCrop
          cache: true
          asynchronous: true
          smooth: true
          mipmap: true
          visible: false
          sourceSize.width: 500
          sourceSize.height: 500
        }

        MultiEffect {
          anchors.fill: parent
          source: cover
          maskEnabled: true
          maskSource: labelMask
          // Soften the mask edge a touch either side of the threshold; with a
          // hard threshold the circle is cut on whole pixels and looks jagged.
          maskThresholdMin: 0.4
          maskSpreadAtMin: 0.6
          visible: cover.status === Image.Ready
        }

        // The circular mask, rendered at twice the label's size with
        // antialiasing so its edge is smooth once scaled onto the cover.
        Item {
          id: labelMask
          width: root.labelSize
          height: root.labelSize
          layer.enabled: true
          layer.smooth: true
          layer.textureSize: Qt.size(Math.max(2, Math.round(width * 2)),
                                     Math.max(2, Math.round(height * 2)))
          visible: false
          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "black"
            antialiasing: true
          }
        }

        // No cover in Plex: show the accent monogram rather than a grey hole.
        Text {
          anchors.centerIn: parent
          visible: cover.status !== Image.Ready
          text: "󰃽"
          font.pixelSize: parent.height * 0.4
          color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                         Color.foreground.b, 0.35)
        }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: "transparent"
          border.width: 1.5
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
          antialiasing: true
        }
      }

      // The spindle hole. Small, but its absence is what makes a drawn record
      // look like a dark coaster.
      Rectangle {
        anchors.centerIn: parent
        width: root.size * 0.022
        height: width
        radius: width / 2
        color: Qt.darker(Color.popups.background, 2.2)
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.6)
      }

      RotationAnimator {
        target: turning
        from: 0
        to: 360
        duration: 1800          // 33 1/3 rpm
        loops: Animation.Infinite
        running: root.spinning
      }
    }

    // The sheen stays put while the record turns underneath it, which is what
    // sells the rotation.
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      opacity: 0.5
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 0.30; color: Qt.rgba(1, 1, 1, 0.045) }
        GradientStop { position: 0.44; color: "transparent" }
        GradientStop { position: 0.62; color: Qt.rgba(1, 1, 1, 0.02) }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                            Color.foreground.b, 0.12)
    }
  }

  // ---- the tonearm ---------------------------------------------------------
  //
  // Based at the platter's top-right corner, as on a real deck. When a record
  // is on it swings down onto the outer groove and creeps inward with the
  // track; when there is nothing on, it lifts and parks along the top edge.
  // `progress` is 0-1 through the current track.
  property real progress: 0
  property bool engaged: false     // a record is on, paused or not

  Item {
    id: arm
    readonly property real len: root.size * 0.52
    width: len
    height: root.size * 0.05
    // The pivot is the arm's right end, sitting just outside the disc.
    x: platter.x + platter.width * 1.02 - width
    y: platter.y + platter.height * 0.02 - height / 2
    transformOrigin: Item.Right
    // Qt rotation is clockwise; the arm points left from its pivot, so a
    // negative angle drops the headshell down onto the record. 12 degrees
    // lands it on the outer groove, 30 puts it at the label.
    rotation: root.engaged ? -(12 + root.progress * 18) : 4
    opacity: 0.95

    Behavior on rotation {
      NumberAnimation { duration: 900; easing.type: Easing.InOutCubic }
    }

    // Counterweight end.
    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: parent.height * 1.7
      height: parent.height * 1.7
      radius: width / 2
      color: Qt.lighter(Color.popups.background, 1.9)
      border.width: 1
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                            Color.foreground.b, 0.22)
    }

    // The arm tube.
    Rectangle {
      anchors.right: parent.right
      anchors.rightMargin: parent.height * 0.8
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - parent.height
      height: Math.max(2, parent.height * 0.30)
      radius: height / 2
      color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                     Color.foreground.b, 0.55)
    }

    // Headshell and needle.
    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.height * 1.25
      height: parent.height * 0.85
      radius: 2
      color: Color.accent
      opacity: 0.9
    }
  }
}
