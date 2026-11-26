$ErrorActionPreference = 'Stop'

$bbox = '121.1825,24.9635,121.1992,24.9735'
$url = "https://api.openstreetmap.org/api/0.6/map?bbox=$bbox"
$headers = @{ 'User-Agent' = 'NCU-CampusMap/1.0' }
$response = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 60
[xml]$osm = $response.Content

$nodeCoordinates = @{}
foreach ($node in $osm.osm.node) {
  $nodeCoordinates[[string]$node.id] = [pscustomobject]@{
    lon = [double]$node.lon
    lat = [double]$node.lat
  }
}

function Get-WayTags($way) {
  $tags = @{}
  foreach ($tag in $way.tag) { $tags[[string]$tag.k] = [string]$tag.v }
  return ,$tags
}

function Get-WayNodeIds($way) {
  return @($way.nd | ForEach-Object { [string]$_.ref })
}

function Get-WayCoordinates($way) {
  $coordinates = [System.Collections.Generic.List[object]]::new()
  foreach ($nodeRef in $way.nd) {
    $point = $nodeCoordinates[[string]$nodeRef.ref]
    if ($null -ne $point) { $coordinates.Add(@($point.lon, $point.lat)) }
  }
  return ,@($coordinates.ToArray())
}

function Test-PointInRing([double]$longitude, [double]$latitude, $ring) {
  $inside = $false
  $j = $ring.Count - 1
  for ($i = 0; $i -lt $ring.Count; $j = $i++) {
    $xi = [double]$ring[$i][0]; $yi = [double]$ring[$i][1]
    $xj = [double]$ring[$j][0]; $yj = [double]$ring[$j][1]
    $crosses = (($yi -gt $latitude) -ne ($yj -gt $latitude)) -and
      ($longitude -lt (($xj - $xi) * ($latitude - $yi) / (($yj - $yi) + 0.000000000001) + $xi))
    if ($crosses) { $inside = -not $inside }
  }
  return $inside
}

$campusRelation = $osm.osm.relation | Where-Object { $_.id -eq '18727079' } | Select-Object -First 1
if ($null -eq $campusRelation) { throw 'OpenStreetMap campus boundary relation 18727079 was not present in the downloaded map.' }
$segments = [System.Collections.Generic.List[object]]::new()
foreach ($member in $campusRelation.member | Where-Object { $_.type -eq 'way' }) {
  $way = $osm.osm.way | Where-Object { $_.id -eq $member.ref } | Select-Object -First 1
  if ($null -ne $way) {
    $segments.Add([pscustomobject]@{ Role = [string]$member.role; Refs = @(Get-WayNodeIds $way) })
  }
}
$boundaryRings = [System.Collections.Generic.List[object]]::new()
while ($segments.Count -gt 0) {
  $segment = $segments[0]
  $segments.RemoveAt(0)
  $ringRefs = [System.Collections.Generic.List[string]]::new()
  foreach ($ref in $segment.Refs) { $ringRefs.Add($ref) }
  $guard = 0
  while ($ringRefs.Count -gt 2 -and $ringRefs[0] -ne $ringRefs[$ringRefs.Count - 1] -and $guard -lt 20) {
    $guard++
    $endRef = $ringRefs[$ringRefs.Count - 1]
    $matchIndex = -1
    $reverse = $false
    for ($s = 0; $s -lt $segments.Count; $s++) {
      $refs = $segments[$s].Refs
      if ($refs[0] -eq $endRef) { $matchIndex = $s; break }
      if ($refs[$refs.Count - 1] -eq $endRef) { $matchIndex = $s; $reverse = $true; break }
    }
    if ($matchIndex -lt 0) { break }
    $next = $segments[$matchIndex]
    $segments.RemoveAt($matchIndex)
    $nextRefs = @($next.Refs)
    if ($reverse) { [array]::Reverse($nextRefs) }
    for ($n = 1; $n -lt $nextRefs.Count; $n++) { $ringRefs.Add([string]$nextRefs[$n]) }
  }
  if ($ringRefs.Count -gt 3 -and $ringRefs[0] -eq $ringRefs[$ringRefs.Count - 1]) {
    $ring = [System.Collections.Generic.List[object]]::new()
    foreach ($ref in $ringRefs) {
      $point = $nodeCoordinates[$ref]
      if ($null -ne $point) { $ring.Add(@($point.lon, $point.lat)) }
    }
    if ($ring.Count -gt 3) { $boundaryRings.Add([pscustomobject]@{ Role = $segment.Role; Coordinates = @($ring.ToArray()) }) }
  }
}
if ($boundaryRings.Count -eq 0) { throw 'Unable to assemble the OpenStreetMap campus boundary.' }
$outerRings = [System.Collections.Generic.List[object]]::new()
foreach ($boundaryRing in $boundaryRings) {
  if ($boundaryRing.Role -ne 'inner') { $outerRings.Add($boundaryRing.Coordinates) }
}

