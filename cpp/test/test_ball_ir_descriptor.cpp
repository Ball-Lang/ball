// test_ball_ir_descriptor.cpp — dedicated coverage for the P4 descriptor-WRITE
// builder in ball_ir.h (issue #18).
//
// P4 lets the encoder CONSTRUCT `DescriptorProto`/`EnumDescriptorProto` as
// proto3-JSON WITHOUT libprotobuf's FieldDescriptorProto builders. The existing
// test_ball_ir.cpp only round-trips descriptors PASS-THROUGH (parse → opaque
// `json` → re-emit); it never CONSTRUCTS one, so P4 had zero coverage.
//
// #18 Stage 5 — the google oracle retires with libprotobuf. This test used to
// build the "expected" DescriptorProto with libprotobuf's builders, parse the
// P4 JSON via JsonStringToMessage, and compare via MessageDifferencer. That
// google-equivalence oracle is now replaced by GOLDEN proto3-JSON: the expected
// shape is authored directly from the P4 spec + an INDEPENDENT C++-type→proto-
// type table (below), and the P4 output is asserted equal to it via nlohmann
// JSON equality. No regression value is lost — the golden pins exactly the
// bytes the oracle would have produced, without linking google.
//
// Correctness bar (from the #18 P4 spec): the JSON the hand-rolled builder emits
// must equal the golden DescriptorProto proto3-JSON (snake_case keys, enum
// NAME-strings for `type`/`label`, bare-number `number`, `type_name` on every
// field). ball_ir.h itself stays protobuf-free; this test now does too.

#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include "ball_ir.h"

