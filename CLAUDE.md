# Project Rules for Claude

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
