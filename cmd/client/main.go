package main

import (
	"fmt"
	"rshttpmux/httpmux"
)

func main() {
	client := httpmux.NewClient(
		"http://127.0.0.1:8080/tunnel",
		"mysession",
		&httpmux.MimicConfig{
			FakeDomain:    "www.google.com",
			FakePath:      "/search",
			UserAgent:     "Mozilla/5.0",
			SessionCookie: true,
		},
		&httpmux.ObfsConfig{
			Enabled:    true,
			MinPadding: 8,
			MaxPadding: 32,
		},
	)

	str, _ := client.DialStream()
	str.Write([]byte("Hello Server"))

	buf := make([]byte, 1024)
	n, _ := str.Read(buf)
	fmt.Println("Server:", string(buf[:n]))
}