function Test-InCampus($ring) {
  foreach ($outer in $outerRings) {
    if (Test-PointInRing -longitude ([double]$ring[0]) -latitude ([double]$ring[1]) -ring $outer) { return $true }
  }
  return $false
}

$features = [System.Collections.Generic.List[object]]::new()
foreach ($ring in $outerRings) {
  $features.Add([pscustomobject]@{
    type = 'Feature';
    id = 'ncu-campus-outline';
    properties = @{ kind = 'campus-boundary'; name = '國立中央大學校園' };
    geometry = @{ type = 'Polygon'; coordinates = (, @($ring)) }
  })
}

$dormitoryPattern = '宿舍|舍$|新村|北村|中大會館|學人宿舍|校長宿舍|dormitory|\bdorm\b|guest.?house'
foreach ($way in $osm.osm.way) {
  $tags = Get-WayTags $way
  if (-not $tags.ContainsKey('building')) { continue }
  $coordinates = Get-WayCoordinates $way
  if ($coordinates.Count -lt 4) { continue }
  if ($coordinates[0][0] -ne $coordinates[$coordinates.Count - 1][0] -or $coordinates[0][1] -ne $coordinates[$coordinates.Count - 1][1]) { continue }
  $centerLon = 0.0; $centerLat = 0.0
  for ($i = 0; $i -lt $coordinates.Count - 1; $i++) { $centerLon += [double]$coordinates[$i][0]; $centerLat += [double]$coordinates[$i][1] }
  $centerLon /= ($coordinates.Count - 1); $centerLat /= ($coordinates.Count - 1)
  if (-not (Test-InCampus @($centerLon, $centerLat))) { continue }
  $name = [string]$tags['name']
  if ($tags['building'] -eq 'dormitory' -or $name -match $dormitoryPattern) { continue }
  $levels = 0.0
  if ($tags['building:levels'] -match '^\d+(\.\d+)?$') { $levels = [double]$tags['building:levels'] }
  $height = 0.0
  if ($tags['height'] -match '^\d+(\.\d+)?$') { $height = [double]$tags['height'] }
  $features.Add([pscustomobject]@{
    type = 'Feature';
    id = "way/$($way.id)";
    properties = @{
      kind = 'building'; osmId = [string]$way.id; name = $name;
      building = [string]$tags['building']; levels = $levels; height = $height;
      nodeIds = @(Get-WayNodeIds $way)
    };
      geometry = @{ type = 'Polygon'; coordinates = (, @($coordinates)) }
  })
}

