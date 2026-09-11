import os
import socket
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse

app = FastAPI()

TEMPLATE = (Path(__file__).parent / "static" / "index.html").read_text()


@app.get("/", response_class=HTMLResponse)
def read_root():
    page = (
        TEMPLATE.replace("__POD_NAME__", os.environ.get("POD_NAME", "unknown"))
        .replace("__POD_IP__", os.environ.get("POD_IP", "unknown"))
        .replace("__NODE_NAME__", os.environ.get("NODE_NAME", "unknown"))
    )
    return HTMLResponse(content=page)


@app.get("/api/info")
def info():
    return {
        "hostname": socket.gethostname(),
        "pod_name": os.environ.get("POD_NAME", "unknown"),
        "pod_ip": os.environ.get("POD_IP", "unknown"),
        "node_name": os.environ.get("NODE_NAME", "unknown"),
    }


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
