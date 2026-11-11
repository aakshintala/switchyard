# Model deprecations research brief

Check the six vendors below for model lifecycle changes as of the report date supplied after this brief. Fetch each public vendor page. Follow links only to the same vendor's public documentation or announcements when the listed page does not contain the lifecycle details.

## Pages to check

- Anthropic: https://platform.claude.com/docs/en/about-claude/model-deprecations
- OpenAI: https://developers.openai.com/api/docs/deprecations
- Gemini: https://aistudio.google.com/docs/deprecations
- OpenRouter: https://openrouter.ai/models
- Databricks: https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/supported-models
- Muse: https://api.muse.ai/v1/models

## Tool scope

Use only public-page fetch tools and the write tool to create the requested report. Do not use shell, terminal, or other tools. The current `delegate` CLI exposes no flag that enforces a tool allowlist, so this is a prompt-only restriction and cannot be guaranteed by the caller.

## What to report

Report only evidence found on the checked pages or their vendor-owned links:

- `deprecated`: a model still available but with a stated retirement date. Include the date.
- `retired`: a model the vendor says has already been retired or removed.
- `new`: a model the vendor explicitly identifies as newly released or added. Do not infer that a model is new just because it appears in a current catalog.

Cite the specific source page URL in every row. Do not report speculation. If a page fails to load or cannot be parsed, include that vendor and a short, non-sensitive reason under `## skipped`; still report results from every page that succeeded.

If there are no evidenced changes and no failed pages, do not create a report. If there are changes or skipped pages, write the report to the absolute scratch report path supplied after this brief. Do not write anywhere else.

## Report format

Use the supplied report date and source line exactly:

```markdown
# Model deprecations YYYY-MM-DD
source: model-deprecations <git short sha>

## <vendor>

| model | kind | field | vendor | models.dev |
|---|---|---|---|---|
| model-id | deprecated | retirement date | YYYY-MM-DD (source: https://vendor.example/page) | - |
| model-id | retired | source | https://vendor.example/page | - |
| model-id | new | source | https://vendor.example/page | - |

## skipped
- vendor: short reason
```

Use one section per vendor with reported changes. Include the table header and separator in each vendor section. Always include `## skipped` at the end, even when no pages were skipped. For a `deprecated` row, the vendor cell must contain the retirement date and source URL. For `retired` and `new` rows, the vendor cell must contain the source URL. Do not invent models.dev values; use `-`.
