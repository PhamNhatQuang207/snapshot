package posts

import (
	"context"
	"fmt"
	"time"
)

// fakeStore is an in-memory Store for handler tests.
type fakeStore struct {
	posts     []Post // oldest first
	pingErr   error
	createErr error
}

func (f *fakeStore) Ping(ctx context.Context) error { return f.pingErr }

func (f *fakeStore) Create(ctx context.Context, caption string) (Post, error) {
	if f.createErr != nil {
		return Post{}, f.createErr
	}
	p := Post{
		ID:        fmt.Sprintf("post-%d", len(f.posts)+1),
		Caption:   caption,
		CreatedAt: time.Now().UTC(),
	}
	f.posts = append(f.posts, p)
	return p, nil
}

func (f *fakeStore) ListRecent(ctx context.Context, limit int) ([]Post, error) {
	out := make([]Post, 0, len(f.posts))
	for i := len(f.posts) - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, f.posts[i])
	}
	return out, nil
}
