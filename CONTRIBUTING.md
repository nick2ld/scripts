# Contributing

## Workflow

1. Create a branch from `main`.
2. Keep changes focused and atomic.
3. Validate script syntax before commit.
4. Open a PR with context and test notes.

## Local Checks

```bash
bash -n central.sh
bash -n vps.sh
```

Optional (recommended):

```bash
shellcheck central.sh vps.sh
```

## Commit Style

Use clear imperative commit messages, e.g.:
- `Fix LAPI port validation`
- `Improve menu UX in central script`

## Security

- Never commit real tokens, keys, or `.env` files.
- Redact public IPs/credentials from logs/screenshots.
