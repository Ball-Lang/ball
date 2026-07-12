package ballrt

import (
	"strings"
	"time"
)

// Minimal DateTime support: the self-hosted engine reads
// `DateTime.now().millisecondsSinceEpoch` for its execution-timeout tracking
// (dart/engine/lib/engine.dart). A DateTime is a message carrying the epoch
// millis field the engine reads; timing never affects stdout, so real wall-clock
// time is fine.

func dateTimeNow() Value {
	return dateTimeFromMillis(time.Now().UnixMilli())
}

func dateTimeFromMillis(millis int64) Value {
	fields := NewMap()
	fields.Set("millisecondsSinceEpoch", millis)
	fields.Set("microsecondsSinceEpoch", millis*1000)
	return NewMessage("DateTime", fields)
}

// dateTimeParse implements the static `DateTime.parse(str)` the engine's
// std_time.parse_timestamp uses, accepting the ISO-8601 forms Dart does (with
// or without a fractional-second part and a trailing `Z`). Returns a DateTime
// message; a value the layouts don't cover fails loud.
func dateTimeParse(s string) Value {
	s = strings.TrimSpace(s)
	layouts := []string{
		"2006-01-02T15:04:05.000Z07:00",
		"2006-01-02T15:04:05Z07:00",
		"2006-01-02T15:04:05.000",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05.000",
		"2006-01-02 15:04:05",
		"2006-01-02",
	}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, s); err == nil {
			return dateTimeFromMillis(t.UnixMilli())
		}
	}
	panic(Thrown{Value: "FormatException: Invalid date format " + s})
}

// dateTimeToIso8601 renders a DateTime message's `.toIso8601String()`. The
// engine only calls it on the UTC value built in std_time.format_timestamp
// (`DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)`), so the output is
// millisecond-precision UTC with the trailing `Z`, matching Dart.
func dateTimeToIso8601(self Value) Value {
	m, ok := self.(*Message)
	if !ok {
		panic(Thrown{Value: "ball: toIso8601String on non-DateTime"})
	}
	msv, _ := m.Fields.Get("millisecondsSinceEpoch")
	t := time.UnixMilli(asInt64(msv)).UTC()
	return t.Format("2006-01-02T15:04:05.000") + "Z"
}
