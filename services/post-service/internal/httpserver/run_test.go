package httpserver

import (
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func slowServer(delay time.Duration) *http.Server {
	return &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(delay)
		_, _ = io.WriteString(w, "done")
	})}
}

func listen(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return ln
}

func TestRun_DrainsInFlightRequestOnCancel(t *testing.T) {
	ln := listen(t)
	ctx, cancel := context.WithCancel(context.Background())
	runErr := make(chan error, 1)
	go func() { runErr <- serve(ctx, slowServer(300*time.Millisecond), ln, 5*time.Second) }()

	body := make(chan string, 1)
	go func() {
		resp, err := http.Get("http://" + ln.Addr().String())
		if err != nil {
			body <- "error: " + err.Error()
			return
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		body <- string(b)
	}()

	time.Sleep(50 * time.Millisecond) // request is now in flight
	cancel()                          // simulate SIGTERM

	if got := <-body; got != "done" {
		t.Fatalf("in-flight response = %q, want done", got)
	}
	if err := <-runErr; err != nil {
		t.Fatalf("Run returned %v, want nil", err)
	}
}

func TestRun_ReturnsErrorWhenShutdownTimesOut(t *testing.T) {
	ln := listen(t)
	ctx, cancel := context.WithCancel(context.Background())
	runErr := make(chan error, 1)
	go func() { runErr <- serve(ctx, slowServer(2*time.Second), ln, 100*time.Millisecond) }()

	go func() {
		resp, err := http.Get("http://" + ln.Addr().String())
		if err == nil {
			resp.Body.Close()
		}
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()

	if err := <-runErr; err == nil {
		t.Fatal("Run returned nil, want shutdown timeout error")
	}
}
