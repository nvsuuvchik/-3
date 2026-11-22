FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=8000

WORKDIR /srv/counter_app

COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app/app.py ./app.py

RUN useradd -m -u 1005 runner \
    && mkdir -p /data \
    && chown -R runner:runner /data /srv/counter_app

USER 1005

EXPOSE 8000

CMD ["python", "app.py"]
