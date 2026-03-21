# Project Rules for Claude

## Python Environment
- **Always use `uv`** instead of `pip` or `pip3`
- **Always use a virtual environment (`venv`)** — never install packages globally
- Standard setup for any Python work in this project:
  ```bash
  uv venv .venv
  source .venv/bin/activate
  uv pip install -r requirements.txt
  ```
- Never use `--break-system-packages`
- Never use bare `pip install` or `pip3 install`
