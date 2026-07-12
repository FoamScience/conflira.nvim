// Command render is the Go IR producer: it reads an ADF document (or a board
// input with -board) on stdin and writes the Projection IR JSON — the same shape
// the Lua plugin emits. This is the headless core that a per-editor client drives.
//
// Usage:
//
//	go run ./cmd/render          < doc.adf.json    > doc.ir.json
//	go run ./cmd/render -board   < board.board.json > board.ir.json
package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"conflira/core/adf"
	"conflira/core/board"
	"conflira/core/ir"
	"conflira/core/render"
)

func main() {
	boardMode := flag.Bool("board", false, "render a board input instead of an ADF document")
	flag.Parse()

	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read stdin:", err)
		os.Exit(2)
	}

	var result *ir.ProjectionIR
	if *boardMode {
		in, err := board.DecodeInput(data)
		if err != nil {
			fmt.Fprintln(os.Stderr, "decode board input:", err)
			os.Exit(2)
		}
		result = board.Build(board.BuildState(in))
	} else {
		doc, err := adf.Decode(data)
		if err != nil {
			fmt.Fprintln(os.Stderr, "decode adf:", err)
			os.Exit(2)
		}
		result = render.Build(doc)
	}

	out, err := ir.Encode(result)
	if err != nil {
		fmt.Fprintln(os.Stderr, "encode ir:", err)
		os.Exit(2)
	}
	os.Stdout.Write(out)
}
