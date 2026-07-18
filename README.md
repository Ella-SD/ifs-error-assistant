# IFS Error Assistant

A tool that turns IFS ERP error screenshots into plain-English explanations and fix steps.

Upload a screenshot of an IFS error dialog and the app:

1. Extracts the exact error text from the image
2. Matches it against the [IFS 10 error catalog](https://github.com/Ella-SD/ifs-error-catalog)
3. Looks up a curated solution, if one exists, or lets you add one

## Live app

https://ella-sd.github.io/ifs-error-assistant

## How it works

- Static site (`index.html`) hosted on GitHub Pages
- Error catalog loaded at runtime from the [ifs-error-catalog](https://github.com/Ella-SD/ifs-error-catalog) repo
- Screenshot analysis and catalog matching are done via a Vercel proxy in front of the Claude API
- Solutions and archived submissions are stored in browser storage

## Contributing

Solutions can be added directly from the app's **Solution library** tab. See [JOURNAL.md](JOURNAL.md) for session notes and current progress.
