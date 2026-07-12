package ballrt

import (
	"regexp"
	"strings"
	"sync"
)

// Minimal RegExp support: the self-hosted engine parses cascade/property-op
// clauses with `RegExp(pattern).firstMatch(s)` + `match.group(n)`
// (dart/engine/lib/engine_control_flow.dart). A RegExp is a message tagged
// "RegExp" carrying its pattern; a match is a "RegExpMatch" message carrying its
// groups. Dart patterns here are RE2-compatible (word/space classes, groups,
// anchors), so Go's regexp package handles them directly.

var (
	regexCacheMu sync.Mutex
	regexCache   = map[string]*regexp.Regexp{}
)

// regexPattern extracts the pattern string from a RegExp message.
func regexPattern(self Value) string {
	if m, ok := self.(*Message); ok {
		for _, k := range []string{"arg0", "pattern", "source"} {
			if v, ok := m.Fields.Get(k); ok {
				return ToStr(v)
			}
		}
	}
	return ToStr(self)
}

// compileRegex compiles (and caches) a Go regexp for a Dart pattern.
func compileRegex(pattern string) *regexp.Regexp {
	regexCacheMu.Lock()
	defer regexCacheMu.Unlock()
	if re, ok := regexCache[pattern]; ok {
		return re
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		panic(Thrown{Value: "FormatException: invalid regular expression: " + err.Error()})
	}
	regexCache[pattern] = re
	return re
}

// regexFirstMatch implements RegExp.firstMatch(s): a RegExpMatch message or null.
func regexFirstMatch(self, input Value) Value {
	re := compileRegex(regexPattern(self))
	s := ToStr(input)
	loc := re.FindStringSubmatchIndex(s)
	if loc == nil {
		return nil
	}
	return newRegexMatch(s, loc)
}

// regexHasMatch implements RegExp.hasMatch(s).
func regexHasMatch(self, input Value) Value {
	return compileRegex(regexPattern(self)).MatchString(ToStr(input))
}

// regexAllMatches implements RegExp.allMatches(s): a list of RegExpMatch messages.
func regexAllMatches(self, input Value) Value {
	re := compileRegex(regexPattern(self))
	s := ToStr(input)
	out := NewList()
	for _, loc := range re.FindAllStringSubmatchIndex(s, -1) {
		out.Add(newRegexMatch(s, loc))
	}
	return out
}

// regexStringMatch implements RegExp.stringMatch(s): the matched substring or null.
func regexStringMatch(self, input Value) Value {
	re := compileRegex(regexPattern(self))
	if m := re.FindString(ToStr(input)); m != "" || re.MatchString(ToStr(input)) {
		return m
	}
	return nil
}

// newRegexMatch builds a RegExpMatch message from submatch indices: groups[i] is
// group i's text (null when the group did not participate), plus start/end.
func newRegexMatch(s string, loc []int) Value {
	groups := NewList()
	for i := 0; i*2 < len(loc); i++ {
		start, end := loc[2*i], loc[2*i+1]
		if start < 0 {
			groups.Add(nil)
		} else {
			groups.Add(s[start:end])
		}
	}
	fields := NewMap()
	fields.Set("groups", groups)
	fields.Set("start", int64(loc[0]))
	fields.Set("end", int64(loc[1]))
	fields.Set("input", s)
	return NewMessage("RegExpMatch", fields)
}

// regexGroup implements RegExpMatch.group(n) / match[n].
func regexGroup(self, n Value) Value {
	if m, ok := self.(*Message); ok {
		if g, ok := m.Fields.Get("groups"); ok {
			if l, ok := g.(*List); ok {
				i := int(asFloat(n))
				if i >= 0 && i < len(l.Items) {
					return l.Items[i]
				}
				panic(Thrown{Value: "RangeError: no group " + ToStr(n)})
			}
		}
	}
	return nil
}

// isRegExp reports whether v is a RegExp message.
func isRegExp(v Value) bool {
	m, ok := v.(*Message)
	return ok && messageShortName(m.TypeName) == "RegExp"
}

// regexGroups implements RegExpMatch.groups([indices]) — the listed groups.
func regexGroups(self, indices Value) Value {
	out := NewList()
	for _, idx := range Iterate(indices) {
		out.Add(regexGroup(self, idx))
	}
	return out
}

// regexReplaceAll applies RegExp-based replacement (string.replaceAll(regexp, repl)).
func regexReplaceAll(s Value, re *regexp.Regexp, repl string) Value {
	// Dart uses $1/$2 for group refs; Go uses $1 too, but bare $ needs escaping.
	replGo := strings.ReplaceAll(repl, "$$", "$$$$")
	return re.ReplaceAllString(ToStr(s), replGo)
}
