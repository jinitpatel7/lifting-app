export function createAccountClient(request = fetch) {
  let session;
  async function send(path, method, body) {
    const response = await request(`/api/${path}`, { method, cache: 'no-store', credentials: 'omit', redirect: 'error',
      headers: { ...(session && { Authorization: `Bearer ${session.token}` }), ...(body !== undefined && { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body) });
    if (response.status === 204) return null;
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (response.status === 401 && session) session = undefined;
      throw new Error(result.error ?? 'The account service is unavailable. Local data is still available.');
    }
    return result;
  }
  return {
    username: () => session?.username,
    async login(username, password, register) { session = await send(`account/${register ? 'register' : 'sign-in'}`, 'POST', { username, password }); },
    async logout() { try { await send('account/sign-out', 'POST'); } finally { session = undefined; } },
    load: () => send('backup/preview', 'GET'),
    save: document => send('backup/preview', 'PUT', document),
    remove: () => send('backup/preview', 'DELETE'),
  };
}
