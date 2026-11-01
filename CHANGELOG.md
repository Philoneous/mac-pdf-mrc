# Changelog

The release notes on GitHub and in the update window come from this file. Add one line per user-visible change
under "Unreleased", in English (CI rejects German text). The release workflow publishes these lines and moves them
under the new version number. Earlier versions: see the
[GitHub releases](https://github.com/Philoneous/mac-pdf-mrc/releases).

## Unreleased

- Conversions that show no progress for 30 minutes are stopped; the file stays unchanged and further jobs continue.
- Pale photos and faded receipts are no longer removed as blank pages (new setting: ink contrast for blank pages).
- Oversized pages can be fitted to A4, US Letter or US Legal.
- Every setting's tooltip now shows its range, what both ends mean and the default; out-of-range values are corrected.
- Encrypted PDFs are left unchanged.
- "Replace original": if anything fails, the original is restored from the Trash.
- Quick actions work when the app is installed in a folder with special characters in its path.
- Jobs started while the app is quitting are no longer lost.
- A damaged history file no longer clears the whole history.
- Smaller download (107 MB instead of 131 MB); the result check now uses macOS's own PDF engine instead of Poppler.
- Complete license notices for all bundled components; source code of the copyleft components is published in the release "third-party-sources".
