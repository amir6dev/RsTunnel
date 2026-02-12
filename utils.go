package httpmux

import "strings"

// SplitMap parses "bind->target".
// bind can be "1412" or "0.0.0.0:1412"
func SplitMap(s string) (bind string, target string, ok bool) {
	parts := strings.Split(s, "->")
	if len(parts) != 2 {
		return "", "", false
	}
	bind = strings.TrimSpace(parts[0])
	target = strings.TrimSpace(parts[1])

	if bind == "" || target == "" {
		return "", "", false
	}

	// If bind is only a port, convert to 0.0.0.0:PORT
	if !strings.Contains(bind, ":") {
		bind = "0.0.0.0:" + bind
	}
	return bind, target, true
}