namespace {

using ball::ir::json;

int g_failures = 0;

void check(bool cond, const std::string& msg) {
  if (!cond) {
    std::cerr << "  FAIL: " << msg << "\n";
    ++g_failures;
  }
}

// The independent oracle for section 2 of the P4 spec: every C++ type spelling
// map_cpp_type_to_proto (encoder.cpp:1376-1401) recognizes, paired with the
// FieldDescriptorProto::Type NAME-STRING it must map to. Encoded here by hand
// (NOT by calling the encoder) so P4's mapCppTypeToProtoTypeName is checked
// against an independent source of truth.
struct TypeCase {
  std::string cppType;
  std::string expected;  // proto enum NAME-string, e.g. "TYPE_INT32"
};

const std::vector<TypeCase>& typeCases() {
  static const std::vector<TypeCase> cases = {
      {"int", "TYPE_INT32"},
      {"int32_t", "TYPE_INT32"},
      {"int32", "TYPE_INT32"},
      {"long", "TYPE_INT64"},
      {"int64_t", "TYPE_INT64"},
      {"long long", "TYPE_INT64"},
      {"unsigned int", "TYPE_UINT32"},
      {"uint32_t", "TYPE_UINT32"},
      {"unsigned long", "TYPE_UINT64"},
      {"uint64_t", "TYPE_UINT64"},
      {"float", "TYPE_FLOAT"},
      {"double", "TYPE_DOUBLE"},
      {"bool", "TYPE_BOOL"},
      {"char", "TYPE_STRING"},
      {"char *", "TYPE_STRING"},
      {"std::string", "TYPE_STRING"},
      {"string", "TYPE_STRING"},
      {"void", "TYPE_BYTES"},
      {"void *", "TYPE_BYTES"},
      // Fallback: anything unrecognized → TYPE_MESSAGE.
      {"MyClass", "TYPE_MESSAGE"},
      {"std::vector<int>", "TYPE_MESSAGE"},
      // `const ` prefix is stripped before matching; type_name keeps the raw
      // spelling.
      {"const int", "TYPE_INT32"},
      {"const std::string", "TYPE_STRING"},
  };
  return cases;
}

// The golden proto3-JSON a single field must serialize to (mirrors
// encode_class_decl: name, number, label, type, raw type_name).
json goldenField(const std::string& name, int number, const TypeCase& tc) {
  json f = json::object();
  f["name"] = name;
  f["number"] = number;
  f["label"] = "LABEL_OPTIONAL";
  f["type"] = tc.expected;
  f["type_name"] = tc.cppType;
  return f;
}

// ── Test 1: every TYPE_* individually ───────────────────────────────────────
void testEachType() {
  for (const auto& tc : typeCases()) {
    ball::ir::descriptor_build::FieldSpec fs;
    fs.name = "f";
    fs.number = 1;
    fs.cppType = tc.cppType;
    json j = ball::ir::descriptor_build::buildDescriptorProto("Msg", {fs});

    // Spec gotcha checks on the RAW JSON:
    //  - snake_case `type_name`, never `typeName`.
    //  - `type`/`label` are enum NAME-STRINGS, never ints.
    //  - `number` is a bare JSON number, never a string.
    const json& fj = j.at("field").at(0);
    check(fj.contains("type_name"), tc.cppType + ": missing snake_case type_name");
    check(!fj.contains("typeName"),
          tc.cppType + ": leaked camelCase typeName key");
    check(fj.at("type_name").get<std::string>() == tc.cppType,
          tc.cppType + ": type_name must be the raw C++ type");
    check(fj.at("type").is_string(),
          tc.cppType + ": type must be an enum name-string, not an int");
    check(fj.at("number").is_number_integer() && !fj.at("number").is_string(),
          tc.cppType + ": number must be a bare JSON number");
    check(fj.at("label").get<std::string>() == "LABEL_OPTIONAL",
          tc.cppType + ": label must be LABEL_OPTIONAL name-string");

    // The mapped `type` must be the oracle's expected NAME-string.
    check(fj.at("type").get<std::string>() == tc.expected,
          tc.cppType + ": mapped to wrong proto type (" +
              fj.at("type").get<std::string>() + " != " + tc.expected + ")");

    // Full golden equality (order-independent nlohmann object compare).
    json golden = json::object();
    golden["name"] = "Msg";
    golden["field"] = json::array({goldenField("f", 1, tc)});
    check(j == golden,
          tc.cppType + ": P4 descriptor JSON != golden\n    got:    " + j.dump() +
              "\n    golden: " + golden.dump());
  }
}

// ── Test 2: a multi-field descriptor (mirrors encode_class_decl end-to-end) ──
void testCompositeDescriptor() {
  json goldenFields = json::array();
  std::vector<ball::ir::descriptor_build::FieldSpec> specs;
  int number = 1;
  for (const auto& tc : typeCases()) {
    const std::string fname = "field" + std::to_string(number);
    goldenFields.push_back(goldenField(fname, number, tc));
    ball::ir::descriptor_build::FieldSpec fs;
    fs.name = fname;
    fs.number = number;
    fs.cppType = tc.cppType;
    specs.push_back(fs);
    ++number;
  }

  json j = ball::ir::descriptor_build::buildDescriptorProto("Composite", specs);
  json golden = json::object();
  golden["name"] = "Composite";
  golden["field"] = std::move(goldenFields);
  check(j == golden, "composite: P4 descriptor JSON != golden");
}

// ── Test 3: an empty-field descriptor omits the `field` key ─────────────────
void testEmptyDescriptor() {
  json j = ball::ir::descriptor_build::buildDescriptorProto("Empty", {});
  check(!j.contains("field"),
        "empty: `field` key must be omitted when there are no fields");
  json golden = json::object();
  golden["name"] = "Empty";
  check(j == golden, "empty: P4 descriptor JSON != golden");
}

// ── Test 4: enum descriptor (mirrors encode_enum_decl) ──────────────────────
// Enum values carry `number` verbatim including the default 0 (proto2 explicit
// presence — the encoder always calls set_number).
void testEnumDescriptor() {
  const std::vector<std::pair<std::string, int>> values = {
      {"RED", 0}, {"GREEN", 1}, {"BLUE", 2}, {"YELLOW", 3}};
  std::vector<ball::ir::descriptor_build::EnumValueSpec> specs;
  json goldenValues = json::array();
  for (const auto& [name, num] : values) {
    specs.push_back({name, num});
    json v = json::object();
    v["name"] = name;
    v["number"] = num;
    goldenValues.push_back(std::move(v));
  }

  json j = ball::ir::descriptor_build::buildEnumDescriptorProto("Color", specs);

  // The default-0 value MUST still carry an explicit "number": 0.
  const json& v0 = j.at("value").at(0);
  check(v0.contains("number") && v0.at("number").is_number_integer(),
        "enum: value 0 must carry an explicit bare-number `number`: 0");
  check(v0.at("number").get<int>() == 0, "enum: value 0 number must be 0");

  json golden = json::object();
  golden["name"] = "Color";
  golden["value"] = std::move(goldenValues);
  check(j == golden, "enum: P4 enum descriptor JSON != golden");
}

}  // namespace

int main() {
  std::cout << "ball_ir P4 descriptor-write builder test\n";
  testEachType();
  testCompositeDescriptor();
  testEmptyDescriptor();
  testEnumDescriptor();
  std::cout << (g_failures == 0 ? "ball_ir_descriptor: ALL PASS\n"
                                : "ball_ir_descriptor: FAILURES\n");
  return g_failures == 0 ? 0 : 1;
}
