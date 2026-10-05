// Separator: a gold hairline that fades out at both ends under Q Galaxy.
import QtQuick
import "../themes"

Rectangle {
  implicitHeight: 1
  readonly property color edge: Theme.colors.ruleFades ? Qt.rgba(Theme.colors.rule.r, Theme.colors.rule.g, Theme.colors.rule.b, 0) : Theme.colors.rule
  gradient: Gradient {
    orientation: Gradient.Horizontal
    GradientStop { position: 0.0; color: edge }
    GradientStop { position: 0.5; color: Theme.colors.rule }
    GradientStop { position: 1.0; color: edge }
  }
}
