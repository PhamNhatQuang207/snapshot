// Package posts owns Snapshot posts: the data type, storage contract, and HTTP API.
package posts

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

// MaxCaptionRunes matches Instagram's caption limit; counted in runes, not bytes.
const MaxCaptionRunes = 2200

// ListLimit caps how many posts one list call returns.
const ListLimit = 50

type Post struct {
	ID        string    `json:"id"`
	Caption   string    `json:"caption"`
	CreatedAt time.Time `json:"created_at"`
}

// Store is the persistence contract the HTTP layer depends on.
type Store interface {
	Ping(ctx context.Context) error
	Create(ctx context.Context, caption string) (Post, error)
	ListRecent(ctx context.Context, limit int) ([]Post, error) // newest first
}

var (
	errCaptionRequired = errors.New("caption is required")
	errCaptionTooLong  = errors.New("caption must be at most 2200 characters")
)

// ValidateCaption checks a caption that has already been trimmed of surrounding space.
func ValidateCaption(caption string) error {
	if caption == "" {
		return errCaptionRequired
	}
	if utf8.RuneCountInString(caption) > MaxCaptionRunes {
		return errCaptionTooLong
	}
	return nil
}

// normalizeCaption trims surrounding whitespace before validation and storage.
func normalizeCaption(caption string) string {
	return strings.TrimSpace(caption)
}
