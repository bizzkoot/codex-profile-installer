# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.2] - 2025-09-20

### Added
- New agent profile `LogmasterPro.md` for automating changelog updates.

### Changed
- Major improvements to `codex_profile_installer.sh`:
  - Added version mismatch detection to prevent conflicts.
  - Implemented safer temporary file handling and cleanup.
  - Enhanced interactive prompts with clipboard support and better validation.
  - Refactored agent installation logic for clarity and robustness.

## [0.0.1] - 2025-09-18

### Added
- Initial release of the Codex Profile Installer.
- `codex_profile_installer.sh` script for installation.
- `Profile/markdown.md` with markdown profile.
- `README.md` with instructions.