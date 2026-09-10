# Local fork ops (abk234)

LanguageTool upstream is a huge Java monorepo (no official Docker Compose). This fork adds:

- `docker/compose/docker-compose.yml` — runs [erikvl87/languagetool](https://hub.docker.com/r/erikvl87/languagetool) on port **8010**
- `scripts/languagetool-app.sh` — start / stop / update / backup / check
- `scripts/sync-upstream.sh` — merge `upstream/master` into the fork; push **origin only**

## Quick start

```bash
cd ~/workspace_for_ai/eval/languagetool
./scripts/languagetool-app.sh setup
./scripts/languagetool-app.sh start
./scripts/languagetool-app.sh check 'This are wrong.'
```

API: `POST http://127.0.0.1:8010/v2/check` (`language` + `text`).

## N-grams (English)

English n-gram data lives under `docker/compose/ngrams/en/` (~14 GB, gitignored). Compose mounts it read-only and sets `langtool_languageModel=/ngrams` with `Java_Xmx=2g`.

Improves many confusion pairs (e.g. weather/whether). Some pairs like their/there are **disabled** in upstream OSS `confusion_sets.txt` (false-positive risk), so they still won’t flag.

## SquadOS

Not applicable — no LLM client, web search, or app telemetry hooks in this stack.
