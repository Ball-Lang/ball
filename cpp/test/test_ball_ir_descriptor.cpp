// test_ball_ir_descriptor.cpp — dedicated coverage for the P4 descriptor-WRITE
// builder in ball_ir.h (issue #18).
//
// P4 lets the encoder CONSTRUCT `DescriptorProto`/`EnumDescriptorProto` as
// proto3-JSON WITHOUT libprotobuf's FieldDescriptorProto builders. The existing
// test_ball_ir.cpp only round-trips descriptors PASS-THROUGH (parse → opaque
// `json` → re-emit); it never CONSTRUCTS one, so P4 had zero coverage.
//
// Correctness bar (from the #18 P4 spec): the JSON the hand-rolled builder
// emits must parse via `JsonStringToMessage` into a `DescriptorProto` IDENTICAL
// to the one the current protobuf path builds (the descriptor that
// `MessageToJsonString(preserve_proto_field_names=true)` would serialize in
// CppEncoder::encode_class_decl). This test builds the oracle descriptor with
// an INDEPENDENT expected-type table (mirroring map_cpp_type_to_proto), builds
// the same descriptor via P4, parses the P4 JSON back through protobuf, and
// asserts proto equality — for every TYPE_* and for the enum path.
//
// This test DOES link libprotobuf: it is the ORACLE. ball_ir.h itself stays
// protobuf-free; only the verification oracle here needs Google's runtime.

#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include <google/protobuf/descriptor.pb.h>
#include <google/protobuf/util/json_util.h>
#include <google/protobuf/util/message_differencer.h>

#include "ball_ir.h"

