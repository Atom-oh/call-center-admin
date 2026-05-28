# HITL UI Streamlit container — Phase 1.
# Build context = repo root (`docker build -f src/hitl_ui/Dockerfile src/`).
# The src/ layout puts hitl_ui/, lib/, prompts/ at the same level.

FROM python:3.12-slim

WORKDIR /app

COPY hitl_ui/requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY hitl_ui/ /app/hitl_ui/
COPY lib/ /app/lib/
COPY prompts/ /app/prompts/

# PYTHONPATH layout:
#   /app/hitl_ui  → puts `hitl_lib` package on the import path (auth, ddb_access)
#   /app          → puts `lib` (root project Lambda helpers, prompts/) on the path
# The hitl_lib name was chosen specifically to avoid shadowing root `src/lib/`.
ENV PYTHONPATH=/app/hitl_ui:/app

EXPOSE 8501

CMD ["streamlit", "run", "/app/hitl_ui/streamlit_app.py", \
     "--server.port=8501", \
     "--server.address=0.0.0.0", \
     "--server.headless=true"]
