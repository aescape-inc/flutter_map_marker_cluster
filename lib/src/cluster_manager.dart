import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/src/core/distance_grid.dart';
import 'package:flutter_map_marker_cluster/src/map_calculator.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_cluster_node.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_node.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_or_cluster_node.dart';

class ClusterManager {
  final MapCalculator mapCalculator;
  final Alignment? alignment;
  final Size predefinedSize;
  final Size Function(List<Marker>)? computeSize;
  final int minZoom;

  final List<DistanceGrid<MarkerClusterNode>> _gridClusters;
  final List<DistanceGrid<MarkerNode>> _gridUnclustered;
  final MarkerClusterNode _topClusterLevel;

  const ClusterManager._({
    required this.mapCalculator,
    required this.alignment,
    required this.predefinedSize,
    required this.computeSize,
    required this.minZoom,
    required List<DistanceGrid<MarkerClusterNode>> gridClusters,
    required List<DistanceGrid<MarkerNode>> gridUnclustered,
    required MarkerClusterNode topClusterLevel,
  })  : _gridClusters = gridClusters,
        _gridUnclustered = gridUnclustered,
        _topClusterLevel = topClusterLevel;

  factory ClusterManager.initialize({
    required MapCalculator mapCalculator,
    required Alignment? alignment,
    required Size predefinedSize,
    required Size Function(List<Marker>)? computeSize,
    required int minZoom,
    required int maxZoom,
    required int maxClusterRadius,
  }) {
    final len = maxZoom - minZoom + 1;
    final gridClusters = List<DistanceGrid<MarkerClusterNode>>.generate(
      len,
      (_) => DistanceGrid(maxClusterRadius),
      growable: false,
    );
    final gridUnclustered = List<DistanceGrid<MarkerNode>>.generate(
      len,
      (_) => DistanceGrid(maxClusterRadius),
      growable: false,
    );

    final topClusterLevel = MarkerClusterNode(
      alignment: alignment,
      zoom: minZoom - 1,
      predefinedSize: predefinedSize,
      computeSize: computeSize,
    );

    return ClusterManager._(
      alignment: alignment,
      mapCalculator: mapCalculator,
      predefinedSize: predefinedSize,
      computeSize: computeSize,
      minZoom: minZoom,
      gridClusters: gridClusters,
      gridUnclustered: gridUnclustered,
      topClusterLevel: topClusterLevel,
    );
  }

  MarkerClusterNode? findClosestCluster(Point<double> markerPoint, int zoom) {
    final gridClusters = _gridClusters[zoom - minZoom];
    MarkerClusterNode? closestCluster;
    var closestDist = double.infinity;

    for (final cluster in gridClusters.grid.values.expand((x) => x)) {
      for (final marker in cluster.obj.markers) {
        final markerProjected =
            mapCalculator.project(marker.point, zoom: zoom.toDouble());
        final dist = markerProjected.distanceTo(markerPoint);

        if (dist < closestDist) {
          closestDist = dist;
          closestCluster = cluster.obj;
        }
      }
    }

    return closestCluster;
  }

  void addLayer(
    MarkerNode newMarker,
    int disableClusteringAtZoom,
    int maxZoom,
    int minZoom,
  ) {
    for (var zoom = maxZoom; zoom >= minZoom; zoom--) {
      final gridIndex = zoom - minZoom;
      final gridUnclustered = _gridUnclustered[gridIndex];
      final cellSize = gridUnclustered.cellSize;
      final newMarkerPoint = mapCalculator.project(
        newMarker.point,
        zoom: zoom.toDouble(),
      );
      if (zoom <= disableClusteringAtZoom) {
        final cluster = findClosestCluster(newMarkerPoint, zoom);
        if (cluster != null) {
          for (final oldMarker in cluster.mapMarkers) {
            final oldMarkerPoint = mapCalculator.project(
              oldMarker.point,
              zoom: zoom.toDouble(),
            );
            final isNewNearOld =
                oldMarkerPoint.distanceTo(newMarkerPoint).floor() <= cellSize;
            if (isNewNearOld) {
              cluster.addChild(newMarker, newMarker.point);
              return;
            }
          }
        }

        final closest = gridUnclustered.getNearObject(newMarkerPoint);
        if (closest != null) {
          final parent = closest.parent!;
          parent.removeChild(closest);

          final newCluster = MarkerClusterNode(
            zoom: zoom,
            alignment: alignment,
            predefinedSize: predefinedSize,
            computeSize: computeSize,
          )
            ..addChild(closest, closest.point)
            ..addChild(newMarker, closest.point);

          gridUnclustered.eachObject((node) {
            if (node.point != closest.point) {
              final nodePoint = mapCalculator.project(
                node.point,
                zoom: zoom.toDouble(),
              );
              if (nodePoint.distanceTo(newMarkerPoint).floor() <= cellSize) {
                final nodeParent = node.parent!;
                nodeParent.removeChild(node);
                newCluster.addChild(node, closest.point);
                gridUnclustered.removeObject(node);
              }
            }
          });

          _gridClusters[gridIndex].addObject(
            newCluster,
            mapCalculator.project(
              newCluster.bounds.center,
              zoom: zoom.toDouble(),
            ),
          );

          // First create any new intermediate parent clusters that don't exist
          var lastParent = newCluster;
          for (var z = zoom - 1; z > parent.zoom; z--) {
            final newParent = MarkerClusterNode(
              zoom: z,
              alignment: alignment,
              predefinedSize: predefinedSize,
              computeSize: computeSize,
            );
            newParent.addChild(lastParent, lastParent.bounds.center);
            lastParent = newParent;
            _gridClusters[z - minZoom].addObject(
              lastParent,
              mapCalculator.project(lastParent.bounds.center,
                  zoom: z.toDouble()),
            );
          }
          parent.addChild(lastParent, lastParent.bounds.center);

          _removeFromNewPosToMyPosGridUnclustered(closest, zoom, minZoom);
          return;
        }
      }

      _gridUnclustered[gridIndex].addObject(newMarker, newMarkerPoint);
    }

    //Didn't get in anything, add us to the top
    _topClusterLevel.addChild(newMarker, newMarker.point);
  }

  void _removeFromNewPosToMyPosGridUnclustered(
    MarkerNode marker,
    int zoom,
    int minZoom,
  ) {
    for (; zoom >= minZoom; zoom--) {
      if (!_gridUnclustered[zoom - minZoom].removeObject(marker)) {
        break;
      }
    }
  }

  void recalculateTopClusterLevelProperties() =>
      _topClusterLevel.recalculate(recursively: true);

  void recursivelyFromTopClusterLevel(
    int zoomLevel,
    int disableClusteringAtZoom,
    LatLngBounds recursionBounds,
    Function(MarkerOrClusterNode) fn,
  ) =>
      _topClusterLevel.recursively(
        zoomLevel,
        disableClusteringAtZoom,
        recursionBounds,
        fn,
      );
}
