export type Post = { id: string; caption: string; created_at: string }

// Relative paths: same origin locally (Vite proxy) and in AWS (CloudFront routes /api/*).
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init)
  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    throw new Error(body.error ?? `request failed (${res.status})`)
  }
  return body as T
}

export async function listPosts(): Promise<Post[]> {
  const { posts } = await request<{ posts: Post[] }>('/api/posts')
  return posts
}

export async function createPost(caption: string): Promise<Post> {
  return request<Post>('/api/posts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ caption }),
  })
}
