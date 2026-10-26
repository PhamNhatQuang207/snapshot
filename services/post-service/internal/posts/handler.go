package posts

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// maxBodyBytes bounds request bodies; a 2200-rune caption is at most ~9 KiB of UTF-8.
const maxBodyBytes = 16 << 10

type handler struct {
	store  Store
	logger *slog.Logger
}

// NewHandler returns the post-service HTTP API, including health endpoints.
func NewHandler(store Store, logger *slog.Logger) http.Handler {
	h := &handler{store: store, logger: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /readyz", h.readyz)
	mux.HandleFunc("GET /api/posts", h.list)
	mux.HandleFunc("POST /api/posts", h.create)
	return mux
}

// healthz is the liveness probe: the process is up. It never touches the database,
// so a database outage does not make Kubernetes restart healthy pods.
func (h *handler) healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is the readiness probe: only send traffic here if the database answers.
func (h *handler) readyz(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Ping(r.Context()); err != nil {
		h.logger.Warn("readiness check failed", "err", err)
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (h *handler) list(w http.ResponseWriter, r *http.Request) {
	posts, err := h.store.ListRecent(r.Context(), ListLimit)
	if err != nil {
		h.internalError(w, r, err)
		return
	}
	if posts == nil {
		posts = []Post{}
	}
	writeJSON(w, http.StatusOK, map[string][]Post{"posts": posts})
}

func (h *handler) create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Caption string `json:"caption"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	caption := normalizeCaption(req.Caption)
	if err := ValidateCaption(caption); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	post, err := h.store.Create(r.Context(), caption)
	if err != nil {
		h.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, post)
}

func (h *handler) internalError(w http.ResponseWriter, r *http.Request, err error) {
	h.logger.Error("request failed", "path", r.URL.Path, "method", r.Method, "err", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
