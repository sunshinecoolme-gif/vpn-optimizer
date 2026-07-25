#!/usr/bin/env python3
import argparse
import ipaddress
import os
import re
import sys
import urllib.parse


def parse_link(link: str) -> tuple[str, int, str, str, bool, str]:
    parsed = urllib.parse.urlsplit(link)
    if parsed.scheme not in ("hysteria2", "hy2"):
        raise ValueError("link must start with hysteria2:// or hy2://")
    password = urllib.parse.unquote(parsed.username or "")
    server = parsed.hostname or ""
    port = parsed.port or 443
    query = urllib.parse.parse_qs(parsed.query)
    sni = query.get("sni", query.get("peer", ["www.bing.com"]))[0]
    insecure = query.get("insecure", ["0"])[0].lower() in ("1", "true", "yes")
    name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else ""
    if not password or not server:
        raise ValueError("link is missing a password or server")
    return server, port, password, sni, insecure, name


def parse_config(path: str, server: str) -> tuple[str, int, str, str, bool, str]:
    with open(path, encoding="utf-8") as stream:
        config = stream.read()
    listen = re.search(r"(?m)^listen:\s*(?:[^:]*:)?(\d+)\s*$", config)
    secret = re.search(r"(?m)^\s+password:\s*(.+?)\s*$", config)
    if not listen or not secret:
        raise ValueError("cannot find listen/password in Hysteria2 config")
    raw = secret.group(1)
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        password = raw[1:-1].replace("''", "'")
    elif len(raw) >= 2 and raw[0] == raw[-1] == '"':
        password = raw[1:-1]
    else:
        password = raw
    if not password:
        raise ValueError("Hysteria2 password is empty")
    return server, int(listen.group(1)), password, "www.bing.com", True, ""


def build_link(server: str, port: int, password: str, sni: str, insecure: bool, name: str) -> str:
    try:
        ipaddress.ip_address(server)
        host = f"[{server}]" if ":" in server else server
    except ValueError:
        host = server
    user = urllib.parse.quote(password, safe="")
    query = urllib.parse.urlencode({"sni": sni, "insecure": "1" if insecure else "0"})
    fragment = urllib.parse.quote(name, safe="")
    return f"hysteria2://{user}@{host}:{port}?{query}#{fragment}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-config", required=True)
    parser.add_argument("--link", default="")
    parser.add_argument("--name", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--output")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        values = parse_link(args.link) if args.link else parse_config(args.server_config, args.server)
        server, port, password, sni, insecure, link_name = values
        result = build_link(server, port, password, sni, insecure, link_name or args.name)
        if args.check:
            return 0
        if not args.output:
            raise ValueError("--output is required unless --check is used")
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(result + "\n")
    except (OSError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
