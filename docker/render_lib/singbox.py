"""Assemble sing-box JSON config from parsed VLESS outbounds."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ListenPorts:
    socks: int = 1090
    http: int = 8128


@dataclass
class ClashEndpoint:
    host: str = "127.0.0.1"
    port: int = 9090


def _inbounds(socks_port: int, http_port: int) -> list[dict]:
    return [
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "0.0.0.0",
            "listen_port": socks_port,
        },
        {
            "type": "http",
            "tag": "http-in",
            "listen": "0.0.0.0",
            "listen_port": http_port,
        },
    ]


def render_config(outbounds, ports=None, clash=None, mock=False) -> dict:
    ports = ports or ListenPorts()
    clash = clash or ClashEndpoint()
    config = {"inbounds": _inbounds(ports.socks, ports.http)}
    if mock:
        config["outbounds"] = [{"type": "direct", "tag": "direct"}]
        config["route"] = {"final": "direct"}
        return config

    tags = [item["tag"] for item in outbounds]
    config["outbounds"] = [
        {
            "type": "selector",
            "tag": "proxy",
            "outbounds": tags,
            "interrupt_exist_connections": False,
        },
        *outbounds,
        {"type": "direct", "tag": "direct"},
    ]
    config["route"] = {"final": "proxy"}
    config["experimental"] = {
        "clash_api": {"external_controller": f"{clash.host}:{clash.port}"}
    }
    return config
