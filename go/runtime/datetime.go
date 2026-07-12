package ballrt

import "time"

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
