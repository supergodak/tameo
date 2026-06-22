# Third-Party Licenses

Tameo's own source code is licensed under the [MIT License](LICENSE), © 2026 ATI Inc.
The third-party components listed below are the works of their respective authors and
are distributed under their own licenses. Their copyright notices are reproduced here.

> Note: dependencies are added in later phases. Each entry's **full license text** will be
> embedded once the dependency is actually wired into the build (see `project.yml`).
> This file currently records the intended components and their license terms.

---

## Sauce — _used (M2), pinned 2.5.0_

- Source: https://github.com/Clipy/Sauce
- License: MIT
- Copyright: © Clipy Project
- Purpose: resolves keyboard key codes per active layout (QWERTY / Dvorak / JIS, etc.),
  so the synthesized ⌘V paste hits the correct physical key regardless of layout.

## KeyboardShortcuts — _used (M2), pinned 3.0.1_

- Source: https://github.com/sindresorhus/KeyboardShortcuts
- License: MIT
- Copyright: © Sindre Sorhus
- Purpose: global hotkey registration (default ⌘⇧V) to open the history palette,
  plus the recorder UI used later in settings (M6).

## Sparkle — _planned (Phase 3)_

- Source: https://github.com/sparkle-project/Sparkle
- License: MIT (with additional permissive notices for bundled components)
- Copyright: © Sparkle Project contributors
- Purpose: secure auto-update for directly-distributed (non-App-Store) macOS apps.

---

When distributing a built/notarized release, include each dependency's complete license
text here (and/or in the app's About panel) as required by the respective licenses.
