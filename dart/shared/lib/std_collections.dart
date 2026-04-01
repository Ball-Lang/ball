/// `std_collections` base module builder for the ball programming language.
///
/// Separate from `std` because not all runtimes expose a mutable collection
/// API (e.g. some WASM targets), and the set of operations is large enough
/// to warrant its own versioned module.
///
/// Depends on `std`. Import explicitly.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_collections base module.
Module buildStdCollectionsModule() {
  final module = Module()
    ..name = 'std_collections'
    ..description =
        'Standard collections module. List and map operations. '
        'Separate from std because not all runtimes support mutable '
        'collections natively.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('ListInput', [
      _exprField('list', 1),
      _exprField('index', 2),
      _exprField('value', 3),
    ]),
    _type('ListCallbackInput', [
      _exprField('list', 1),
      _exprField('callback', 2),
    ]),
    _type('ListReduceInput', [
      _exprField('list', 1),
      _exprField('callback', 2),
      _exprField('initial', 3),
    ]),
    _type('ListSliceInput', [
      _exprField('list', 1),
      _exprField('start', 2),
      _exprField('end', 3),
    ]),
    _type('MapInput', [
      _exprField('map', 1),
      _exprField('key', 2),
      _exprField('value', 3),
    ]),
    _type('MapCallbackInput', [
      _exprField('map', 1),
      _exprField('callback', 2),
    ]),
    _type('StringJoinInput', [
      _exprField('list', 1),
      _exprField('separator', 2),
    ]),
    _type('SetInput', [
      _exprField('set', 1),
      _exprField('value', 2),
    ]),
    _type('SetCallbackInput', [
      _exprField('set', 1),
      _exprField('callback', 2),
    ]),
    _type('SetBinaryInput', [
      _exprField('left', 1),
      _exprField('right', 2),
    ]),
  ]);

  // ============================================================
  // Functions — list operations
  // ============================================================

  module.functions.addAll([
    // List — indexed, ordered
    _fn('list_push', 'ListInput', '', 'Append to list: list.add(value)'),
    _fn('list_pop', 'ListInput', '', 'Remove last: list.removeLast()'),
    _fn('list_insert', 'ListInput', '',
        'Insert at index: list.insert(index, value)'),
    _fn('list_remove_at', 'ListInput', '',
        'Remove at index: list.removeAt(index)'),
    _fn('list_get', 'ListInput', '', 'Get element: list[index]'),
    _fn('list_set', 'ListInput', '', 'Set element: list[index] = value'),
    _fn('list_length', 'ListInput', '', 'List length: list.length'),
    _fn('list_is_empty', 'ListInput', '', 'Is empty: list.isEmpty'),
    _fn('list_first', 'ListInput', '', 'First element: list.first'),
    _fn('list_last', 'ListInput', '', 'Last element: list.last'),
    _fn('list_single', 'ListInput', '', 'Single element: list.single'),
    _fn('list_contains', 'ListInput', '',
        'Contains element: list.contains(value)'),
    _fn('list_index_of', 'ListInput', '',
        'Index of element: list.indexOf(value)'),
    _fn('list_map', 'ListCallbackInput', '', 'Map: list.map(callback)'),
    _fn('list_filter', 'ListCallbackInput', '',
        'Filter: list.where(callback)'),
    _fn('list_reduce', 'ListReduceInput', '',
        'Reduce: list.fold(initial, callback)'),
    _fn('list_find', 'ListCallbackInput', '',
        'Find first: list.firstWhere(callback)'),
    _fn('list_any', 'ListCallbackInput', '', 'Any match: list.any(callback)'),
    _fn('list_all', 'ListCallbackInput', '',
        'All match: list.every(callback)'),
    _fn('list_none', 'ListCallbackInput', '',
        'None match: !list.any(callback)'),
    _fn('list_sort', 'ListCallbackInput', '', 'Sort: list.sort(compare)'),
    _fn('list_sort_by', 'ListCallbackInput', '',
        'Sort by key: list.sort((a,b) => key(a).compareTo(key(b)))'),
    _fn('list_reverse', 'ListInput', '',
        'Reverse: list.reversed.toList()'),
    _fn('list_slice', 'ListSliceInput', '',
        'Slice: list.sublist(start, end)'),
    _fn('list_flat_map', 'ListCallbackInput', '',
        'Flat map: list.expand(callback)'),
    _fn('list_zip', 'ListInput', '', 'Zip two lists: zip(list, other)'),
    _fn('list_take', 'ListInput', '', 'Take N: list.take(n)'),
    _fn('list_drop', 'ListInput', '', 'Drop N: list.skip(n)'),
    _fn('list_concat', 'ListInput', '',
        'Concat two lists: list + other'),

    // Map — key/value
    _fn('map_get', 'MapInput', '', 'Get value: map[key]'),
    _fn('map_set', 'MapInput', '', 'Set value: map[key] = value'),
    _fn('map_delete', 'MapInput', '', 'Delete key: map.remove(key)'),
    _fn('map_contains_key', 'MapInput', '',
        'Contains key: map.containsKey(key)'),
    _fn('map_keys', 'MapInput', '', 'All keys: map.keys'),
    _fn('map_values', 'MapInput', '', 'All values: map.values'),
    _fn('map_entries', 'MapInput', '', 'All entries: map.entries'),
    _fn('map_from_entries', 'ListInput', '',
        'Map from entries: Map.fromEntries(list)'),
    _fn('map_merge', 'MapInput', '', 'Merge two maps: {...a, ...b}'),
    _fn('map_map', 'MapCallbackInput', '', 'Map over map: map.map(callback)'),
    _fn('map_filter', 'MapCallbackInput', '',
        'Filter map: Map.fromEntries(map.entries.where(callback))'),
    _fn('map_is_empty', 'MapInput', '', 'Is empty: map.isEmpty'),
    _fn('map_length', 'MapInput', '', 'Map size: map.length'),

    // String ↔ collection bridge
    _fn('string_join', 'StringJoinInput', '',
        'Join list of strings: list.join(separator)'),

    // Set — unordered, unique elements
    _fn('set_create', 'ListInput', '', 'Create set from list: Set.from(list)'),
    _fn('set_add', 'SetInput', '', 'Add element: set.add(value)'),
    _fn('set_remove', 'SetInput', '', 'Remove element: set.remove(value)'),
    _fn('set_contains', 'SetInput', '',
        'Contains element: set.contains(value)'),
    _fn('set_union', 'SetBinaryInput', '',
        'Union: left.union(right)'),
    _fn('set_intersection', 'SetBinaryInput', '',
        'Intersection: left.intersection(right)'),
    _fn('set_difference', 'SetBinaryInput', '',
        'Difference: left.difference(right)'),
    _fn('set_length', 'SetInput', '', 'Set size: set.length'),
    _fn('set_is_empty', 'SetInput', '', 'Is empty: set.isEmpty'),
    _fn('set_to_list', 'SetInput', '', 'To list: set.toList()'),
  ]);

  return module;
}

// ============================================================
// Helpers
// ============================================================

const _exprTypeName = '.ball.v1.Expression';

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) => google.DescriptorProto()
  ..name = name
  ..field.addAll(fields);

google.FieldDescriptorProto _exprField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
      ..typeName = _exprTypeName
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

FunctionDefinition _fn(
  String name,
  String inputType,
  String outputType,
  String description,
) => FunctionDefinition()
  ..name = name
  ..inputType = inputType
  ..outputType = outputType
  ..isBase = true
  ..description = description;
