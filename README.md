# Plaintexter

[Download for Mac](https://bergmayer.net/plaintexter) · Free · macOS 13 or later · Apple silicon and Intel

A tiny native macOS app with a single **pt** menu bar button. Click it to convert the clipboard using the selected mode. Right-click or Control-click it to choose the mode:

- **Convert to Plain Text** replaces the clipboard with plain text.
- **Convert to Markdown** replaces rich text with Markdown, preserving headings, bold, italic, links, lists, code, strikethrough, and simple HTML tables when the source provides that information.

These are mutually exclusive checked options. Plain Text is the default, and the app remembers your selection across launches. Choosing an option changes the mode for future clicks without modifying the clipboard. The menu also includes **Undo Last Conversion**, **Open at Launch**, **Help**, and **Quit Plaintexter**. Open at Launch uses macOS Login Items to start the app when you log in. Help opens [bergmayer.net/plaintexter](https://bergmayer.net/plaintexter).

Unchecking Open at Launch removes the login item. It does not quit the currently running app.

## Install

Open the downloaded DMG and drag Plaintexter to Applications, then launch it. You can also keep it in `~/Applications`. If launched from another location, the app offers to move to `~/Applications`, quit, and reopen the installed copy. Replacing an existing copy requires confirmation and preserves the previous app in the Trash. A copy on a read-only disk image stays on the image, which you can eject afterward.

When you click **pt**, an ellipsis appears while conversion runs, followed by a brief checkmark on success. The app has no Dock icon or main window. It reads the clipboard only when you ask it to convert. macOS may ask for clipboard access the first time.

## Text in images

Both conversion options automatically run on-device OCR on images using Apple's Vision framework. This includes screenshots, copied image files, images in HTML, and embedded RTF/RTFD attachments. When an image contains at least 40 letters or digits recognized with reasonable confidence, its text replaces the image reference. Surrounding document text stays in order. If no substantial text is recognized, the clipboard receives exactly `No text found to OCR.` in either format. Images embedded in a text selection are replaced with that message while surrounding text is preserved. Images are not saved as a fallback.

Markdown conversion escapes literal Markdown characters in OCR output and retains recognized line breaks; OCR does not infer headings or other formatting. Recognition supports automatic language detection, but accuracy and reading order depend on image quality and layout.

OCR runs in the background. If you copy something else before conversion finishes, the newer clipboard is left alone. Undo restores the original clipboard, including image data, even after a no-text message.

Web images use clipboard pixels when supplied. If an HTML image has only a source URL, the app downloads that image for local OCR, with a 20 MB limit and a short timeout. These requests use no saved cookies or credentials. Images that cannot be loaded produce the same no-text message. No clipboard content or recognized text is uploaded, and no scripts run.

## PDFs

Both conversion options convert PDF data on the clipboard, copied PDF files, and PDF attachments in rich text. Pages are processed in order. Embedded text is extracted directly; pages without usable text are rendered and read with on-device OCR. Scanned pages with only a short digital footer or page number also receive OCR. Unlike ordinary images, scanned PDF pages retain short recognized text such as "PAID."

Markdown conversion preserves available native bold, italic, and links. Text from scanned pages becomes escaped Markdown with line breaks. PDF reading order, paragraph structure, columns, and tables may need cleanup; OCR does not infer formatting from page images.

Blank pages are skipped. A nonblank page that yields no readable text is marked in the output. PDFs that yield no readable text at all produce `No text found to OCR.`. PDFs that require a password, disallow copying, or cannot be opened leave the clipboard unchanged. Undo restores the original PDF representation or file reference. PDF processing stays on this Mac and does not change the source files.

## Other clipboard content

| Content | Plain Text | Markdown |
| --- | --- | --- |
| Plain text, including existing Markdown | Unchanged text | Unchanged text |
| An image with substantial readable text | Recognized text | Recognized text, escaped for Markdown |
| A PDF, including a copied PDF file | Extracted text plus OCR of scanned pages | Available native formatting plus OCR text |
| Other copied files | Full paths, one per line | File links |
| A URL | URL text | A Markdown link when copied as a URL |
| An image with no substantial recognized text, including copied image files and HTML images | `No text found to OCR.` | `No text found to OCR.` |
| Rich text attachments | Saved attachment paths | Links to saved attachments |
| Unsupported content | Leave clipboard unchanged | Leave clipboard unchanged |

Non-image file attachments in rich text are saved under `~/Library/Application Support/Plaintexter/Clipboard Images` when a file reference is needed. Existing images saved by older versions also remain there. New image conversions do not save fallback files. This folder is not a clipboard history. Local attachment links work on this Mac; sharing Markdown does not include those files.

Undo keeps one original clipboard snapshot in memory until another conversion or app exit. It is available only while the clipboard still contains that conversion, so it cannot replace something copied afterward. Both conversions write only the plain text pasteboard type.

Markdown conversion uses semantic HTML and common inline styles, or native RTF/RTFD attributes. Arbitrary page CSS, complex table layouts, and visual formatting without document structure cannot always be represented in Markdown. Fonts, colors, and underline are discarded.

## Build and run

Requires macOS 13 or later and Xcode with Swift 6 or later. No third-party dependencies.

```sh
./scripts/build.sh
open "$HOME/Applications/Plaintexter.app"
```

Every build installs the signed app directly in `~/Applications/Plaintexter.app`, replacing the previous build after the new bundle passes signature verification. Quit and reopen Plaintexter to use a newly installed build. The build script signs locally by default; set `SIGNING_IDENTITY` for Developer ID signing with Hardened Runtime and a secure timestamp. Set `UNIVERSAL=1` to build both Apple silicon and Intel architectures.

The bundle includes a lowercase `pt` icon. Its vector drawing is in `scripts/generate-icon.swift`; regenerate `Resources/AppIcon.icns` with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/generate-icon.swift
```

Open `Package.swift` in Xcode to work on the source. To run the conversion and clipboard tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Signed and notarized releases

Requires a Developer ID Application certificate, Xcode command-line tools, Python 3, and a working `notarytool` Keychain profile. No credentials are stored in the repository.

```sh
NOTARY_PROFILE=your-keychain-profile ./scripts/release.sh
```

The script runs tests, builds a universal app in `~/Applications`, signs it, submits it to Apple, and staples its ticket. It then creates a DMG with an Applications shortcut and drag-to-install artwork, signs and notarizes the DMG, and verifies both signatures and Gatekeeper acceptance. The final DMG and SHA-256 checksum go in `~/Applications/Plaintexter Releases`. `OUTPUT_DIR` overrides the release-artifact directory; the app bundle remains in `~/Applications`.

The packaging script installs `dmgbuild` in a project-local virtual environment. It is a build tool only; the app itself uses Apple's built-in frameworks and has no third-party runtime dependencies.

`website/` contains the standalone Blot landing page and icon. Copy those files to the Blot folder root and the final DMG to `files/plaintexter/`. Blot serves `_plaintexter.html` at `/plaintexter`. Update the page's version and download URL for each release.
