# App Store Translator

Automatically translates App Store Connect metadata using AI translation.

## Setup

1. Install dependencies: `bundle install`
2. Copy `.env.example` to `.env` and configure:
   - `OPENROUTER_API_KEY` - Your OpenRouter API key
   - `APP_STORE_KEY_ID` - App Store Connect API Key ID
   - `APP_STORE_ISSUER_ID` - App Store Connect Issuer ID
   - `APP_STORE_PRIVATE_KEY` - Your .p8 private key content

## Usage

IMPORTANT: before you can automatically update the metadata for other localizations they need to be selected and saved (with your default language values) from App Store Connect.

IMPORTANT: App name and sub-title cannot be updated automatically and need to be copied-and-pasted from the script output

```bash
ruby translator.rb [options] <APP_ID>
```

### Options

- `-f, --force` - Force retranslation of all languages
- `-w, --whats-new` - Update only What's New field from pending release
- `-a, --auto-detect` - Auto-detect available localizations from App Store
- `-l, --languages LANGS` - Comma-separated list of languages (e.g., 'German,French' or 'de-DE,fr-FR')
- `-h, --help` - Show help message

### Examples

```bash
# Auto-detect existing languages and translate
ruby translator.rb 6747396799 --auto-detect

# Translate specific languages
ruby translator.rb 6747396799 --languages German,French,Korean

# Update only What's New for detected languages
ruby translator.rb 6747396799 --whats-new --auto-detect

# Force retranslation of all content
ruby translator.rb 6747396799 --force --auto-detect
```

### Default Languages

German, French, Spanish, Japanese, Chinese Simplified, Italian, Dutch

### Notes

- App name/subtitle translations may require manual entry in App Store Connect
- Version-specific content (description, keywords, etc.) updates automatically via API
- Manual translations are saved to timestamped `.txt` files when needed
