// Go's net/http client against the mttp interop server, directly or through
// a reverse proxy. interop/run.mbtx runs it as
//
//	client <base> <direct> <case,case,...>
//
// where <base> is where the server's endpoints are (http://127.0.0.1:39000
// directly, or a proxy's /up prefix) and <direct> the server itself. It
// prints `CASE <id> ok|fail <detail>` per case.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"os"
	"strings"
	"sync"
	"time"
)

// pattern and digest are interop/pattern's binary and Digest.
func pattern(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte((i*7 + i>>8) & 0xff)
	}
	return b
}

func digest(b []byte) string {
	h := uint32(0x811c9dc5)
	for _, c := range b {
		h = (h ^ uint32(c)) * 0x01000193
	}
	return fmt.Sprintf("%d:%08x", len(b), h)
}

// echoed is the value of `key` in an /echo answer.
func echoed(body []byte, key string) string {
	for _, line := range strings.Split(string(body), "\n") {
		if v, ok := strings.CutPrefix(line, key+" "); ok {
			return v
		}
	}
	return "?"
}

type ctx struct {
	base, direct string
	client       *http.Client
}

func newClient() *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			// HTTP/1.1 only: the interop server speaks nothing else.
			TLSNextProto:          map[string]func(string, *tls.Conn) http.RoundTripper{},
			ExpectContinueTimeout: 10 * time.Second,
			MaxIdleConnsPerHost:   16,
		},
	}
}

func (c *ctx) do(req *http.Request) (*http.Response, []byte, error) {
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return resp, body, err
}

func (c *ctx) get(url string) (*http.Response, []byte, error) {
	req, _ := http.NewRequest("GET", url, nil)
	return c.do(req)
}

func want(ok bool, format string, args ...any) error {
	if ok {
		return nil
	}
	return fmt.Errorf(format, args...)
}

// noLength hides a reader's length, so the request goes out chunked.
type noLength struct{ io.Reader }

func (c *ctx) upload(body io.Reader, expected string, header http.Header) (string, error) {
	req, _ := http.NewRequest("POST", c.base+"/echo", body)
	for k, v := range header {
		req.Header[k] = v
	}
	resp, got, err := c.do(req)
	if err != nil {
		return "", err
	}
	if err := want(resp.StatusCode == 200, "status %d", resp.StatusCode); err != nil {
		return "", err
	}
	received := echoed(got, "body")
	if err := want(received == expected, "the server got %s", received); err != nil {
		return "", err
	}
	return echoed(got, "framing") + ", " + received, nil
}

func run(c *ctx, id string) (string, error) {
	switch id {
	case "get":
		resp, body, err := c.get(c.base + "/conn")
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(body)), want(resp.StatusCode == 200, "status %d", resp.StatusCode)
	case "reuse", "upstream-reuse":
		// reuse: one client, so one connection to the server.
		// upstream-reuse: two clients, so two connections to the proxy,
		// which should still reuse one connection to the server.
		peers := []string{}
		for i := 0; i < 2; i++ {
			if id == "upstream-reuse" {
				c.client = newClient()
			}
			_, body, err := c.get(c.base + "/conn")
			if err != nil {
				return "", err
			}
			peers = append(peers, strings.TrimSpace(string(body)))
		}
		return "peer " + peers[0], want(peers[0] == peers[1], "peers %v", peers)
	case "chunked-upload":
		payload := pattern(1 << 20)
		return c.upload(noLength{bytes.NewReader(payload)}, digest(payload), nil)
	case "large-upload":
		payload := pattern(16 << 20)
		return c.upload(bytes.NewReader(payload), digest(payload), nil)
	case "expect":
		payload := pattern(1 << 20)
		got100 := false
		trace := &httptrace.ClientTrace{Got100Continue: func() { got100 = true }}
		req, _ := http.NewRequestWithContext(
			httptrace.WithClientTrace(context.Background(), trace),
			"POST", c.base+"/echo", bytes.NewReader(payload))
		req.Header.Set("Expect", "100-continue")
		resp, body, err := c.do(req)
		if err != nil {
			return "", err
		}
		if err := want(resp.StatusCode == 200 && got100, "status %d, 100 Continue %v", resp.StatusCode, got100); err != nil {
			return "", err
		}
		received := echoed(body, "body")
		return "100 Continue, then " + received, want(received == digest(payload), "the server got %s", received)
	case "stream":
		_, body, err := c.get(c.base + "/stream?pieces=16&size=4096&delay_ms=10")
		if err != nil {
			return "", err
		}
		return digest(body), want(digest(body) == digest(pattern(16*4096)), "body %s", digest(body))
	case "head":
		req, _ := http.NewRequest("HEAD", c.base+"/bytes?n=1000", nil)
		resp, body, err := c.do(req)
		if err != nil {
			return "", err
		}
		if err := want(resp.StatusCode == 200 && resp.ContentLength == 1000 && len(body) == 0,
			"status %d, length %d, %d body bytes", resp.StatusCode, resp.ContentLength, len(body)); err != nil {
			return "", err
		}
		_, next, err := c.get(c.base + "/bytes?n=10")
		if err != nil {
			return "", err
		}
		return "length 1000, no body", want(bytes.Equal(next, pattern(10)), "next body %q", next)
	case "no-content":
		resp, body, err := c.get(c.base + "/status/204")
		if err != nil {
			return "", err
		}
		if err := want(resp.StatusCode == 204 && len(body) == 0, "status %d, %d body bytes", resp.StatusCode, len(body)); err != nil {
			return "", err
		}
		_, next, err := c.get(c.base + "/bytes?n=10")
		if err != nil {
			return "", err
		}
		return "204", want(bytes.Equal(next, pattern(10)), "next body %q", next)
	case "parallel":
		var wg sync.WaitGroup
		errs := make(chan error, 16)
		for i := 0; i < 16; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, body, err := c.get(c.base + "/bytes?n=100000")
				if err == nil && digest(body) != digest(pattern(100000)) {
					err = fmt.Errorf("body %s", digest(body))
				}
				if err != nil {
					errs <- err
				}
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			return "", err
		}
		return "16 concurrent requests", nil
	}
	return "", fmt.Errorf("unknown case")
}

func main() {
	if len(os.Args) != 4 {
		fmt.Println("usage: client <base> <direct> <case,...>")
		os.Exit(2)
	}
	c := &ctx{base: os.Args[1], direct: os.Args[2], client: newClient()}
	for _, id := range strings.Split(os.Args[3], ",") {
		detail, err := run(c, id)
		if err != nil {
			fmt.Printf("CASE %s fail %v\n", id, err)
		} else {
			fmt.Printf("CASE %s ok %s\n", id, detail)
		}
	}
}
