// Command server runs post-service.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/PhamNhatQuang207/snapshot/services/post-service/internal/httpserver"
	"github.com/PhamNhatQuang207/snapshot/services/post-service/internal/posts"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("post-service stopped", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	store, err := posts.NewPostgresStore(ctx, databaseURL)
	if err != nil {
		return err
	}
	defer store.Close()

	// If the database is unreachable at startup, exit; Kubernetes restarts with backoff.
	migrateCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := store.Migrate(migrateCtx); err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           posts.NewHandler(store, logger),
		ReadHeaderTimeout: 5 * time.Second,
	}
	logger.Info("post-service listening", "port", port, "pid", os.Getpid())
	if err := httpserver.Run(ctx, srv, 20*time.Second); err != nil {
		return err
	}
	logger.Info("post-service shut down cleanly")
	return nil
}
