//! `std_collections` base module builder (issue #35).
//!
//! Ports `dart/shared/lib/std_collections.dart` to Rust. Separate from
//! `std` because not all runtimes expose a mutable collection API (e.g.
//! some WASM targets); the set of operations is large enough to warrant its
//! own module. Depends on `std`.

use crate::descriptor_builders::{base_fn, expr_field, type_def};
use crate::{FunctionDefinition, Module, TypeDefinition};

/// Build the `std_collections` base module.
pub fn build_std_collections_module() -> Module {
    Module {
        name: "std_collections".to_string(),
        description: "Standard collections module. List and map operations. \
            Separate from std because not all runtimes support mutable \
            collections natively."
            .to_string(),
        type_defs: type_defs(),
        functions: functions(),
        ..Default::default()
    }
}

fn type_defs() -> Vec<TypeDefinition> {
    vec![
        type_def(
            "ListInput",
            vec![
                expr_field("list", 1),
                expr_field("index", 2),
                expr_field("value", 3),
            ],
        ),
        type_def(
            "ListCallbackInput",
            vec![expr_field("list", 1), expr_field("callback", 2)],
        ),
        type_def(
            "ListReduceInput",
            vec![
                expr_field("list", 1),
                expr_field("callback", 2),
                expr_field("initial", 3),
            ],
        ),
        type_def(
            "ListSliceInput",
            vec![
                expr_field("list", 1),
                expr_field("start", 2),
                expr_field("end", 3),
            ],
        ),
        type_def(
            "MapInput",
            vec![
                expr_field("map", 1),
                expr_field("key", 2),
                expr_field("value", 3),
            ],
        ),
        type_def(
            "MapCallbackInput",
            vec![expr_field("map", 1), expr_field("callback", 2)],
        ),
        type_def(
            "StringJoinInput",
            vec![expr_field("list", 1), expr_field("separator", 2)],
        ),
        type_def(
            "SetInput",
            vec![expr_field("set", 1), expr_field("value", 2)],
        ),
        type_def(
            "SetCallbackInput",
            vec![expr_field("set", 1), expr_field("callback", 2)],
        ),
        type_def(
            "SetBinaryInput",
            vec![expr_field("left", 1), expr_field("right", 2)],
        ),
    ]
}

