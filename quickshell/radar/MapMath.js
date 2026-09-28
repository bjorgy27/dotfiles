// Web Mercator / great-circle helpers shared by the map and its overlays.
// World pixel space: at (continuous) zoom z the world is TILE * 2^z px square,
// x grows east from lon -180, y grows south from lat +85.05.
.pragma library

var TILE = 256
var MAX_LAT = 85.05112878
// Globe mode keeps the view centre this far from the poles so the orthographic
// projection never degenerates (and the mercator texture has data there).
var GLOBE_MAX_LAT = 80
// The globe's radius follows the mercator scale at the view centre so the
// flat<->globe switch is seamless, but only up to this latitude: beyond it the
// 1/cos(lat) growth would balloon the globe while rotating toward a pole.
var GLOBE_SCALE_LAT = 40
var EARTH_RADIUS_M = 6378137.0
var EARTH_RADIUS_NM = 3440.065

function worldSize(zoom) { return TILE * Math.pow(2, zoom) }

function clampLat(lat) { return Math.max(-MAX_LAT, Math.min(MAX_LAT, lat)) }

function wrapLon(lon) {
  var l = ((lon + 180) % 360 + 360) % 360 - 180
  return l === -180 ? 180 : l
}

function lonToX(lon, zoom) {
  return (lon + 180) / 360 * worldSize(zoom)
}

function latToY(lat, zoom) {
  var s = Math.sin(clampLat(lat) * Math.PI / 180)
  return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * worldSize(zoom)
}

function xToLon(x, zoom) {
  return x / worldSize(zoom) * 360 - 180
}

function yToLat(y, zoom) {
  var n = Math.PI - 2 * Math.PI * y / worldSize(zoom)
  return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)))
}

function haversineNm(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var dLat = (lat2 - lat1) * toRad
  var dLon = (lon2 - lon1) * toRad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
        + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 2 * EARTH_RADIUS_NM * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function bearingDeg(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var phi1 = lat1 * toRad, phi2 = lat2 * toRad
  var dLon = (lon2 - lon1) * toRad
  var y = Math.sin(dLon) * Math.cos(phi2)
  var x = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLon)
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360
}

function destinationPoint(lat, lon, bearing, distNm) {
  var toRad = Math.PI / 180
  var d = distNm / EARTH_RADIUS_NM
  var phi1 = lat * toRad, lam1 = lon * toRad, th = bearing * toRad
  var phi2 = Math.asin(Math.sin(phi1) * Math.cos(d) + Math.cos(phi1) * Math.sin(d) * Math.cos(th))
  var lam2 = lam1 + Math.atan2(Math.sin(th) * Math.sin(d) * Math.cos(phi1),
                               Math.cos(d) - Math.sin(phi1) * Math.sin(phi2))
  return { lat: phi2 * 180 / Math.PI, lon: wrapLon(lam2 * 180 / Math.PI) }
}

// n+1 points along the great circle from (lat1,lon1) to (lat2,lon2).
// Longitudes are returned raw (wrapped to -180..180 per point); consumers
// should project each with MapView.lonLatToXY, which picks the nearest world copy.
function greatCirclePoints(lat1, lon1, lat2, lon2, n) {
  var toRad = Math.PI / 180
  var phi1 = lat1 * toRad, lam1 = lon1 * toRad
  var phi2 = lat2 * toRad, lam2 = lon2 * toRad
  var d = 2 * Math.asin(Math.sqrt(
    Math.pow(Math.sin((phi1 - phi2) / 2), 2)
    + Math.cos(phi1) * Math.cos(phi2) * Math.pow(Math.sin((lam1 - lam2) / 2), 2)))
  var pts = []
  if (n < 1) n = 1
  if (d < 1e-9) {
    for (var k = 0; k <= n; k++) pts.push([lat1, lon1])
    return pts
  }
  for (var i = 0; i <= n; i++) {
    var f = i / n
    var A = Math.sin((1 - f) * d) / Math.sin(d)
    var B = Math.sin(f * d) / Math.sin(d)
    var x = A * Math.cos(phi1) * Math.cos(lam1) + B * Math.cos(phi2) * Math.cos(lam2)
    var y = A * Math.cos(phi1) * Math.sin(lam1) + B * Math.cos(phi2) * Math.sin(lam2)
    var z = A * Math.sin(phi1) + B * Math.sin(phi2)
    var lat = Math.atan2(z, Math.sqrt(x * x + y * y)) * 180 / Math.PI
    var lon = Math.atan2(y, x) * 180 / Math.PI
    pts.push([lat, wrapLon(lon)])
  }
  return pts
}

function metersPerPixel(lat, zoom) {
  return 2 * Math.PI * EARTH_RADIUS_M * Math.cos(clampLat(lat) * Math.PI / 180) / worldSize(zoom)
}

// EPSG:3857 bounds of a slippy tile (metres), for WMS GetMap bbox.
function tileBounds3857(z, x, y) {
  var n = Math.pow(2, z)
  var half = Math.PI * EARTH_RADIUS_M
  var size = 2 * half / n
  return {
    minx: -half + x * size,
    maxx: -half + (x + 1) * size,
    maxy: half - y * size,
    miny: half - (y + 1) * size
  }
}

function formatTime(unixSeconds) {
  var d = new Date(unixSeconds * 1000)
  var h = d.getHours(), m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// ---- orthographic globe helpers ----
// View space: x right, y up, z toward the viewer; the view centre (0,0,1) is
// the surface point (centerLat, centerLon). Angles in degrees.

// Unit-sphere view-space coordinates of (lat, lon). z < 0 means the point is on
// the far side of the globe.
function orthoProject(lat, lon, centerLat, centerLon) {
  var toRad = Math.PI / 180
  var phi = lat * toRad, dl = (lon - centerLon) * toRad, a = centerLat * toRad
  var x = Math.cos(phi) * Math.sin(dl)
  var yp = Math.sin(phi)
  var zp = Math.cos(phi) * Math.cos(dl)
  return {
    x: x,
    y: yp * Math.cos(a) - zp * Math.sin(a),
    z: yp * Math.sin(a) + zp * Math.cos(a)
  }
}

// Inverse of orthoProject for a point (x, y) on the unit disc; null outside it.
function orthoUnproject(x, y, centerLat, centerLon) {
  var r2 = x * x + y * y
  if (r2 > 1) return null
  var z = Math.sqrt(1 - r2)
  var a = centerLat * Math.PI / 180
  var yp = y * Math.cos(a) + z * Math.sin(a)
  var zp = z * Math.cos(a) - y * Math.sin(a)
  var lat = Math.asin(Math.max(-1, Math.min(1, yp))) * 180 / Math.PI
  var lon = centerLon + Math.atan2(x, zp) * 180 / Math.PI
  return { lat: lat, lon: wrapLon(lon) }
}

// Globe radius in px for a zoom level: the orthographic scale at the view
// centre equals the mercator scale at latitude `lat` and that zoom.
function globeRadius(zoom, lat) {
  var c = Math.cos(Math.max(-GLOBE_SCALE_LAT, Math.min(GLOBE_SCALE_LAT, lat)) * Math.PI / 180)
  return worldSize(zoom) / (2 * Math.PI * c)
}

// Zoom at which globeRadius(zoom, lat) == radiusPx (inverse of globeRadius).
function globeZoomForRadius(radiusPx, lat) {
  var c = Math.cos(Math.max(-GLOBE_SCALE_LAT, Math.min(GLOBE_SCALE_LAT, lat)) * Math.PI / 180)
  return Math.log2(radiusPx * 2 * Math.PI * c / TILE)
}
