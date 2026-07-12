// Package rpc is a minimal newline-delimited JSON-RPC 2.0 server over stdio. It
// exposes the conflira core (render, board, jql, fields, adf, fetch) so thin
// per-editor clients (Neovim, VSCode, Sublime) can drive the same logic.
//
// Wire format: one JSON object per line in, one per line out.
package rpc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

// Request is a JSON-RPC 2.0 request. A missing/empty ID marks a notification
// (no response is written).
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Response is a JSON-RPC 2.0 response.
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Error is a JSON-RPC 2.0 error object.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Handler processes a method's params and returns a result or error.
type Handler func(params json.RawMessage) (any, error)

// Server dispatches JSON-RPC methods to registered handlers.
type Server struct {
	methods map[string]Handler
}

// NewServer creates an empty server.
func NewServer() *Server {
	return &Server{methods: map[string]Handler{}}
}

// Register binds a handler to a method name.
func (s *Server) Register(method string, h Handler) {
	s.methods[method] = h
}

// Methods returns the registered method names (for introspection/tests).
func (s *Server) Methods() []string {
	out := make([]string, 0, len(s.methods))
	for m := range s.methods {
		out = append(out, m)
	}
	return out
}

func errResp(id json.RawMessage, code int, msg string) *Response {
	return &Response{JSONRPC: "2.0", ID: id, Error: &Error{Code: code, Message: msg}}
}

// Dispatch runs one request and returns its response (nil for notifications).
func (s *Server) Dispatch(req *Request) *Response {
	h, ok := s.methods[req.Method]
	if !ok {
		return errResp(req.ID, -32601, "method not found: "+req.Method)
	}
	result, err := h(req.Params)
	if err != nil {
		return errResp(req.ID, -32000, err.Error())
	}
	return &Response{JSONRPC: "2.0", ID: req.ID, Result: result}
}

// Serve reads newline-delimited requests from in and writes responses to out
// until EOF.
func (s *Server) Serve(in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64*1024), 32*1024*1024)
	enc := json.NewEncoder(out)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			_ = enc.Encode(errResp(nil, -32700, "parse error: "+err.Error()))
			continue
		}
		resp := s.Dispatch(&req)
		if len(bytes.TrimSpace(req.ID)) == 0 {
			continue // notification — no response
		}
		if err := enc.Encode(resp); err != nil {
			return err
		}
	}
	return scanner.Err()
}
