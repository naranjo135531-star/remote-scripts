# Claude Code — project notes

## Git / GitHub (secondary account)

This repo is **not** on the default GitHub account (`nacosdev`). It uses:

| Setting | Value |
|---------|--------|
| GitHub user | `naranjo135531-star` |
| Repository | `https://github.com/naranjo135531-star/remote-scripts` |
| Remote URL | `git@github.com:naranjo135531-star/remote-scripts.git` |
| SSH private key | `~/.ssh/id_ed_naranjo` |
| SSH public key | `~/.ssh/id_ed_naranjo.pub` |

### Important

- Default key `~/.ssh/id_rsa` → authenticates as **nacosdev** → push denied on this repo.
- This repo has `core.sshCommand` set locally to always use `id_ed_naranjo` with `IdentitiesOnly=yes`.

### Commands

```bash
# Verify auth (must say naranjo135531-star)
ssh -i ~/.ssh/id_ed_naranjo -o IdentitiesOnly=yes -T git@github.com

# Push / pull (from repo root)
git push origin main
git pull origin main
```

### Troubleshooting

- `Permission denied (publickey)` → key not on GitHub or wrong key; use explicit `-i ~/.ssh/id_ed_naranjo -o IdentitiesOnly=yes`.
- `Permission denied to nacosdev` → default key used; fix with `core.sshCommand` or `IdentitiesOnly=yes`.
- When pasting the public key on GitHub, copy exactly from `cat ~/.ssh/id_ed_naranjo.pub` (base64 is case-sensitive).

Do not use `gh` as `nacosdev` for push/PR operations on this repo unless the user switches `gh auth` to `naranjo135531-star`.
