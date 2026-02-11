package main

import (
	"net/http"
	"rshttpmux/httpmux"
)

func main() {
	srv := httpmux.NewServer(
		15,
		&httpmux.MimicConfig{},
		&httpmux.ObfsConfig{},
	)

	http.HandleFunc("/tunnel", srv.Handle)
	http.ListenAndServe(":8080", nil)
}
