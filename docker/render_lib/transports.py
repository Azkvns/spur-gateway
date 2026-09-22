"""VLESS TLS and transport blocks for sing-box outbounds."""

from __future__ import annotations

from render_lib.subscription import normalize_extra_json, query_first

XHTTP_EXTRA_KEY_MAP = {
    "scMaxEachPostBytes": "sc_max_each_post_bytes",
    "scMaxConcurrentPosts": "sc_max_concurrent_posts",
    "scMinPostsIntervalMs": "sc_min_posts_interval_ms",
    "xPaddingBytes": "x_padding_bytes",
    "noGRPCHeader": "no_grpc_header",
    "xmux": "xmux",
}


def tls_settings(qs: dict[str, list[str]]) -> dict | None:
    security = query_first(qs, "security")
    if security not in {"reality", "tls"}:
        return None
    tls: dict = {"enabled": True}
    server_name = query_first(qs, "sni", "peer")
    if server_name:
        tls["server_name"] = server_name
    fingerprint = query_first(qs, "fp")
    if fingerprint:
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
    if security == "reality":
        pbk = query_first(qs, "pbk")
        if not pbk:
            raise ValueError("reality link missing pbk")
        tls["reality"] = {
            "enabled": True,
            "public_key": pbk,
            "short_id": query_first(qs, "sid"),
        }
    return tls


def _path_host(
    transport_type: str,
    qs: dict[str, list[str]],
    host_field: str,
) -> dict:
    transport: dict = {"type": transport_type}
    path = query_first(qs, "path")
    if path:
        transport["path"] = path
    host = query_first(qs, "host")
    if host:
        if host_field == "headers":
            transport["headers"] = {"Host": host}
        else:
            transport[host_field] = host
    return transport


def _grpc_transport(qs: dict[str, list[str]]) -> dict:
    return {
        "type": "grpc",
        "service_name": query_first(qs, "serviceName", "service_name"),
    }


def _xhttp_transport(qs: dict[str, list[str]]) -> dict:
    transport: dict = {
        "type": "xhttp",
        # sing-box-extended rejects configs that omit padding.
        "x_padding_bytes": "100-1000",
    }
    path = query_first(qs, "path")
    if path:
        transport["path"] = path
    host = query_first(qs, "host")
    if host:
        transport["host"] = host
    mode = query_first(qs, "mode")
    if mode:
        transport["mode"] = mode
    extra = normalize_extra_json(query_first(qs, "extra"))
    for src, dest in XHTTP_EXTRA_KEY_MAP.items():
        if src not in extra:
            continue
        value = extra[src]
        if dest == "xmux" and isinstance(value, dict):
            transport["xmux"] = value
        else:
            transport[dest] = value
    return transport


def _ws_transport(qs: dict[str, list[str]]) -> dict:
    return _path_host("ws", qs, "headers")


def _httpupgrade_transport(qs: dict[str, list[str]]) -> dict:
    return _path_host("httpupgrade", qs, "host")


_TRANSPORT_BUILDERS = {
    "grpc": _grpc_transport,
    "ws": _ws_transport,
    "httpupgrade": _httpupgrade_transport,
    "xhttp": _xhttp_transport,
}


def build_transport(transport_type: str, qs: dict[str, list[str]]) -> dict | None:
    if transport_type in {"", "tcp"}:
        return None
    builder = _TRANSPORT_BUILDERS.get(transport_type)
    if builder is None:
        return None
    return builder(qs)
