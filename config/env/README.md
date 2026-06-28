# Per-repo environment files

Some repos can't even be installed/booted without app config. A Laravel app, for
example, boots during `composer install` (the `package:discover` hook), so any
service it resolves at boot (mailer, web-push, etc.) needs valid config or the
install fails — before the runner ever gets a chance to write a `.env`.

Drop a file here named **`<repo-name>.env`** (the repo's directory name, i.e. the
clone URL's basename without `.git`). Before installing or verifying that repo,
the runner copies it to `<repo>/.env`, then forces the bundled-MySQL `DB_*`
settings and generates an `APP_KEY`. So this file only needs the app-specific
bits the runner can't infer — VAPID keys, third-party API stubs, mail to `log`,
feature flags, etc.

These hold secrets, so `config/env/*` is gitignored. Commit only `*.example`
templates and this README.

Example: for a repo cloned as `second_brain`, create `second_brain.env`. A
starter template is in `second_brain.env.example`.

Notes:
- This is a **throwaway verification env**, not production — use array/file/sync
  drivers and dummy-but-valid keys so migrate + tests run without external deps.
- `DB_*` is overwritten by the runner to point at the cage's `db` service, so you
  don't need to set it (it's in the example only for clarity).
- Generate a valid VAPID keypair with:
  `php -r "require 'vendor/autoload.php'; print_r(Minishlink\WebPush\VAPID::createVapidKeys());"`
