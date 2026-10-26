// Package httpserver runs an http.Server until its context is cancelled, then drains it.
package httpserver

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"
)

// Run serves srv on srv.Addr until ctx is cancelled (e.g. on SIGTERM during a
// Kubernetes rolling update), then stops accepting new connections and waits up to
// shutdownTimeout for in-flight requests to finish.
func Run(ctx context.Context, srv *http.Server, shutdownTimeout time.Duration) error {
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		return err
	}
	return serve(ctx, srv, ln, shutdownTimeout)
}

func serve(ctx context.Context, srv *http.Server, ln net.Listener, shutdownTimeout time.Duration) error {
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	select {
	case err := <-serveErr:
		return err // listener failed before any shutdown was requested
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
