# shared

Data every app reads.

- `inspo.json` — the inspo video list. Windows builds it straight in; for
  the others, `scripts/make-inspo.sh` writes it out as code (mac, android,
  web). Add new videos at the end: order is numbering.
