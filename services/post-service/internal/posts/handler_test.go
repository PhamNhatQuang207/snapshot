package posts

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestHandler(store Store) http.Handler {
	return NewHandler(store, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body.String(), err)
	}
	return v
}

func assertStatus(t *testing.T, rec *httptest.ResponseRecorder, want int) {
	t.Helper()
	if rec.Code != want {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, want, rec.Body.String())
	}
}

func assertError(t *testing.T, rec *httptest.ResponseRecorder, want string) {
	t.Helper()
	got := decode[map[string]string](t, rec)["error"]
	if got != want {
		t.Fatalf("error = %q, want %q", got, want)
	}
}

func TestHealthz_Returns200EvenWhenStoreDown(t *testing.T) {
	h := newTestHandler(&fakeStore{pingErr: errors.New("db down")})
	rec := do(t, h, http.MethodGet, "/healthz", "")
	assertStatus(t, rec, http.StatusOK)
	if got := decode[map[string]string](t, rec)["status"]; got != "ok" {
		t.Fatalf("status field = %q, want ok", got)
	}
}

func TestReadyz_Returns503WhenStoreUnavailable(t *testing.T) {
	h := newTestHandler(&fakeStore{pingErr: errors.New("db down")})
	rec := do(t, h, http.MethodGet, "/readyz", "")
	assertStatus(t, rec, http.StatusServiceUnavailable)
	assertError(t, rec, "database unavailable")
}

func TestReadyz_Returns200WhenStoreOK(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	rec := do(t, h, http.MethodGet, "/readyz", "")
	assertStatus(t, rec, http.StatusOK)
	if got := decode[map[string]string](t, rec)["status"]; got != "ready" {
		t.Fatalf("status field = %q, want ready", got)
	}
}

func TestCreatePost_Returns201WithPost(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	rec := do(t, h, http.MethodPost, "/api/posts", `{"caption":"hello"}`)
	assertStatus(t, rec, http.StatusCreated)
	p := decode[Post](t, rec)
	if p.Caption != "hello" || p.ID == "" {
		t.Fatalf("got %+v, want caption hello and non-empty id", p)
	}
}

func TestCreatePost_RejectsEmptyCaption(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	rec := do(t, h, http.MethodPost, "/api/posts", `{"caption":"   "}`)
	assertStatus(t, rec, http.StatusBadRequest)
	assertError(t, rec, "caption is required")
}

func TestCreatePost_RejectsCaptionOver2200Runes(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	body, _ := json.Marshal(map[string]string{"caption": strings.Repeat("é", 2201)})
	rec := do(t, h, http.MethodPost, "/api/posts", string(body))
	assertStatus(t, rec, http.StatusBadRequest)
	assertError(t, rec, "caption must be at most 2200 characters")
}

func TestCreatePost_Accepts2200Runes(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	body, _ := json.Marshal(map[string]string{"caption": strings.Repeat("é", 2200)})
	rec := do(t, h, http.MethodPost, "/api/posts", string(body))
	assertStatus(t, rec, http.StatusCreated)
}

func TestCreatePost_RejectsMalformedJSON(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	rec := do(t, h, http.MethodPost, "/api/posts", `{`)
	assertStatus(t, rec, http.StatusBadRequest)
	assertError(t, rec, "invalid JSON body")
}

func TestCreatePost_RejectsOversizedBody(t *testing.T) {
	h := newTestHandler(&fakeStore{})
	body := `{"caption":"` + strings.Repeat("a", 17*1024) + `"}`
	rec := do(t, h, http.MethodPost, "/api/posts", body)
	assertStatus(t, rec, http.StatusBadRequest)
	assertError(t, rec, "invalid JSON body")
}

func TestCreatePost_Returns500JSONOnStoreError(t *testing.T) {
	h := newTestHandler(&fakeStore{createErr: errors.New("insert failed")})
	rec := do(t, h, http.MethodPost, "/api/posts", `{"caption":"hello"}`)
	assertStatus(t, rec, http.StatusInternalServerError)
	assertError(t, rec, "internal error")
}

func TestListPosts_NewestFirst(t *testing.T) {
	now := time.Now().UTC()
	store := &fakeStore{posts: []Post{
		{ID: "1", Caption: "older", CreatedAt: now.Add(-time.Minute)},
		{ID: "2", Caption: "newer", CreatedAt: now},
	}}
	rec := do(t, newTestHandler(store), http.MethodGet, "/api/posts", "")
	assertStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Posts []Post `json:"posts"`
	}](t, rec).Posts
	if len(got) != 2 || got[0].Caption != "newer" || got[1].Caption != "older" {
		t.Fatalf("got %+v, want [newer older]", got)
	}
}

func TestListPosts_EmptyIsEmptyArray(t *testing.T) {
	rec := do(t, newTestHandler(&fakeStore{}), http.MethodGet, "/api/posts", "")
	assertStatus(t, rec, http.StatusOK)
	if strings.TrimSpace(rec.Body.String()) != `{"posts":[]}` {
		t.Fatalf("body = %s, want {\"posts\":[]}", rec.Body.String())
	}
}

func TestPosts_WrongMethodReturns405(t *testing.T) {
	rec := do(t, newTestHandler(&fakeStore{}), http.MethodDelete, "/api/posts", "")
	assertStatus(t, rec, http.StatusMethodNotAllowed)
}
