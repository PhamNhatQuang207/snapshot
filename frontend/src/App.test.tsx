import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test, vi } from 'vitest'
import App from './App'

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const now = new Date().toISOString()

test('renders posts returned by the API, newest first', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () =>
      jsonResponse(200, {
        posts: [
          { id: '2', caption: 'newer', created_at: now },
          { id: '1', caption: 'older', created_at: now },
        ],
      }),
    ),
  )
  render(<App />)

  const items = await screen.findAllByRole('listitem')
  expect(items.map((li) => li.querySelector('p')?.textContent)).toEqual(['newer', 'older'])
})

test('shows the API error message when creating a post fails', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (_url: string, init?: RequestInit) =>
      init?.method === 'POST'
        ? jsonResponse(400, { error: 'caption is required' })
        : jsonResponse(200, { posts: [] }),
    ),
  )
  render(<App />)

  await userEvent.type(screen.getByLabelText('Caption'), 'x')
  await userEvent.click(screen.getByRole('button', { name: 'Post' }))

  expect(await screen.findByRole('alert')).toHaveTextContent('caption is required')
})

test('prepends the created post after a successful submit', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (_url: string, init?: RequestInit) =>
      init?.method === 'POST'
        ? jsonResponse(201, { id: '3', caption: 'brand new', created_at: now })
        : jsonResponse(200, { posts: [{ id: '1', caption: 'existing', created_at: now }] }),
    ),
  )
  render(<App />)
  await screen.findByText('existing')

  await userEvent.type(screen.getByLabelText('Caption'), 'brand new')
  await userEvent.click(screen.getByRole('button', { name: 'Post' }))

  await screen.findByText('brand new')
  const items = screen.getAllByRole('listitem')
  expect(items[0]).toHaveTextContent('brand new')
  expect(screen.getByLabelText('Caption')).toHaveValue('')
})
