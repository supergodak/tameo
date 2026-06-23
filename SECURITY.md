# Security Policy / セキュリティポリシー

## Reporting a vulnerability

Tameo handles clipboard data entirely on-device, but security reports are always welcome.

- **Preferred:** open a [private security advisory](https://github.com/supergodak/tameo/security/advisories/new) on GitHub.
- Or email: _(security contact to be added before public release)_

Please **do not** open a public issue for security problems. We aim to acknowledge reports within a few days.

When reporting, include: the version (`v0.1.0 (build N)` shown in the menu / About panel), macOS version, and steps to reproduce.

## Supported versions

Tameo is pre-1.0; only the latest release is supported. Please update before reporting.

## Scope notes

- Tameo makes **no network calls** for its core features (see [PRIVACY.md](PRIVACY.md)); the only optional network activity is the Sparkle update check in future releases.
- Tameo requires macOS **Accessibility** permission solely to synthesize ⌘V for pasting.

---

## 日本語

### 脆弱性の報告

Tameo はクリップボードデータを端末内のみで扱いますが、セキュリティ報告は歓迎します。

- **推奨:** GitHub の [非公開セキュリティ勧告](https://github.com/supergodak/tameo/security/advisories/new) を作成してください。
- またはメール: _（公開前に連絡先を追記）_

セキュリティ問題は**公開 Issue にしないで**ください。数日以内の応答を目指します。報告時はバージョン（メニュー/About の `v0.1.0 (build N)`）・macOS バージョン・再現手順を添えてください。

### 対応バージョン

1.0 未満のため、最新リリースのみ対応します。報告前に更新してください。
