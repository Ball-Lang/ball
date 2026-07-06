// ball_ir.h — lightweight, protobuf-free C++ representation of the Ball IR.
//
// This is the foundation of the "drop google::protobuf" effort (#18): it mirrors
// the message types in `proto/ball/v1/ball.proto`, but is loaded directly from
// `.ball.json` (proto3-JSON) via nlohmann/json — no libprotobuf, no abseil, no
// generated `ball.pb.{cc,h}`.
//
// Semantic fields (the expression tree, signatures, module structure) are typed;
// cosmetic/WKT payloads (`google.protobuf.Struct metadata`, the type
// `DescriptorProto`) are kept as `nlohmann::json` — they are read opaquely by
// the compiler/engine and need no structural typing here.
//
// Field lookups accept both proto3-JSON camelCase (the canonical encoder output,
// e.g. `entryModule`, `intValue`) and snake_case, so any Ball JSON parses.
#pragma once

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace ball::ir {

using json = nlohmann::json;

// ── JSON field-access helpers (camelCase ‖ snake_case) ──────────────────────

// Returns a pointer to `obj[camel]` or `obj[snake]` if present, else nullptr.
inline const json* getField(const json& obj, const char* camel,
                            const char* snake) {
  if (!obj.is_object()) return nullptr;
  auto it = obj.find(camel);
  if (it != obj.end()) return &*it;
  if (snake != nullptr) {
    it = obj.find(snake);
    if (it != obj.end()) return &*it;
  }
  return nullptr;
}

inline std::string getStr(const json& obj, const char* camel,
                          const char* snake = nullptr) {
  const json* f = getField(obj, camel, snake);
  return (f != nullptr && f->is_string()) ? f->get<std::string>()
                                          : std::string{};
}

inline bool getBool(const json& obj, const char* camel,
                    const char* snake = nullptr) {
  const json* f = getField(obj, camel, snake);
  return (f != nullptr && f->is_boolean()) && f->get<bool>();
}

// ── Forward declarations ────────────────────────────────────────────────────

struct Expression;
struct FunctionDefinition;
using ExpressionPtr = std::unique_ptr<Expression>;

// ── Type system ─────────────────────────────────────────────────────────────

struct TypeRef {
  std::string name;
  std::vector<TypeRef> typeArgs;
  bool nullable = false;
};

struct TypeParameter {
  std::string name;
  json metadata;  // Struct (opaque)
};

struct TypeDefinition {
  std::string name;
  json descriptor;  // google.protobuf.DescriptorProto (opaque)
  std::vector<TypeParameter> typeParams;
  std::string description;
  json metadata;  // Struct (opaque)
};

struct TypeAlias {
  std::string name;
  std::string targetType;
  std::vector<TypeParameter> typeParams;
  json metadata;
};

// ── Expression variants ─────────────────────────────────────────────────────

struct FunctionCall {
  std::string module;
  std::string function;
  ExpressionPtr input;  // may be null
  std::vector<TypeRef> typeArgs;
};

enum class LiteralKind {
  Unset,
  Int,
  Double,
  String,
  Bool,
  Bytes,
  List,
};

struct Literal {
  LiteralKind kind = LiteralKind::Unset;
  int64_t intValue = 0;
  double doubleValue = 0.0;
  std::string stringValue;
  bool boolValue = false;
  std::string bytesValue;  // base64 as in proto3-JSON
  std::vector<Expression> listElements;
};

struct Reference {
  std::string name;
};

struct FieldAccess {
  ExpressionPtr object;  // may be null
  std::string field;
};

struct FieldValuePair {
  std::string name;
  ExpressionPtr value;  // may be null
};

struct MessageCreation {
  std::string typeName;
  std::vector<FieldValuePair> fields;
  json metadata;  // Struct (opaque)
};

struct LetBinding {
  std::string name;
  ExpressionPtr value;  // may be null
  json metadata;        // Struct (opaque)
};

enum class StatementKind { Unset, Let, Expr };

struct Statement {
  StatementKind kind = StatementKind::Unset;
  std::unique_ptr<LetBinding> let;
  ExpressionPtr expr;
};

struct Block {
  std::vector<Statement> statements;
  ExpressionPtr result;  // may be null
};

enum class ExprKind {
  Unset,
  Call,
  Literal,
  Reference,
  FieldAccess,
  MessageCreation,
  Block,
  Lambda,
};

struct Expression {
  ExprKind kind = ExprKind::Unset;
  std::unique_ptr<FunctionCall> call;
  std::unique_ptr<Literal> literal;
  std::unique_ptr<Reference> reference;
  std::unique_ptr<FieldAccess> fieldAccess;
  std::unique_ptr<MessageCreation> messageCreation;
  std::unique_ptr<Block> block;
  std::unique_ptr<FunctionDefinition> lambda;
};

struct FunctionDefinition {
  std::string name;
  std::string inputType;
  std::string outputType;
  ExpressionPtr body;  // null for base functions
  std::string description;
  bool isBase = false;
  json metadata;  // Struct (opaque)
};

struct Constant {
  std::string name;
  std::string type;
  ExpressionPtr value;
  json metadata;
};

// ── Module / Program ────────────────────────────────────────────────────────

struct ModuleImport {
  std::string name;
  std::string integrity;
  json metadata;
  // The `source` oneof (http/file/inline/git/registry) is kept as raw JSON;
  // the loader/resolver consumes it opaquely.
  json source;
};

struct Module {
  std::string name;
  std::string description;
  std::vector<FunctionDefinition> functions;
  std::vector<ModuleImport> moduleImports;
  std::vector<TypeDefinition> typeDefs;
  std::vector<TypeAlias> typeAliases;
  std::vector<Constant> moduleConstants;
  json enums;   // repeated EnumDescriptorProto (opaque)
  json assets;  // repeated ModuleAsset (opaque)
  json metadata;
};

struct Program {
  std::string name;
  std::string version;
  std::vector<Module> modules;
  std::string entryModule;
  std::string entryFunction;
  json metadata;

  // Convenience: find a module by name, or nullptr.
  const Module* findModule(const std::string& moduleName) const {
    for (const auto& m : modules) {
      if (m.name == moduleName) return &m;
    }
    return nullptr;
  }
};

// ── Parser (proto3-JSON → ball::ir) ─────────────────────────────────────────

Expression parseExpression(const json& j);
FunctionDefinition parseFunction(const json& j);

inline TypeRef parseTypeRef(const json& j) {
  TypeRef t;
  t.name = getStr(j, "name");
  t.nullable = getBool(j, "nullable");
  if (const json* args = getField(j, "typeArgs", "type_args");
      args != nullptr && args->is_array()) {
    for (const auto& a : *args) t.typeArgs.push_back(parseTypeRef(a));
  }
  return t;
}

inline TypeParameter parseTypeParameter(const json& j) {
  TypeParameter p;
  p.name = getStr(j, "name");
  if (const json* m = getField(j, "metadata", nullptr)) p.metadata = *m;
  return p;
}

inline TypeAlias parseTypeAlias(const json& j) {
  TypeAlias t;
  t.name = getStr(j, "name");
  t.targetType = getStr(j, "targetType", "target_type");
  if (const json* m = getField(j, "metadata", nullptr)) t.metadata = *m;
  if (const json* tp = getField(j, "typeParams", "type_params");
      tp != nullptr && tp->is_array()) {
    for (const auto& p : *tp) t.typeParams.push_back(parseTypeParameter(p));
  }
  return t;
}

inline Literal parseLiteral(const json& j) {
  Literal lit;
  // proto3-JSON: int64 is emitted as a string; double/bool/string as native.
  if (const json* f = getField(j, "intValue", "int_value")) {
    lit.kind = LiteralKind::Int;
    lit.intValue = f->is_string() ? std::stoll(f->get<std::string>())
                                  : f->get<int64_t>();
  } else if (const json* d = getField(j, "doubleValue", "double_value")) {
    lit.kind = LiteralKind::Double;
    lit.doubleValue = d->is_string() ? std::stod(d->get<std::string>())
                                     : d->get<double>();
  } else if (const json* s = getField(j, "stringValue", "string_value")) {
    lit.kind = LiteralKind::String;
    lit.stringValue = s->get<std::string>();
  } else if (const json* b = getField(j, "boolValue", "bool_value")) {
    lit.kind = LiteralKind::Bool;
    lit.boolValue = b->get<bool>();
  } else if (const json* by = getField(j, "bytesValue", "bytes_value")) {
    lit.kind = LiteralKind::Bytes;
    lit.bytesValue = by->get<std::string>();
  } else if (const json* lst = getField(j, "listValue", "list_value")) {
    lit.kind = LiteralKind::List;
    if (const json* els = getField(*lst, "elements", nullptr);
        els != nullptr && els->is_array()) {
      for (const auto& e : *els) lit.listElements.push_back(parseExpression(e));
    }
  }
  return lit;
}

inline LetBinding parseLet(const json& j) {
  LetBinding b;
  b.name = getStr(j, "name");
  if (const json* v = getField(j, "value", nullptr))
    b.value = std::make_unique<Expression>(parseExpression(*v));
  if (const json* m = getField(j, "metadata", nullptr)) b.metadata = *m;
  return b;
}

inline Statement parseStatement(const json& j) {
  Statement s;
  if (const json* l = getField(j, "let", nullptr)) {
    s.kind = StatementKind::Let;
    s.let = std::make_unique<LetBinding>(parseLet(*l));
  } else if (const json* e = getField(j, "expression", nullptr)) {
    s.kind = StatementKind::Expr;
    s.expr = std::make_unique<Expression>(parseExpression(*e));
  }
  return s;
}

inline Expression parseExpression(const json& j) {
  Expression e;
  if (!j.is_object()) return e;
  if (const json* c = getField(j, "call", nullptr)) {
    e.kind = ExprKind::Call;
    auto fc = std::make_unique<FunctionCall>();
    fc->module = getStr(*c, "module");
    fc->function = getStr(*c, "function");
    if (const json* in = getField(*c, "input", nullptr))
      fc->input = std::make_unique<Expression>(parseExpression(*in));
    if (const json* ta = getField(*c, "typeArgs", "type_args");
        ta != nullptr && ta->is_array()) {
      for (const auto& t : *ta) fc->typeArgs.push_back(parseTypeRef(t));
    }
    e.call = std::move(fc);
  } else if (const json* l = getField(j, "literal", nullptr)) {
    e.kind = ExprKind::Literal;
    e.literal = std::make_unique<Literal>(parseLiteral(*l));
  } else if (const json* r = getField(j, "reference", nullptr)) {
    e.kind = ExprKind::Reference;
    e.reference = std::make_unique<Reference>(Reference{getStr(*r, "name")});
  } else if (const json* fa = getField(j, "fieldAccess", "field_access")) {
    e.kind = ExprKind::FieldAccess;
    auto f = std::make_unique<FieldAccess>();
    if (const json* o = getField(*fa, "object", nullptr))
      f->object = std::make_unique<Expression>(parseExpression(*o));
    f->field = getStr(*fa, "field");
    e.fieldAccess = std::move(f);
  } else if (const json* mc = getField(j, "messageCreation",
                                       "message_creation")) {
    e.kind = ExprKind::MessageCreation;
    auto m = std::make_unique<MessageCreation>();
    m->typeName = getStr(*mc, "typeName", "type_name");
    if (const json* flds = getField(*mc, "fields", nullptr);
        flds != nullptr && flds->is_array()) {
      for (const auto& fp : *flds) {
        FieldValuePair pair;
        pair.name = getStr(fp, "name");
        if (const json* v = getField(fp, "value", nullptr))
          pair.value = std::make_unique<Expression>(parseExpression(*v));
        m->fields.push_back(std::move(pair));
      }
    }
    if (const json* md = getField(*mc, "metadata", nullptr)) m->metadata = *md;
    e.messageCreation = std::move(m);
  } else if (const json* bl = getField(j, "block", nullptr)) {
    e.kind = ExprKind::Block;
    auto b = std::make_unique<Block>();
    if (const json* st = getField(*bl, "statements", nullptr);
        st != nullptr && st->is_array()) {
      for (const auto& s : *st) b->statements.push_back(parseStatement(s));
    }
    if (const json* res = getField(*bl, "result", nullptr))
      b->result = std::make_unique<Expression>(parseExpression(*res));
    e.block = std::move(b);
  } else if (const json* lam = getField(j, "lambda", nullptr)) {
    e.kind = ExprKind::Lambda;
    e.lambda = std::make_unique<FunctionDefinition>(parseFunction(*lam));
  }
  return e;
}

inline FunctionDefinition parseFunction(const json& j) {
  FunctionDefinition f;
  f.name = getStr(j, "name");
  f.inputType = getStr(j, "inputType", "input_type");
  f.outputType = getStr(j, "outputType", "output_type");
  f.description = getStr(j, "description");
  f.isBase = getBool(j, "isBase", "is_base");
  if (const json* b = getField(j, "body", nullptr))
    f.body = std::make_unique<Expression>(parseExpression(*b));
  if (const json* m = getField(j, "metadata", nullptr)) f.metadata = *m;
  return f;
}

inline TypeDefinition parseTypeDefinition(const json& j) {
  TypeDefinition t;
  t.name = getStr(j, "name");
  t.description = getStr(j, "description");
  if (const json* d = getField(j, "descriptor", nullptr)) t.descriptor = *d;
  if (const json* m = getField(j, "metadata", nullptr)) t.metadata = *m;
  if (const json* tp = getField(j, "typeParams", "type_params");
      tp != nullptr && tp->is_array()) {
    for (const auto& p : *tp) t.typeParams.push_back(parseTypeParameter(p));
  }
  return t;
}

inline Constant parseConstant(const json& j) {
  Constant c;
  c.name = getStr(j, "name");
  c.type = getStr(j, "type");
  if (const json* v = getField(j, "value", nullptr))
    c.value = std::make_unique<Expression>(parseExpression(*v));
  if (const json* m = getField(j, "metadata", nullptr)) c.metadata = *m;
  return c;
}

inline Module parseModule(const json& j) {
  Module m;
  m.name = getStr(j, "name");
  m.description = getStr(j, "description");
  if (const json* fns = getField(j, "functions", nullptr);
      fns != nullptr && fns->is_array()) {
    for (const auto& f : *fns) m.functions.push_back(parseFunction(f));
  }
  if (const json* imps = getField(j, "moduleImports", "module_imports");
      imps != nullptr && imps->is_array()) {
    for (const auto& i : *imps) {
      ModuleImport mi;
      mi.name = getStr(i, "name");
      mi.integrity = getStr(i, "integrity");
      if (const json* md = getField(i, "metadata", nullptr)) mi.metadata = *md;
      mi.source = i;  // keep the whole import for opaque source resolution
      m.moduleImports.push_back(std::move(mi));
    }
  }
  if (const json* tds = getField(j, "typeDefs", "type_defs");
      tds != nullptr && tds->is_array()) {
    for (const auto& t : *tds) m.typeDefs.push_back(parseTypeDefinition(t));
  }
  if (const json* tas = getField(j, "typeAliases", "type_aliases");
      tas != nullptr && tas->is_array()) {
    for (const auto& t : *tas) m.typeAliases.push_back(parseTypeAlias(t));
  }
  if (const json* cs = getField(j, "moduleConstants", "module_constants");
      cs != nullptr && cs->is_array()) {
    for (const auto& c : *cs) m.moduleConstants.push_back(parseConstant(c));
  }
  if (const json* en = getField(j, "enums", nullptr)) m.enums = *en;
  if (const json* as = getField(j, "assets", nullptr)) m.assets = *as;
  if (const json* md = getField(j, "metadata", nullptr)) m.metadata = *md;
  return m;
}

inline Program parseProgram(const json& j) {
  Program p;
  // A google.protobuf.Any envelope wrapping a non-well-known message (like
  // ball.v1.Program) uses proto3-JSON's "merged" representation: the
  // payload's own fields sit directly alongside "@type" at the SAME level
  // (unlike Any-wrapping a well-known type such as Duration/Timestamp/
  // Struct, whose JSON form nests the payload under a "value" key). So
  // there is nothing to unwrap -- getField()'s by-name lookups simply skip
  // the unrecognized "@type" key and find "name"/"modules"/etc. right next
  // to it (verified: all 321 tests/conformance/*.ball.json fixtures carry
  // this exact envelope shape and parse correctly today).
  const json* root = &j;
  // An envelope IS still a type declaration, though: fail loud if it names
  // something other than Program (e.g. a Module file handed to the wrong
  // loader) instead of silently parsing an empty/garbage Program from it —
  // the class of bug issue #55 hid (see CLAUDE.md's "fail loud" mandate).
  if (j.is_object()) {
    if (auto it = j.find("@type"); it != j.end() && it->is_string()) {
      const std::string& url = it->get_ref<const std::string&>();
      if (!url.ends_with("/ball.v1.Program")) {
        throw std::runtime_error(
            "ball::ir::parseProgram: envelope @type is not ball.v1.Program: " +
            url);
      }
    }
  }
  p.name = getStr(*root, "name");
  p.version = getStr(*root, "version");
  p.entryModule = getStr(*root, "entryModule", "entry_module");
  p.entryFunction = getStr(*root, "entryFunction", "entry_function");
  if (const json* mods = getField(*root, "modules", nullptr);
      mods != nullptr && mods->is_array()) {
    for (const auto& m : *mods) p.modules.push_back(parseModule(m));
  }
  if (const json* md = getField(*root, "metadata", nullptr)) p.metadata = *md;
  return p;
}

// Parse a `.ball.json` string into a Program (throws nlohmann::json::exception
// on malformed JSON).
inline Program parseProgramString(const std::string& jsonText) {
  return parseProgram(json::parse(jsonText));
}

// ── Serializer (ball::ir → proto3-JSON) ─────────────────────────────────────
//
// Mirrors each parseX with a toJson overload. Omits default-valued scalar/
// array fields (proto3-JSON's textbook default-omission convention: an
// empty string/false/empty array is not written) — this matches the REAL
// corpus for the overwhelming common case (e.g. base functions never carry
// "outputType"/"inputType" at all). int64 fields are serialized as JSON
// strings (proto3-JSON's own int64 convention, mirrored from parseLiteral
// above); opaque `json` fields (metadata/descriptor/enums/assets/
// ModuleImport::source) are emitted exactly as parsed — omitted only when
// never present in the source (`is_null()`), which the parser guarantees is
// a faithful presence signal (it only ever assigns them when the source
// key exists).
//
// ball::ir's plain (non-optional) struct fields cannot distinguish "omitted"
// from "present at the zero value" once parsed, and the real corpus is
// occasionally inconsistent about which shape a given call site uses for
// the SAME field (e.g. some MessageCreation.typeName values are explicit ""
// while others of the identical shape omit the key entirely) — a handful of
// these are real, narrow ambiguities (documented + normalized on the
// round-trip test in test_ball_ir.cpp, not guessed at here). Byte-for-byte
// fidelity for every such case would need presence-tracking (e.g.
// std::optional<T>) added to ball::ir's field types — a bigger design change
// left for a future pass; see test_ball_ir.cpp's roundtrip result for the
// current (high, not 100%) match rate against the whole conformance corpus.

json toJson(const Expression& e);
json toJson(const FunctionDefinition& f);

inline json toJson(const TypeParameter& p) {
  json j = json::object();
  j["name"] = p.name;
  if (!p.metadata.is_null()) j["metadata"] = p.metadata;
  return j;
}

inline json toJson(const TypeRef& t) {
  json j = json::object();
  j["name"] = t.name;
  if (t.nullable) j["nullable"] = true;
  if (!t.typeArgs.empty()) {
    json arr = json::array();
    for (const auto& a : t.typeArgs) arr.push_back(toJson(a));
    j["typeArgs"] = std::move(arr);
  }
  return j;
}

inline json toJson(const Literal& lit) {
  json j = json::object();
  switch (lit.kind) {
    case LiteralKind::Int:
      j["intValue"] = std::to_string(lit.intValue);
      break;
    case LiteralKind::Double:
      j["doubleValue"] = lit.doubleValue;
      break;
    case LiteralKind::String:
      j["stringValue"] = lit.stringValue;
      break;
    case LiteralKind::Bool:
      j["boolValue"] = lit.boolValue;
      break;
    case LiteralKind::Bytes:
      j["bytesValue"] = lit.bytesValue;
      break;
    case LiteralKind::List: {
      json lv = json::object();
      if (!lit.listElements.empty()) {
        json elements = json::array();
        for (const auto& el : lit.listElements) elements.push_back(toJson(el));
        lv["elements"] = std::move(elements);
      }
      j["listValue"] = std::move(lv);
      break;
    }
    case LiteralKind::Unset:
      break;
  }
  return j;
}

inline json toJson(const LetBinding& b) {
  json j = json::object();
  j["name"] = b.name;
  if (b.value) j["value"] = toJson(*b.value);
  if (!b.metadata.is_null()) j["metadata"] = b.metadata;
  return j;
}

inline json toJson(const Statement& s) {
  json j = json::object();
  switch (s.kind) {
    case StatementKind::Let:
      if (s.let) j["let"] = toJson(*s.let);
      break;
    case StatementKind::Expr:
      if (s.expr) j["expression"] = toJson(*s.expr);
      break;
    case StatementKind::Unset:
      break;
  }
  return j;
}

inline json toJson(const Expression& e) {
  json j = json::object();
  switch (e.kind) {
    case ExprKind::Call: {
      json c = json::object();
      if (!e.call->module.empty()) c["module"] = e.call->module;
      c["function"] = e.call->function;
      if (e.call->input) c["input"] = toJson(*e.call->input);
      if (!e.call->typeArgs.empty()) {
        json ta = json::array();
        for (const auto& t : e.call->typeArgs) ta.push_back(toJson(t));
        c["typeArgs"] = std::move(ta);
      }
      j["call"] = std::move(c);
      break;
    }
    case ExprKind::Literal:
      j["literal"] = toJson(*e.literal);
      break;
    case ExprKind::Reference: {
      json r = json::object();
      r["name"] = e.reference->name;
      j["reference"] = std::move(r);
      break;
    }
    case ExprKind::FieldAccess: {
      json fa = json::object();
      if (e.fieldAccess->object) fa["object"] = toJson(*e.fieldAccess->object);
      fa["field"] = e.fieldAccess->field;
      j["fieldAccess"] = std::move(fa);
      break;
    }
    case ExprKind::MessageCreation: {
      json mc = json::object();
      // typeName is NOT omitted when empty: an empty string is a meaningful
      // sentinel ("anonymous/inline" message creation, per ball.proto's own
      // field comment), not an unset-default -- the real encoder always
      // writes it explicitly, verified against the conformance corpus.
      mc["typeName"] = e.messageCreation->typeName;
      if (!e.messageCreation->fields.empty()) {
        json fields = json::array();
        for (const auto& fp : e.messageCreation->fields) {
          json fpj = json::object();
          fpj["name"] = fp.name;
          if (fp.value) fpj["value"] = toJson(*fp.value);
          fields.push_back(std::move(fpj));
        }
        mc["fields"] = std::move(fields);
      }
      const json& mcMeta = e.messageCreation->metadata;
      if (!mcMeta.is_null()) mc["metadata"] = mcMeta;
      j["messageCreation"] = std::move(mc);
      break;
    }
    case ExprKind::Block: {
      json bl = json::object();
      if (!e.block->statements.empty()) {
        json st = json::array();
        for (const auto& s : e.block->statements) st.push_back(toJson(s));
        bl["statements"] = std::move(st);
      }
      if (e.block->result) bl["result"] = toJson(*e.block->result);
      j["block"] = std::move(bl);
      break;
    }
    case ExprKind::Lambda:
      j["lambda"] = toJson(*e.lambda);
      break;
    case ExprKind::Unset:
      break;
  }
  return j;
}

inline json toJson(const FunctionDefinition& f) {
  json j = json::object();
  j["name"] = f.name;
  if (!f.inputType.empty()) j["inputType"] = f.inputType;
  if (!f.outputType.empty()) j["outputType"] = f.outputType;
  if (f.body) j["body"] = toJson(*f.body);
  if (!f.description.empty()) j["description"] = f.description;
  if (f.isBase) j["isBase"] = true;
  if (!f.metadata.is_null()) j["metadata"] = f.metadata;
  return j;
}

inline json toJson(const TypeDefinition& t) {
  json j = json::object();
  j["name"] = t.name;
  if (!t.description.empty()) j["description"] = t.description;
  if (!t.descriptor.is_null()) j["descriptor"] = t.descriptor;
  if (!t.metadata.is_null()) j["metadata"] = t.metadata;
  if (!t.typeParams.empty()) {
    json tp = json::array();
    for (const auto& p : t.typeParams) tp.push_back(toJson(p));
    j["typeParams"] = std::move(tp);
  }
  return j;
}

inline json toJson(const TypeAlias& t) {
  json j = json::object();
  j["name"] = t.name;
  if (!t.targetType.empty()) j["targetType"] = t.targetType;
  if (!t.typeParams.empty()) {
    json tp = json::array();
    for (const auto& p : t.typeParams) tp.push_back(toJson(p));
    j["typeParams"] = std::move(tp);
  }
  if (!t.metadata.is_null()) j["metadata"] = t.metadata;
  return j;
}

inline json toJson(const Constant& c) {
  json j = json::object();
  j["name"] = c.name;
  if (!c.type.empty()) j["type"] = c.type;
  if (c.value) j["value"] = toJson(*c.value);
  if (!c.metadata.is_null()) j["metadata"] = c.metadata;
  return j;
}

inline json toJson(const ModuleImport& mi) {
  // `source` holds the whole original import object (the http/file/inline/
  // git/registry oneof is kept opaque) -- start from a copy of it and
  // overlay the typed fields, so whichever `source` variant was present is
  // preserved verbatim.
  json j = mi.source.is_object() ? mi.source : json::object();
  j["name"] = mi.name;
  if (!mi.integrity.empty()) j["integrity"] = mi.integrity;
  if (!mi.metadata.is_null()) j["metadata"] = mi.metadata;
  return j;
}

inline json toJson(const Module& m) {
  json j = json::object();
  j["name"] = m.name;
  if (!m.description.empty()) j["description"] = m.description;
  if (!m.functions.empty()) {
    json fns = json::array();
    for (const auto& f : m.functions) fns.push_back(toJson(f));
    j["functions"] = std::move(fns);
  }
  if (!m.moduleImports.empty()) {
    json imps = json::array();
    for (const auto& i : m.moduleImports) imps.push_back(toJson(i));
    j["moduleImports"] = std::move(imps);
  }
  if (!m.typeDefs.empty()) {
    json tds = json::array();
    for (const auto& t : m.typeDefs) tds.push_back(toJson(t));
    j["typeDefs"] = std::move(tds);
  }
  if (!m.typeAliases.empty()) {
    json tas = json::array();
    for (const auto& t : m.typeAliases) tas.push_back(toJson(t));
    j["typeAliases"] = std::move(tas);
  }
  if (!m.moduleConstants.empty()) {
    json cs = json::array();
    for (const auto& c : m.moduleConstants) cs.push_back(toJson(c));
    j["moduleConstants"] = std::move(cs);
  }
  if (!m.enums.is_null()) j["enums"] = m.enums;
  if (!m.assets.is_null()) j["assets"] = m.assets;
  if (!m.metadata.is_null()) j["metadata"] = m.metadata;
  return j;
}

inline json toJson(const Program& p) {
  json j = json::object();
  j["name"] = p.name;
  if (!p.version.empty()) j["version"] = p.version;
  if (!p.modules.empty()) {
    json mods = json::array();
    for (const auto& m : p.modules) mods.push_back(toJson(m));
    j["modules"] = std::move(mods);
  }
  if (!p.entryModule.empty()) j["entryModule"] = p.entryModule;
  if (!p.entryFunction.empty()) j["entryFunction"] = p.entryFunction;
  if (!p.metadata.is_null()) j["metadata"] = p.metadata;
  return j;
}

// Serializes a Program back to a proto3-JSON string, wrapped in the
// self-describing google.protobuf.Any envelope ball_file.h/parseProgram
// expect (`{"@type": "type.googleapis.com/ball.v1.Program", <fields>}`).
// `indent < 0` (the default) produces compact output; `indent >= 0` pretty-
// prints with that many spaces (mirrors nlohmann::json::dump).
inline std::string programToJsonString(const Program& p, int indent = -1) {
  json j = toJson(p);
  // Matches ball::kProgramTypeUrl in ball_file.h -- duplicated rather than
  // shared because ball_ir.h is deliberately protobuf/nlohmann-only and
  // must not #include ball_file.h (which pulls in libprotobuf headers).
  j["@type"] = "type.googleapis.com/ball.v1.Program";
  return j.dump(indent);
}

}  // namespace ball::ir
