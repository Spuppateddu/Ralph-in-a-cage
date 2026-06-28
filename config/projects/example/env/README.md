# Per-repo environment files (this project)

Some repos can't even be installed/booted without app config. A Laravel app, for
example, boots during `composer install` (the `package:discover` hook), so any
service it resolves at boot (mailer, web-push, etc.) needs valid config or the
install fails — before the runner ever gets a chance to write a `.env`.

Drop a file here named **`<repo-name>.env`** (the repo's directory name, i.e. the
clone URL's basename without `.git`). Before installing or verifying that repo,
the runner copies it into the checkout, then forces this project's `DB_*`
settings (`DB_DATABASE` comes from this project's `project.env`) and generates an
`APP_KEY`. So this file only needs the app-specific bits the runner can't infer —
VAPID keys, third-party API stubs, mail to `log`, feature flags, etc.

- **Laravel** repos: copied to `<repo>/.env`. Required if the app needs config at
  boot (e.g. VAPID for web-push).
- **Convex (Next.js)** repos: copied to `<repo>/.env.local`. Optional — use it to
  set `NEXT_PUBLIC_CONVEX_URL` / `NEXT_PUBLIC_BACKEND_API_URL` for the build. If
  absent, the runner injects a placeholder Convex URL so `next build` can run.

These hold secrets, so `env/*` is gitignored. Commit only `*.example` templates
and this README.

Notes:
- This is a **throwaway verification env**, not production — use array/file/sync
  drivers and dummy-but-valid keys so migrate + tests run without external deps.
- For Laravel, `DB_*` is overwritten by the runner to point at the cage's MySQL
  (using this project's `DB_DATABASE`), so you don't need to set it.
- Generate a valid VAPID keypair with:
  `php -r "require 'vendor/autoload.php'; print_r(Minishlink\WebPush\VAPID::createVapidKeys());"`