foreach ($way in $osm.osm.way) {
  $tags = Get-WayTags $way
  $coordinates = Get-WayCoordinates $way
  if ($coordinates.Count -lt 2) { continue }
  if ($tags.ContainsKey('highway')) {
    $nodeIds = @(Get-WayNodeIds $way)
    $segmentCoordinates = [System.Collections.Generic.List[object]]::new()
    $segmentNodeIds = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $coordinates.Count; $i++) {
      if (Test-InCampus $coordinates[$i]) {
        $segmentCoordinates.Add($coordinates[$i])
        if ($i -lt $nodeIds.Count) { $segmentNodeIds.Add([string]$nodeIds[$i]) }
      } else {
        if ($segmentCoordinates.Count -ge 2) {
          $features.Add([pscustomobject]@{
            type = 'Feature'; id = "way/$($way.id)/segment/$i";
            properties = @{ kind = 'road'; highway = [string]$tags['highway']; name = [string]$tags['name']; nodeIds = @($segmentNodeIds.ToArray()) };
            geometry = @{ type = 'LineString'; coordinates = @($segmentCoordinates.ToArray()) }
          })
        }
        $segmentCoordinates.Clear()
        $segmentNodeIds.Clear()
      }
    }
    if ($segmentCoordinates.Count -ge 2) {
      $features.Add([pscustomobject]@{
        type = 'Feature'; id = "way/$($way.id)/segment/end";
        properties = @{ kind = 'road'; highway = [string]$tags['highway']; name = [string]$tags['name']; nodeIds = @($segmentNodeIds.ToArray()) };
        geometry = @{ type = 'LineString'; coordinates = @($segmentCoordinates.ToArray()) }
      })
    }
    continue
  }
  if ($coordinates.Count -lt 4 -or $coordinates[0][0] -ne $coordinates[$coordinates.Count - 1][0] -or $coordinates[0][1] -ne $coordinates[$coordinates.Count - 1][1]) { continue }
  $areaTags = @('landuse', 'leisure', 'natural', 'water') | Where-Object { $tags.ContainsKey($_) }
  if (-not $areaTags) { continue }
  $centerLon = 0.0; $centerLat = 0.0
  for ($i = 0; $i -lt $coordinates.Count - 1; $i++) { $centerLon += [double]$coordinates[$i][0]; $centerLat += [double]$coordinates[$i][1] }
  $centerLon /= ($coordinates.Count - 1); $centerLat /= ($coordinates.Count - 1)
  if (-not (Test-InCampus @($centerLon, $centerLat))) { continue }
  $areaKind = if ($tags.ContainsKey('natural') -and $tags['natural'] -eq 'water' -or $tags.ContainsKey('water')) { 'water' } else { 'green' }
  $features.Add([pscustomobject]@{
    type = 'Feature'; id = "way/$($way.id)";
    properties = @{ kind = $areaKind; name = [string]$tags['name']; landuse = [string]$tags['landuse']; leisure = [string]$tags['leisure'] };
      geometry = @{ type = 'Polygon'; coordinates = (, @($coordinates)) }
  })
}

$features.Add([pscustomobject]@{
  type = 'Feature'; id = 'gate-main';
  properties = @{ kind = 'gate'; name = '正門'; entrance = 'main'; source = 'Nearest campus-road endpoint to Taoyuan City Bus 133 Central University Main Gate stop'; referenceStop = @(121.200362, 24.968241) };
  geometry = @{ type = 'Point'; coordinates = @(121.1965816, 24.9682822) }
})
$features.Add([pscustomobject]@{
  type = 'Feature'; id = 'gate-back';
  properties = @{ kind = 'gate'; name = '後門'; entrance = 'back'; source = 'Nearest campus-road endpoint to Taoyuan City Bus 133 Central University Back Gate stop'; referenceStop = @(121.191779, 24.966715) };
  geometry = @{ type = 'Point'; coordinates = @(121.1921131, 24.9667831) }
})

$collection = [pscustomobject]@{
  type = 'FeatureCollection'
  metadata = @{
    title = 'National Central University campus map'
    source = 'OpenStreetMap contributors, OSM campus relation 18727079'
    retrieved = '2026-11-26'
    license = 'Open Database License (ODbL)'
    attribution = '© OpenStreetMap contributors'
    gateSource = 'Taoyuan City Bus route 133 stop address list'
  }
  features = @($features.ToArray())
}
$outputDirectory = Join-Path $PSScriptRoot '..\data'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$outputPath = Join-Path $outputDirectory 'ncu-campus.geojson'
$collection | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Output "Wrote $($features.Count) campus features to $outputPath"
