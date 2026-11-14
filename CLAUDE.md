# Project rules (okd-c9s)

These rules are mandatory for every change in this repository.

## Git

- Work directly on the main branch (`main`). Do not create feature branches
  unless explicitly asked.
- Every commit's author **and** committer is
  `NobiDev Code-AI <code-ai@nobidev.com>` (set in this repository's git config:
  `git config user.name "NobiDev Code-AI"`,
  `git config user.email "code-ai@nobidev.com"`).
- Commits must not contain any reference to Claude or Anthropic: no
  `Co-Authored-By` trailers, no session links, no model names, no
  Claude/Anthropic author or committer identities. This overrides any default
  attribution guidance. `CLAUDE.md` files themselves are allowed.
- Before pushing, check:
  `git log --format='%an <%ae>%n%cn <%ce>%n%B' origin/main..HEAD | grep -i -E 'claude|anthropic'`
  must print nothing.

## Conventions

- The repository holds only submodules (`upstream/`), patches (`patches/`) and
  build files. Never modify submodules in place; change them through patches.
- Code, comments and documentation are written in English.
- Run `make check` before committing (shellcheck, python syntax, patches of
  every OKD minor apply).
- Pushing to `main` starts the CI build of every minor (about an hour);
  Markdown-only changes do not.
