// Command jsonfmt formats, minifies, and validates JSON read from stdin.
//
// It exists because Foundation cannot pretty-print JSON without damaging it.
// JSONSerialization parses into an unordered NSDictionary, which destroys object
// key order before any writing option applies, and it re-renders numbers from
// their binary value (1.0 -> 1, 1e2 -> 100, -0.0 -> -0). There is no
// order-preserving JSON value type anywhere in the macOS SDK.
//
// Go's encoding/json.Indent is not a decode-then-encode round trip: it runs the
// scanner over the raw source bytes and, per its own comment, emits semantically
// uninteresting bytes unmodified. So key order, duplicate keys, number literals
// and string escape sequences all survive byte-identically.
//
// Usage:
//
//	jsonfmt {pretty|minify|validate} < input > output
//
// On success the result is written to stdout and the exit status is 0. On
// failure a single line "<byteOffset>\t<message>" is written to stderr and the
// exit status is 1; byteOffset is -1 when no position is known.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

const indent = "  "

func main() {
	if len(os.Args) != 2 {
		fail(-1, "usage: jsonfmt {pretty|minify|validate}")
	}

	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail(-1, "cannot read input: "+err.Error())
	}

	var out bytes.Buffer
	switch os.Args[1] {
	case "pretty":
		err = json.Indent(&out, src, "", indent)
	case "minify":
		err = json.Compact(&out, src)
	case "validate":
		// The same walk as minify with the output thrown away. One code path
		// behind all three commands means they can never disagree about what
		// counts as valid.
		err = json.Compact(&out, src)
		out.Reset()
	default:
		fail(-1, "unknown mode "+os.Args[1])
	}

	if err != nil {
		fail(locate(src), err.Error())
	}

	if _, err := os.Stdout.Write(out.Bytes()); err != nil {
		fail(-1, "cannot write output: "+err.Error())
	}
}

// locate returns the UTF-8 byte offset of the first syntax error in src, or -1.
//
// This has to re-parse, because Indent and Compact report *json.SyntaxError with
// Offset always 0 -- they run the scanner locally and never populate it. Only the
// Unmarshal/Decoder path fills Offset in. Verified against Go 1.24.5: for every
// malformed input tried, Indent gave Offset 0 while Unmarshal gave the true
// position.
//
// Unmarshal is used for DIAGNOSIS ONLY and its decoded value is thrown away, so
// the verbatim byte-for-byte guarantee of the Indent/Compact output path is
// untouched.
//
// SyntaxError.Offset is documented as "error occurred after reading Offset
// bytes", so the offending byte is the one before it.
func locate(src []byte) int64 {
	var discarded any
	err := json.Unmarshal(src, &discarded)
	if err == nil {
		return -1 // Unmarshal disagreed with the formatter; no position to offer.
	}

	se, ok := err.(*json.SyntaxError)
	if !ok || se.Offset <= 0 {
		return -1
	}
	offset := se.Offset - 1
	if offset > int64(len(src)) {
		offset = int64(len(src))
	}
	return offset
}

func fail(offset int64, msg string) {
	fmt.Fprintf(os.Stderr, "%d\t%s\n", offset, msg)
	os.Exit(1)
}