fn functions() -> Vec<FunctionDefinition> {
    vec![
        // --- List — indexed, ordered ---
        base_fn(
            "list_push",
            "ListInput",
            "",
            "Append to list: list.add(value)",
        ),
        base_fn(
            "list_pop",
            "ListInput",
            "",
            "Remove last: list.removeLast()",
        ),
        base_fn(
            "list_insert",
            "ListInput",
            "",
            "Insert at index: list.insert(index, value)",
        ),
        base_fn(
            "list_remove_at",
            "ListInput",
            "",
            "Remove at index: list.removeAt(index)",
        ),
        base_fn("list_get", "ListInput", "", "Get element: list[index]"),
        base_fn(
            "list_set",
            "ListInput",
            "",
            "Set element: list[index] = value",
        ),
        base_fn("list_length", "ListInput", "", "List length: list.length"),
        base_fn("list_is_empty", "ListInput", "", "Is empty: list.isEmpty"),
        base_fn("list_first", "ListInput", "", "First element: list.first"),
        base_fn("list_last", "ListInput", "", "Last element: list.last"),
        base_fn(
            "list_single",
            "ListInput",
            "",
            "Single element: list.single",
        ),
        base_fn(
            "list_contains",
            "ListInput",
            "",
            "Contains element: list.contains(value)",
        ),
        base_fn(
            "list_index_of",
            "ListInput",
            "",
            "Index of element: list.indexOf(value)",
        ),
        base_fn(
            "list_map",
            "ListCallbackInput",
            "",
            "Map: list.map(callback)",
        ),
        base_fn(
            "list_filter",
            "ListCallbackInput",
            "",
            "Filter: list.where(callback)",
        ),
        base_fn(
            "list_reduce",
            "ListReduceInput",
            "",
            "Reduce: list.fold(initial, callback)",
        ),
        base_fn(
            "list_find",
            "ListCallbackInput",
            "",
            "Find first: list.firstWhere(callback)",
        ),
        base_fn(
            "list_any",
            "ListCallbackInput",
            "",
            "Any match: list.any(callback)",
        ),
        base_fn(
            "list_all",
            "ListCallbackInput",
            "",
            "All match: list.every(callback)",
        ),
        base_fn(
            "list_none",
            "ListCallbackInput",
            "",
            "None match: !list.any(callback)",
        ),
        base_fn(
            "list_sort",
            "ListCallbackInput",
            "",
            "Sort: list.sort(compare)",
        ),
        base_fn(
            "list_sort_by",
            "ListCallbackInput",
            "",
            "Sort by key: list.sort((a,b) => key(a).compareTo(key(b)))",
        ),
        base_fn(
            "list_reverse",
            "ListInput",
            "",
            "Reverse: list.reversed.toList()",
        ),
        base_fn(
            "list_slice",
            "ListSliceInput",
            "",
            "Slice: list.sublist(start, end)",
        ),
        base_fn(
            "list_flat_map",
            "ListCallbackInput",
            "",
            "Flat map: list.expand(callback)",
        ),
        base_fn(
            "list_zip",
            "ListInput",
            "",
            "Zip two lists: zip(list, other)",
        ),
        base_fn("list_take", "ListInput", "", "Take N: list.take(n)"),
        base_fn("list_drop", "ListInput", "", "Drop N: list.skip(n)"),
        base_fn(
            "list_concat",
            "ListInput",
            "",
            "Concat two lists: list + other",
        ),
        // --- Map — key/value ---
        base_fn("map_get", "MapInput", "", "Get value: map[key]"),
        base_fn("map_set", "MapInput", "", "Set value: map[key] = value"),
        base_fn("map_delete", "MapInput", "", "Delete key: map.remove(key)"),
        base_fn(
            "map_contains_key",
            "MapInput",
            "",
            "Contains key: map.containsKey(key)",
        ),
        base_fn("map_keys", "MapInput", "", "All keys: map.keys"),
        base_fn("map_values", "MapInput", "", "All values: map.values"),
        base_fn("map_entries", "MapInput", "", "All entries: map.entries"),
        base_fn(
            "map_from_entries",
            "ListInput",
            "",
            "Map from entries: Map.fromEntries(list)",
        ),
        base_fn("map_merge", "MapInput", "", "Merge two maps: {...a, ...b}"),
        base_fn(
            "map_map",
            "MapCallbackInput",
            "",
            "Map over map: map.map(callback)",
        ),
        base_fn(
            "map_filter",
            "MapCallbackInput",
            "",
            "Filter map: Map.fromEntries(map.entries.where(callback))",
        ),
        base_fn("map_is_empty", "MapInput", "", "Is empty: map.isEmpty"),
        base_fn("map_length", "MapInput", "", "Map size: map.length"),
        // --- String <-> collection bridge ---
        base_fn(
            "string_join",
            "StringJoinInput",
            "",
            "Join list of strings: list.join(separator)",
        ),
        // --- Set — unordered, unique elements ---
        base_fn(
            "set_create",
            "ListInput",
            "",
            "Create set from list: Set.from(list)",
        ),
        base_fn("set_add", "SetInput", "", "Add element: set.add(value)"),
        base_fn(
            "set_remove",
            "SetInput",
            "",
            "Remove element: set.remove(value)",
        ),
        base_fn(
            "set_contains",
            "SetInput",
            "",
            "Contains element: set.contains(value)",
        ),
        base_fn(
            "set_union",
            "SetBinaryInput",
            "",
            "Union: left.union(right)",
        ),
        base_fn(
            "set_intersection",
            "SetBinaryInput",
            "",
            "Intersection: left.intersection(right)",
        ),
        base_fn(
            "set_difference",
            "SetBinaryInput",
            "",
            "Difference: left.difference(right)",
        ),
        base_fn("set_length", "SetInput", "", "Set size: set.length"),
        base_fn("set_is_empty", "SetInput", "", "Is empty: set.isEmpty"),
        base_fn("set_to_list", "SetInput", "", "To list: set.toList()"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_function_is_base_with_no_body() {
        let module = build_std_collections_module();
        assert_eq!(module.name, "std_collections");
        for function in &module.functions {
            assert!(function.is_base, "{} must be is_base", function.name);
            assert!(
                function.body.is_none(),
                "{} must have no body",
                function.name
            );
        }
    }

    #[test]
    fn function_count_matches_std_json() {
        let module = build_std_collections_module();
        assert_eq!(module.functions.len(), 53);
    }
}
