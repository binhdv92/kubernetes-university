import os
import socket

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def read_root():
    return {
        "hostname": socket.gethostname(),
        "pod_name": os.environ.get("POD_NAME", "unknown"),
        "pod_ip": os.environ.get("POD_IP", "unknown"),
        "node_name": os.environ.get("NODE_NAME", "unknown"),
    }


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
