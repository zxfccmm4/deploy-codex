# Model catalog provenance

`models-gpt56-non-lite.json` is derived from the model catalog embedded in the official `@openai/codex@0.147.0` platform package.

Changes made by this repository:

1. Keep only `gpt-5.6-sol` and `gpt-5.5`.
2. Set `use_responses_lite` to `false` for the GPT-5.6 coding model.
3. Preserve all other selected model metadata byte-for-byte at the parsed JSON value level.

The upstream Codex package is licensed under Apache-2.0. See `LICENSE-APACHE-2.0.txt` in this directory. The repository's own scripts and documentation remain under the root MIT license.
