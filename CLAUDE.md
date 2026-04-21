# blackmatter-services — Claude Orientation

One-sentence purpose: NixOS + home-manager modules defining recurring
microservice lifecycles (systemd units on Linux, launchd agents on Darwin,
scheduled tasks, health probes).

## Classification

- **Archetype:** `blackmatter-component-hm-nixos`
- **Flake shape:** `substrate/lib/blackmatter-component-flake.nix`
- **Option namespace:** `blackmatter.components.services`

## Where to look

| Intent | File |
|--------|------|
| NixOS systemd services | `module/nixos/` |
| HM-side launchd / systemd-user units | `module/home-manager/` |

## Service definition pattern

Each service gets a submodule:

```nix
blackmatter.components.services.<name> = {
  enable = true;
  command = ...;
  schedule = "*:0/10";   # systemd onCalendar syntax
  healthProbe.url = ...;
};
```

Backend picks the right wire-up: systemd on NixOS, launchd on Darwin.

## What NOT to do

- Don't fork service implementations here. This repo wires **existing** binaries
  into systemd/launchd; the binaries come from elsewhere.
