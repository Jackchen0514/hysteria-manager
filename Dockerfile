FROM python:3.12-alpine
WORKDIR /app
COPY hy2mgr ./hy2mgr
ENV HY2M_DB=/data/hy2mgr.db HY2M_PORT=8080
VOLUME /data
EXPOSE 8080
CMD ["python", "-m", "hy2mgr"]
