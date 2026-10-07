# Brotli streams

Made with the brotli tool (google/brotli 1.2.0):

- `words.txt.br`: `brotli -q 11 -w 16 words.txt`, which takes words from
  the static dictionary, some of them transformed.
- `words-x40-w10.br`: `words.txt` 40 times, `brotli -q 9 -w 10` (a 1 KiB
  window).
- `words-x40-q1.br`: `words.txt` 40 times, `brotli -q 1`.
