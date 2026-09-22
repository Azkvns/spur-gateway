# README polish + Docker install

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Переписать корневой [`README.md`](README.md) так, чтобы он выглядел опрятнее и сразу объяснял продукт, требования и два способа поднять шлюз — из репозитория и из готового Docker-образа GHCR.

**Architecture:** Один файл — корневой README на английском. Документация в `docs/` не меняется; README даёт самодостаточный onboarding и ссылается на GitHub Pages / `docs/` за деталями. Секреты (`SPUR_SUB_URL`) только через env / `.env`, без примеров с реальными URL.

**Tech Stack:** Markdown, существующие бейджи GitHub/GHCR, Docker / Docker Compose, Make-таргеты из [`Makefile`](Makefile), образ `ghcr.io/azkvns/spur-gateway`.

## Global Constraints

- Language: English only (RU остаётся в [`docs/ru/index.md`](docs/ru/index.md)).
- Scope: only [`README.md`](README.md) — do not edit `docs/docker.md` or other docs.
- Keep existing badge set (test, maintainability, license, GHCR, docs).
- Loopback ports only: `127.0.0.1:1090` (SOCKS5), `127.0.0.1:8128` (HTTP CONNECT).
- No `NET_ADMIN` / TUN claims; host routes unchanged.
- Image: `ghcr.io/azkvns/spur-gateway` tags `:latest`, `:vX.Y.Z`.

## File map

- Modify: [`README.md`](README.md) — full rewrite of structure and content (badges retained).
- Create (at execution start, per writing-plans): `docs/superpowers/plans/2026-09-22-readme-polish-docker.md` — copy of this plan for agent tracking.
- Do not create: new compose override files, screenshots, or Russian README.

## Target README structure

1. Title + badges (unchanged set)
2. Short product pitch + key properties (loopback, opt-in, Docker + sing-box-extended)
3. Features (bullet list: SOCKS5/HTTP CONNECT, `spur` wrapper, watchdog/health, mock mode)
4. Requirements (Docker Compose, VLESS subscription URL for live mode)
5. Install from source (`git clone` → `make env` → PATH → `make up` → smoke)
6. Install via Docker image (GHCR): `docker pull` + `docker run` with ports and `SPUR_SUB_URL`
7. Usage snippets (`spur curl`, Chrome `--proxy-server`)
8. Useful Make targets (table or short list from Makefile)
9. Documentation links
10. CI / releases (condensed from current section)
11. License + NOTICE

## Concrete Docker section (must appear verbatim in spirit)

```bash
docker pull ghcr.io/azkvns/spur-gateway:latest

docker run -d --name spur-gateway --restart unless-stopped \
  -e SPUR_SUB_URL='your-subscription-url' \
  -p 127.0.0.1:1090:1090 \
  -p 127.0.0.1:8128:8128 \
  ghcr.io/azkvns/spur-gateway:latest
```

Note in README: CLI helpers (`spur`, `spur-gw`) still need the repo/`bin` on `PATH` if used; bare container only exposes the proxies. For mock without subscription: `-e SPUR_MOCK=1`.

## Tasks

### Task 1: Write polished README

**Files:**
- Modify: `README.md`
- Create: `docs/superpowers/plans/2026-09-22-readme-polish-docker.md` (plan archive)

**Interfaces:**
- Consumes: current badge URLs, Makefile targets (`env`, `up`, `up-mock`, `down`, `status`, `logs`), ports and image name from compose/docs
- Produces: complete English README as sole deliverable

- [x] **Step 1:** Save this plan to `docs/superpowers/plans/2026-09-22-readme-polish-docker.md` (checkbox syntax preserved).
- [x] **Step 2:** Replace `README.md` with the full content (prebuilt path: `docker pull` + `docker run` only).
- [x] **Step 3:** Visually skim rendered Markdown: headings hierarchy, fenced blocks, no broken relative links to `docs/` or `NOTICE`.
- [x] **Step 4:** Commit README and plan file.

## Self-review (spec coverage)

- Nicer structure: sections, table for ports and Make targets — covered
- More info: features, requirements, usage, CI — covered
- Docker container install: GHCR pull + `docker run` — covered
- English only, README-only scope — covered
- No placeholders left; compose-with-image removed as inaccurate