namespace {

using google::protobuf::DescriptorProto;
using google::protobuf::EnumDescriptorProto;
using google::protobuf::FieldDescriptorProto;
using google::protobuf::util::JsonStringToMessage;
using google::protobuf::util::MessageDifferencer;

int g_failures = 0;

void check(bool cond, const std::string& msg) {
  if (!cond) {
    std::cerr << "  FAIL: " << msg << "\n";
    ++g_failures;
  }
}

// The independent oracle for section 2 of the P4 spec: every C++ type spelling
// map_cpp_type_to_proto (encoder.cpp:1376-1401) recognizes, paired with the
// FieldDescriptorProto::Type it must map to. Encoded here by hand (NOT by
// calling the encoder) so P4's mapCppTypeToProtoTypeName is checked against an
// independent source of truth.
struct TypeCase {
  std::string cppType;
  FieldDescriptorProto::Type expected;
};

const std::vector<TypeCase>& typeCases() {
  static const std::vector<TypeCase> cases = {
      {"int", FieldDescriptorProto::TYPE_INT32},
      {"int32_t", FieldDescriptorProto::TYPE_INT32},
      {"int32", FieldDescriptorProto::TYPE_INT32},
      {"long", FieldDescriptorProto::TYPE_INT64},
      {"int64_t", FieldDescriptorProto::TYPE_INT64},
      {"long long", FieldDescriptorProto::TYPE_INT64},
      {"unsigned int", FieldDescriptorProto::TYPE_UINT32},
      {"uint32_t", FieldDescriptorProto::TYPE_UINT32},
      {"unsigned long", FieldDescriptorProto::TYPE_UINT64},
      {"uint64_t", FieldDescriptorProto::TYPE_UINT64},
      {"float", FieldDescriptorProto::TYPE_FLOAT},
      {"double", FieldDescriptorProto::TYPE_DOUBLE},
      {"bool", FieldDescriptorProto::TYPE_BOOL},
      {"char", FieldDescriptorProto::TYPE_STRING},
      {"char *", FieldDescriptorProto::TYPE_STRING},
      {"std::string", FieldDescriptorProto::TYPE_STRING},
      {"string", FieldDescriptorProto::TYPE_STRING},
      {"void", FieldDescriptorProto::TYPE_BYTES},
      {"void *", FieldDescriptorProto::TYPE_BYTES},
      // Fallback: anything unrecognized → TYPE_MESSAGE.
      {"MyClass", FieldDescriptorProto::TYPE_MESSAGE},
      {"std::vector<int>", FieldDescriptorProto::TYPE_MESSAGE},
      // `const ` prefix is stripped before matching; type_name keeps the raw
      // spelling (verified below via oracle set_type_name(cppType)).
      {"const int", FieldDescriptorProto::TYPE_INT32},
      {"const std::string", FieldDescriptorProto::TYPE_STRING},
  };
  return cases;
}

// Adds a field to `d` exactly the way encode_class_decl does (encoder.cpp:
// 213-218): name, number, type (from the oracle table), raw type_name,
// LABEL_OPTIONAL.
void addOracleField(DescriptorProto* d, const std::string& name, int number,
                    const TypeCase& tc) {
  auto* f = d->add_field();
  f->set_name(name);
  f->set_number(number);
  f->set_type(tc.expected);
  f->set_type_name(tc.cppType);
  f->set_label(FieldDescriptorProto::LABEL_OPTIONAL);
}

// Parses a P4-built JSON descriptor back into a DescriptorProto. Fails loud on
// a parse error (a bad enum name-string / wrong number type would throw here —
// exactly what the loader would do in production).
bool parseP4Descriptor(const ball::ir::json& j, DescriptorProto* out,
                       const std::string& ctx) {
  const std::string text = j.dump();
  auto status = JsonStringToMessage(text, out);
  if (!status.ok()) {
    check(false, ctx + ": JsonStringToMessage failed: " +
                     std::string(status.message()) + "  json=" + text);
    return false;
  }
  return true;
}

// ── Test 1: every TYPE_* individually ───────────────────────────────────────
// For each C++ type spelling, build a single-field descriptor via P4 and via
// the oracle, and assert the parsed protos are identical. This is the direct
// "for each TYPE_*" assertion the P4 spec asks for.
void testEachType() {
  for (const auto& tc : typeCases()) {
    DescriptorProto oracle;
    oracle.set_name("Msg");
    addOracleField(&oracle, "f", 1, tc);

    ball::ir::descriptor_build::FieldSpec fs;
    fs.name = "f";
    fs.number = 1;
    fs.cppType = tc.cppType;
    ball::ir::json j =
        ball::ir::descriptor_build::buildDescriptorProto("Msg", {fs});

    // Spec gotcha checks on the RAW JSON (before it is parsed away):
    //  - snake_case `type_name`, never `typeName`.
    //  - `type` is the enum NAME-STRING, never an int.
    //  - `number` is a bare JSON number, never a string.
    //  - `type_name` present on EVERY field incl. scalars, = raw C++ type.
    const ball::ir::json& fj = j.at("field").at(0);
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

    DescriptorProto p4;
    if (!parseP4Descriptor(j, &p4, tc.cppType)) continue;

    // The parsed field's type must be the oracle's expected mapping.
    check(p4.field_size() == 1, tc.cppType + ": expected exactly one field");
    if (p4.field_size() == 1) {
      check(p4.field(0).type() == tc.expected,
            tc.cppType + ": mapped to wrong FieldDescriptorProto::Type (" +
                FieldDescriptorProto::Type_Name(p4.field(0).type()) +
                " != " + FieldDescriptorProto::Type_Name(tc.expected) + ")");
    }

    // Full proto equality vs the protobuf-builder path.
    check(MessageDifferencer::Equals(oracle, p4),
          tc.cppType + ": P4 DescriptorProto != protobuf-path DescriptorProto");
  }
}

// ── Test 2: a multi-field descriptor (mirrors encode_class_decl end-to-end) ──
// Build a single message carrying one field per type case (numbers 1..N, just
// like the encoder's field_number++), then compare P4 vs oracle wholesale.
void testCompositeDescriptor() {
  DescriptorProto oracle;
  oracle.set_name("Composite");
  std::vector<ball::ir::descriptor_build::FieldSpec> specs;
  int number = 1;
  for (const auto& tc : typeCases()) {
    const std::string fname = "field" + std::to_string(number);
    addOracleField(&oracle, fname, number, tc);
    ball::ir::descriptor_build::FieldSpec fs;
    fs.name = fname;
    fs.number = number;
    fs.cppType = tc.cppType;
    specs.push_back(fs);
    ++number;
  }

  ball::ir::json j =
      ball::ir::descriptor_build::buildDescriptorProto("Composite", specs);
  DescriptorProto p4;
  if (parseP4Descriptor(j, &p4, "composite")) {
    check(MessageDifferencer::Equals(oracle, p4),
          "composite: P4 DescriptorProto != protobuf-path DescriptorProto");
  }
}

// ── Test 3: an empty-field descriptor omits the `field` key ─────────────────
void testEmptyDescriptor() {
  DescriptorProto oracle;
  oracle.set_name("Empty");
  ball::ir::json j =
      ball::ir::descriptor_build::buildDescriptorProto("Empty", {});
  check(!j.contains("field"),
        "empty: `field` key must be omitted when there are no fields");
  DescriptorProto p4;
  if (parseP4Descriptor(j, &p4, "empty")) {
    check(MessageDifferencer::Equals(oracle, p4),
          "empty: P4 DescriptorProto != protobuf-path DescriptorProto");
  }
}

// ── Test 4: enum descriptor (mirrors encode_enum_decl) ──────────────────────
// Enum values carry `number` verbatim including the default 0 (proto2 explicit
// presence — the encoder always calls set_number). Build via P4 vs oracle and
// compare.
void testEnumDescriptor() {
  EnumDescriptorProto oracle;
  oracle.set_name("Color");
  const std::vector<std::pair<std::string, int>> values = {
      {"RED", 0}, {"GREEN", 1}, {"BLUE", 2}, {"YELLOW", 3}};
  std::vector<ball::ir::descriptor_build::EnumValueSpec> specs;
  for (const auto& [name, num] : values) {
    auto* v = oracle.add_value();
    v->set_name(name);
    v->set_number(num);
    specs.push_back({name, num});
  }

  ball::ir::json j =
      ball::ir::descriptor_build::buildEnumDescriptorProto("Color", specs);

  // The default-0 value MUST still carry an explicit "number": 0.
  const ball::ir::json& v0 = j.at("value").at(0);
  check(v0.contains("number") && v0.at("number").is_number_integer(),
        "enum: value 0 must carry an explicit bare-number `number`: 0");
  check(v0.at("number").get<int>() == 0, "enum: value 0 number must be 0");

  EnumDescriptorProto p4;
  const std::string text = j.dump();
  auto status = JsonStringToMessage(text, &p4);
  if (!status.ok()) {
    check(false, "enum: JsonStringToMessage failed: " +
                     std::string(status.message()) + "  json=" + text);
    return;
  }
  check(MessageDifferencer::Equals(oracle, p4),
        "enum: P4 EnumDescriptorProto != protobuf-path EnumDescriptorProto");
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
