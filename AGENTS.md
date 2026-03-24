# Project Rules for Codex

## Python Environment
- **Always use `uv`** instead of `pip` or `pip3`
- **Always use a virtual environment** — never install packages globally
- This project uses `pyproject.toml` (not `requirements.txt`)

### Fresh clone setup
```bash
uv sync        # creates .venv and installs all dependencies
```

### Adding a new package
```bash
uv add <package>
```

### Running scripts
```bash
uv run python server/server.py
# or activate the venv first:
source .venv/bin/activate
```

### Never use
- `pip install` or `pip3 install`
- `--break-system-packages`
- `uv pip install` (use `uv add` instead)
- manual `uv venv` + `uv pip install` (use `uv sync`)

## Git Workflow
- **Never commit directly to `main`**
- For every plan step or feature, create a branch first:
  ```bash
  git checkout -b step-02-swift-menubar-shell
  # ... do the work, commit along the way ...
  git push origin step-02-swift-menubar-shell
  ```
- Once the step is complete and tested, merge into main:
  ```bash
  git checkout main
  git merge step-02-swift-menubar-shell
  git push origin main
  git branch -d step-02-swift-menubar-shell
  ```
- Branch naming: `step-XX-<short-description>` for plan steps, `feat/<short-description>` for features, `fix/<short-description>` for bug fixes
- This makes it easy to revert any step by reverting the merge commit
