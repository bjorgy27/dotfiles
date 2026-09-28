import QtQuick

// Describes one slippy-map tile layer for MapView. `urlFor(z, x, y)` returns
// the tile URL; x arrives already wrapped into [0, 2^z). Bump `nonce` to force
// every tile of this source to refetch (MapView appends "#<nonce>" to the URL).
// `tileSize` is the pixel size of the served images (256 or 512).
QtObject {
  property string key: ""
  property var urlFor: function(z, x, y) { return "" }
  property int minZoom: 0
  property int maxZoom: 19
  // Pixel size of the images this source serves (256 or 512). The tile still
  // covers the standard z/x/y extent; a 512 px image just doubles the detail.
  property int tileSize: 256
  property real opacity: 1.0
  property bool visible: true
  property bool smooth: true
  property int nonce: 0
  property string attribution: ""
}
