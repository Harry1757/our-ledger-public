FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ledger.py auth.py firestore_store.py ./
ENV PYTHONUNBUFFERED=1 LEDGER_STORAGE=firestore
USER 65534:65534
CMD ["python", "app.py", "--host", "0.0.0.0"]
