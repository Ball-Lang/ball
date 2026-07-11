package compiler

import (
	"fmt"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	descriptorpb "google.golang.org/protobuf/types/descriptorpb"
	structpb "google.golang.org/protobuf/types/known/structpb"
)

// compileModuleTypes emits Go type declarations for a module's typeDefs[] and
// enums[].
//
// Runtime instances of user types flow through the dynamic *ballrt.Message
// (a type tag + ordered field map), so these Go structs are — as in the Rust
// compiler — a faithful, largely documentation-level mapping of the protobuf
// DescriptorProto rather than the concrete carrier of instance state. Every
// field is typed ballrt.Value (the uniform dynamic value), with its original
// protobuf field type preserved in a trailing comment. This keeps emission
// always-valid Go regardless of how exotic the descriptor is, while still
// demonstrating the typeDefs[] → target-type path the SKILL requires.
func (c *Compiler) compileModuleTypes(m *ballv1.Module) string {
	var b strings.Builder
	for _, td := range m.GetTypeDefs() {
		b.WriteString(c.compileTypeDef(td))
	}
	for _, en := range m.GetEnums() {
		b.WriteString(compileEnum(en))
	}
	return b.String()
}

func (c *Compiler) compileTypeDef(td *ballv1.TypeDefinition) string {
	name := sanitize(typeShortName(td.GetName()))
	kind := metaString(td.GetMetadata(), "kind")

	var b strings.Builder
	if desc := td.GetDescription(); desc != "" {
		fmt.Fprintf(&b, "// %s: %s\n", name, singleLine(desc))
	}
	if kind != "" {
		fmt.Fprintf(&b, "// Ball kind: %s\n", kind)
	}
	fields := td.GetDescriptor_().GetField()
	if len(fields) == 0 {
		fmt.Fprintf(&b, "type %s struct{}\n\n", name)
		return b.String()
	}
	fmt.Fprintf(&b, "type %s struct {\n", name)
	for _, fld := range fields {
		fmt.Fprintf(&b, "\t%s ballrt.Value // %s\n", exportedField(fld.GetName()), protoTypeName(fld))
	}
	b.WriteString("}\n\n")
	return b.String()
}

// compileEnum emits a Ball enum (a protobuf EnumDescriptorProto) as a Go typed
// int64 constant group.
func compileEnum(en *descriptorpb.EnumDescriptorProto) string {
	name := sanitize(en.GetName())
	var b strings.Builder
	fmt.Fprintf(&b, "type %s int64\n\n", name)
	values := en.GetValue()
	if len(values) == 0 {
		return b.String()
	}
	b.WriteString("const (\n")
	for _, v := range values {
		fmt.Fprintf(&b, "\t%s_%s %s = %d\n", name, sanitize(v.GetName()), name, v.GetNumber())
	}
	b.WriteString(")\n\n")
	return b.String()
}

// typeShortName strips a module qualifier ("main:Point" → "Point").
func typeShortName(name string) string {
	if i := strings.LastIndex(name, ":"); i >= 0 {
		return name[i+1:]
	}
	return name
}

// exportedField sanitizes a field name for use as a Go struct field.
func exportedField(name string) string {
	s := sanitize(name)
	if s == "" {
		return "Field"
	}
	// Capitalize so struct fields are exported (cosmetic; these are
	// documentation-level types).
	return strings.ToUpper(s[:1]) + s[1:]
}

// protoTypeName renders a field descriptor's protobuf type for the trailing
// comment (e.g. "TYPE_STRING", "repeated TYPE_INT64").
func protoTypeName(f *descriptorpb.FieldDescriptorProto) string {
	t := f.GetType().String()
	if f.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED {
		return "repeated " + t
	}
	if tn := f.GetTypeName(); tn != "" {
		return t + " " + tn
	}
	return t
}

// metaString reads a top-level string field from a metadata Struct.
func metaString(meta *structpb.Struct, key string) string {
	if meta == nil {
		return ""
	}
	if v, ok := meta.GetFields()[key]; ok {
		return v.GetStringValue()
	}
	return ""
}

// singleLine collapses a multi-line description to one comment line.
func singleLine(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " ")
}
