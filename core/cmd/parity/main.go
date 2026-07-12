// Command parity validates a Projection IR JSON document against the Go IR
// contract and prints a structural summary. It is the bridge for checking that
// the Lua producer (or a future Go producer) emits a well-formed, editor-neutral
// IR.
//
// Usage:
//
//	nvim --headless -c 'lua io.write(require("atlassian.editor.ir").encode(
//	    require("atlassian.editor.render").build_ir(adf)))' -c qa \
//	  | go run ./cmd/parity
//
// Or against a captured fixture:
//
//	go run ./cmd/parity < testdata/editor_ir.json
//
// Exit code is non-zero if the IR fails validation.
package main

import (
	"fmt"
	"io"
	"os"
	"sort"

	"conflira/core/ir"
)

func main() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read stdin:", err)
		os.Exit(2)
	}

	p, err := ir.Decode(data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	fmt.Printf("lines: %d\n", len(p.Lines))
	fmt.Printf("marks: %d\n", len(p.Marks))
	fmt.Printf("spans: %d\n", len(p.Spans))

	fmt.Println("by kind:")
	printSortedCounts(p.MarksByKind())

	fmt.Println("style tokens:")
	tokens := make([]string, 0)
	for tok := range p.StyleTokens() {
		tokens = append(tokens, tok)
	}
	sort.Strings(tokens)
	for _, tok := range tokens {
		fmt.Printf("  %s\n", tok)
	}

	if errs := p.Validate(); len(errs) > 0 {
		fmt.Fprintf(os.Stderr, "\nINVALID (%d problems):\n", len(errs))
		for _, e := range errs {
			fmt.Fprintf(os.Stderr, "  - %v\n", e)
		}
		os.Exit(1)
	}
	fmt.Println("\nOK: valid editor-neutral IR")
}

func printSortedCounts(m map[string]int) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("  %-12s %d\n", k, m[k])
	}
}
