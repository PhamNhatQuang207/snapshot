package posts

import (
	"context"
	"os"
	"testing"
)

// Integration test: runs only when POSTS_TEST_DATABASE_URL points at a disposable
// Postgres (e.g. `docker compose up -d postgres`).
func TestPostgresStore_CreateListAndMigrateTwice(t *testing.T) {
	url := os.Getenv("POSTS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POSTS_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()

	store, err := NewPostgresStore(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	for i := 0; i < 2; i++ { // migrations must be idempotent
		if err := store.Migrate(ctx); err != nil {
			t.Fatalf("migrate run %d: %v", i+1, err)
		}
	}
	if _, err := store.pool.Exec(ctx, "TRUNCATE posts.posts"); err != nil {
		t.Fatal(err)
	}
	if err := store.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	if _, err := store.Create(ctx, "first"); err != nil {
		t.Fatal(err)
	}
	second, err := store.Create(ctx, "second")
	if err != nil {
		t.Fatal(err)
	}
	if second.ID == "" || second.CreatedAt.IsZero() {
		t.Fatalf("created post missing id/created_at: %+v", second)
	}

	got, err := store.ListRecent(ctx, ListLimit)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Caption != "second" || got[1].Caption != "first" {
		t.Fatalf("got %+v, want [second first]", got)
	}
}
