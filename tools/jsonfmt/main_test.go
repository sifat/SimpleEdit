package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// pretty mirrors what main() does for the "pretty" mode.
func pretty(t *testing.T, src string) string {
	t.Helper()
	var out bytes.Buffer
	if err := json.Indent(&out, []byte(src), "", indent); err != nil {
		t.Fatalf("Indent(%q) returned %v", src, err)
	}
	return out.String()
}

func minify(t *testing.T, src string) string {
	t.Helper()
	var out bytes.Buffer
	if err := json.Compact(&out, []byte(src)); err != nil {
		t.Fatalf("Compact(%q) returned %v", src, err)
	}
	return out.String()
}

// The whole reason this helper exists: Foundation reorders keys, Go must not.
func TestKeyOrderPreserved(t *testing.T) {
	src := `{"z":1,"m":2,"a":3,"q":4,"b":5,"y":6,"c":7,"x":8,"d":9,"w":10}`
	got := pretty(t, src)
	want := []string{"z", "m", "a", "q", "b", "y", "c", "x", "d", "w"}
	at := 0
	for _, key := range want {
		i := strings.Index(got[at:], `"`+key+`"`)
		if i < 0 {
			t.Fatalf("key %q missing or out of order in:\n%s", key, got)
		}
		at += i
	}
}

func TestDuplicateKeysBothSurvive(t *testing.T) {
	got := pretty(t, `{"a":1,"a":2}`)
	if strings.Count(got, `"a"`) != 2 {
		t.Errorf("duplicate key dropped:\n%s", got)
	}
	if !strings.Contains(got, "1") || !strings.Contains(got, "2") {
		t.Errorf("duplicate value dropped:\n%s", got)
	}
}

// Foundation rewrites these from the parsed binary value. Go must not.
func TestNumberLiteralsVerbatim(t *testing.T) {
	for _, lit := range []string{
		"1.0", "1e2", "1E2", "-0.0", "0.1000",
		"12345678901234567890123456789012", "1e400", "-1.5e-9",
	} {
		got := pretty(t, `{"n":`+lit+`}`)
		if !strings.Contains(got, lit) {
			t.Errorf("number literal %q was rewritten:\n%s", lit, got)
		}
	}
}

func TestStringContentsVerbatim(t *testing.T) {
	for _, s := range []string{
		`"a\/b"`,      // escaped solidus must stay escaped
		`"caf\u00e9"`, // \u escape must not be decoded
		`"café"`,      // literal non-ASCII must not be escaped
		`"tab\tnew\nquote\""`,
		`"lone surrogate \ud800"`, // RFC 8259 permits this; rejecting it refuses files jq accepts
	} {
		got := pretty(t, `{"k":`+s+`}`)
		if !strings.Contains(got, s) {
			t.Errorf("string %s was rewritten:\n%s", s, got)
		}
	}
}

func TestEmptyContainersStayCompact(t *testing.T) {
	got := pretty(t, `{"o":{},"a":[]}`)
	if !strings.Contains(got, "{}") || !strings.Contains(got, "[]") {
		t.Errorf("empty containers were expanded:\n%s", got)
	}
}

func TestTrailingNewlinePreserved(t *testing.T) {
	if got := pretty(t, "{\"a\":1}\n"); !strings.HasSuffix(got, "\n") {
		t.Errorf("trailing newline dropped: %q", got)
	}
	if got := pretty(t, `{"a":1}`); strings.HasSuffix(got, "\n") {
		t.Errorf("trailing newline invented: %q", got)
	}
}

func TestTopLevelScalarsAccepted(t *testing.T) {
	for _, src := range []string{"42", `"hi"`, "true", "false", "null", "1.5"} {
		if !json.Valid([]byte(src)) {
			t.Errorf("valid RFC 8259 document rejected: %s", src)
		}
	}
}

func TestMinifyThenFormatIsIdempotent(t *testing.T) {
	src := `{"z":1,"a":[1,2,{"b":1.0}],"c":{}}`
	once := pretty(t, src)
	twice := pretty(t, minify(t, once))
	if once != twice {
		t.Errorf("format is not idempotent:\n%q\nvs\n%q", once, twice)
	}
}

// Indent and Compact report Offset 0 for every syntax error, so locate() must
// re-parse to find the real position. If this regresses, the editor silently
// parks the caret at byte 0 for every malformed file.
func TestIndentDoesNotReportUsableOffsets(t *testing.T) {
	var out bytes.Buffer
	err := json.Indent(&out, []byte(`{"a":1,,}`), "", indent)
	se, ok := err.(*json.SyntaxError)
	if !ok {
		t.Fatalf("expected *json.SyntaxError, got %T", err)
	}
	if se.Offset != 0 {
		t.Skip("Indent now populates Offset; locate() could be simplified")
	}
}

func TestLocateFindsTheOffendingByte(t *testing.T) {
	cases := []struct {
		src  string
		want byte
	}{
		{`{"a":1,,}`, ','},
		{`{"a":1 "b":2}`, '"'},
		{`{"a":1}trailing`, 't'},
		{`{"x": oops}`, 'o'},
		// Non-ASCII ahead of the error: the offset is in BYTES, which is exactly
		// why the Swift side converts it to a UTF-16 index before selecting.
		{`{"ünïcödé":1, "x": oops}`, 'o'},
	}
	for _, c := range cases {
		offset := locate([]byte(c.src))
		if offset < 0 {
			t.Errorf("locate(%q) found no position", c.src)
			continue
		}
		if got := c.src[offset]; got != c.want {
			t.Errorf("locate(%q) = %d, pointing at %q; want %q", c.src, offset, got, c.want)
		}
	}
}

func TestLocateReturnsNegativeOnValidInput(t *testing.T) {
	if got := locate([]byte(`{"a":1}`)); got != -1 {
		t.Errorf("locate(valid) = %d, want -1", got)
	}
}

func TestTrailingContentRejected(t *testing.T) {
	// NDJSON lands here, which is why the Swift side detects .jsonl separately.
	if json.Valid([]byte("{\"a\":1}\n{\"b\":2}\n")) {
		t.Error("two top-level documents should not validate as one")
	}
}

func TestBOMIsRejected(t *testing.T) {
	// Documents the contract the Swift side relies on: Go treats a BOM as an
	// invalid character, not whitespace, so JSONTool must strip it first.
	if json.Valid([]byte("\ufeff{\"a\":1}")) {
		t.Error("a leading BOM is expected to be rejected by the Go scanner")
	}
}
