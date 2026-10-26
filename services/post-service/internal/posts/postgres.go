package posts

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schemaSQL string

// PostgresStore is the production Store, backed by a pgx connection pool.
type PostgresStore struct {
	pool *pgxpool.Pool
}

func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open postgres pool: %w", err)
	}
	return &PostgresStore{pool: pool}, nil
}

// Migrate applies the embedded schema. Every statement is idempotent, so running it
// on each start (and from several pods at once) is safe.
func (s *PostgresStore) Migrate(ctx context.Context) error {
	if _, err := s.pool.Exec(ctx, schemaSQL); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

func (s *PostgresStore) Close() { s.pool.Close() }

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Create(ctx context.Context, caption string) (Post, error) {
	var p Post
	err := s.pool.QueryRow(ctx,
		`INSERT INTO posts.posts (caption) VALUES ($1) RETURNING id::text, caption, created_at`,
		caption,
	).Scan(&p.ID, &p.Caption, &p.CreatedAt)
	if err != nil {
		return Post{}, fmt.Errorf("insert post: %w", err)
	}
	return p, nil
}

func (s *PostgresStore) ListRecent(ctx context.Context, limit int) ([]Post, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id::text, caption, created_at FROM posts.posts ORDER BY created_at DESC, id DESC LIMIT $1`,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("list posts: %w", err)
	}
	defer rows.Close()

	posts := []Post{}
	for rows.Next() {
		var p Post
		if err := rows.Scan(&p.ID, &p.Caption, &p.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan post: %w", err)
		}
		posts = append(posts, p)
	}
	return posts, rows.Err()
}
