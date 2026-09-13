package ballrt

// The declared text sink (issue #630): std.sink_create / sink_write /
// sink_to_string.
//
// A sink is a __type__-tagged *Map carrying its accumulated text under
// __buffer__, NOT a *strings.Builder. Two properties depend on that, and both
// fail SILENTLY when a target gets them wrong:
//
//   - TypeOf answers "Sink", because typeOfName already reads a *Map's
//     __type__ tag. A *strings.Builder backing would answer "Builder" here and
//     "String"/"StringBuilder"/"StringIO" on the other targets, so a Ball
//     program branching on type_of would take a different arm per target.
//   - A *Map is a pointer, so an append performed inside a callee is visible to
//     the caller. Go's own docs make this the likely bug — "Do not copy a
//     non-zero Builder" (https://pkg.go.dev/strings#Builder) — and the
//     precedent is issue #300, where a by-value clone lost every list append.
//
// Before #630 this target had no sink at all (`grep -r __buffer__ go/` found
// nothing), so a Ball program using a StringBuffer was refused by the compiler
// even though every self-hosted engine runs one fine.

const (
	ballSinkTag    = "std:Sink"
	ballSinkBuffer = "__buffer__"
)

// SinkCreate implements std.sink_create(initial?) — a new text sink, optionally
// seeded. A nil initial means an empty sink.
func SinkCreate(initial Value) Value {
	m := NewMap()
	m.Set("__type__", ballSinkTag)
	seed := ""
	if initial != nil {
		seed = ToStr(initial)
	}
	m.Set(ballSinkBuffer, seed)
	return m
}

// SinkWrite implements std.sink_write(sink, text) — append text. Returns nil:
// the observable effect is the in-place mutation, which is what makes the sink
// reference-semantic.
func SinkWrite(sink, text Value) Value {
	m := sinkBacking(sink, "sink_write")
	existing := ""
	if cur, ok := m.Get(ballSinkBuffer); ok {
		existing = ToStr(cur)
	}
	m.Set(ballSinkBuffer, existing+ToStr(text))
	return nil
}

// SinkToString implements std.sink_to_string(sink) — the accumulated text, in
// write order.
func SinkToString(sink Value) Value {
	m := sinkBacking(sink, "sink_to_string")
	if cur, ok := m.Get(ballSinkBuffer); ok {
		return ToStr(cur)
	}
	return ""
}

// sinkBacking returns the live backing map of a sink, or panics loudly. Never
// fabricate an empty sink: silently accepting a non-sink turns every mis-routed
// SinkWrite into a discarded write (issue #55's silent-degradation shape).
func sinkBacking(sink Value, function string) *Map {
	if m, ok := sink.(*Map); ok {
		if tag, ok := m.Get("__type__"); ok {
			if name, ok := tag.(string); ok && name == ballSinkTag {
				return m
			}
		}
	}
	panic("ball runtime: std." + function + " expected a sink (std.sink_create), got " + ToStr(TypeOf(sink)))
}
