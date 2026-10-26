import { useEffect, useState, type FormEvent } from 'react'
import { createPost, listPosts, type Post } from './api'

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })

function timeAgo(iso: string): string {
  const seconds = Math.round((new Date(iso).getTime() - Date.now()) / 1000)
  if (Math.abs(seconds) < 60) return relative.format(seconds, 'second')
  const minutes = Math.round(seconds / 60)
  if (Math.abs(minutes) < 60) return relative.format(minutes, 'minute')
  const hours = Math.round(minutes / 60)
  if (Math.abs(hours) < 24) return relative.format(hours, 'hour')
  return relative.format(Math.round(hours / 24), 'day')
}

export default function App() {
  const [posts, setPosts] = useState<Post[]>([])
  const [caption, setCaption] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    listPosts()
      .then(setPosts)
      .catch((e: Error) => setError(e.message))
  }, [])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setError(null)
    try {
      const post = await createPost(caption)
      setPosts((prev) => [post, ...prev])
      setCaption('')
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main>
      <h1>Snapshot</h1>
      <form onSubmit={onSubmit}>
        <label htmlFor="caption">Caption</label>
        <textarea
          id="caption"
          value={caption}
          onChange={(e) => setCaption(e.target.value)}
          maxLength={2200}
          rows={3}
          placeholder="What's happening?"
        />
        <button type="submit" disabled={submitting}>
          Post
        </button>
        {error && <div role="alert">{error}</div>}
      </form>
      <ul>
        {posts.map((post) => (
          <li key={post.id}>
            <p>{post.caption}</p>
            <time dateTime={post.created_at}>{timeAgo(post.created_at)}</time>
          </li>
        ))}
      </ul>
    </main>
  )
}
