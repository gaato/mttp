package main

import (
	"bytes"
	"fmt"
	"log"
	"net/http"
	"os"
)

var (
	smallBody = []byte("mttp benchmark\n")
	largeBody = bytes.Repeat([]byte{'x'}, 1024*1024)
)

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: server <address>")
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body []byte
		switch r.URL.Path {
		case "/small":
			body = smallBody
		case "/large":
			body = largeBody
		default:
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(body)
	})
	server := &http.Server{
		Addr:              os.Args[1],
		Handler:           handler,
		ReadHeaderTimeout: 0,
	}
	log.Fatal(server.ListenAndServe())
}
