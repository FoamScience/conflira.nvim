// Command conflira-core is the headless JSON-RPC server: it exposes the conflira
// core (render, board, jql, fields, adf, and a curl-backed board.fetch) over
// newline-delimited JSON-RPC 2.0 on stdio, for thin per-editor clients.
//
//	echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | conflira-core
//	echo '{"jsonrpc":"2.0","id":1,"method":"jql.main"}' | conflira-core
package main

import (
	"os"

	"conflira/core/rpc"
)

func main() {
	s := rpc.NewServer()
	rpc.Register(s, rpc.CurlFetcher, rpc.CurlClient)
	if err := s.Serve(os.Stdin, os.Stdout); err != nil {
		os.Exit(1)
	}
}
