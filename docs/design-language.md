# Scout: design language

Scout looks like a night-time instrument: deep ink and indigo, one warm signal color, glass on top. It is built on macOS 26 Liquid Glass and does not borrow from Syn.

Code: `mac/Scout/Design/`.

## Mark

A pointer with three signal arcs coming from its tip: *point* and *talk* in one glyph (`ScoutMark.swift`).

- The arcs double as a progress display. During onboarding, one arc lights per granted permission, and a pulse runs through lit arcs while Scout is ready or scouting.
- The menu bar icon is the same mark rendered as a template image. It takes the flare color while scouting.
- The app icon (`script/render-app-icon.sh`) renders the mark on an ink-to-indigo squircle with a flare glow in the lower-right corner.

## Color

| Token | Hex | Use |
|---|---|---|
| `ink` | `#07080D` | Deepest background |
| `night` | `#0E1020` | Panels, glass tint |
| `indigo` | `#1C2156` | Aurora field |
| `plum` | `#3B1650` | Aurora field |
| `flare` | `#FF6A3D` | The one accent: primary actions, recording, pins |
| `flareGradient` | `#FFB36B → #FF6A3D → #FF3D6E` | Primary buttons, pressed keycaps |
| `beam` | `#8B96FF` | Aiming, element highlights, source locations |
| `mint` | `#42E2A4` | Success, granted, listening |
| `amber` | `#FFB84D` | Waiting |
| `rose` | `#FF5876` | Denied, destructive |

Text is white at 100%, 66% and 42% opacity. Hairlines are white at 10%.

Rule: flare means "you" (your voice, your pins, your primary action). Beam means "Scout's understanding" (what Scout thinks you are pointing at). Keeping these apart makes it clear what the user did and what Scout inferred.

## Backdrop

`Aurora` is a 3×3 `MeshGradient` whose inner points drift slowly (periods of 25–50 s). The lower-left control point carries a glow color that changes per onboarding step, animated with a spring. `Grain` adds a fixed noise layer at 1.5–5% opacity so gradients don't band. Both stop moving when Reduce Motion is on.

## Type

System fonts only.

| Style | Spec |
|---|---|
| Hero | SF Pro Bold, expanded width, 52 pt, tracking −1.5 |
| Title | SF Pro Semibold, 30 pt, tracking −0.4 |
| Headline | Semibold, 15 pt |
| Body | Regular, 14 pt, line spacing +3 |
| Eyebrow | Semibold, expanded width, 11 pt, uppercase, tracking 1.6, flare-soft |
| Mono | SF Mono Medium, 12 pt, used for paths, URLs and source locations |
| Transcript | Medium, 26 pt, used for live speech |

## Surfaces and shape

- Cards are `glassEffect(.regular.tint(night @ 20–30%))` in continuous rounded rectangles with a 20–24 pt radius. The item that needs attention gets a beam-tinted glass and a 1 pt beam outline.
- Primary buttons are flare-gradient capsules with a soft flare shadow. Secondary buttons are interactive glass capsules. Tertiary buttons are text only.
- Keycaps are rounded squares with a 2 pt drop edge. Pressed keycaps sink 2 pt and fill with the flare gradient.
- Status badges are a dot plus a label on a 12% tint of their tone.

## Motion

| Token | Spring | Use |
|---|---|---|
| `snappy` | response 0.32, damping 0.86 | Presses, toggles, hover |
| `smooth` | 0.55, 0.9 | Layout and color changes |
| `bouncy` | 0.45, 0.62 | Success moments: checks, pins, arcs lighting |
| `step` | 0.6, 0.88 | Onboarding step transitions: slide 36 pt, fade, scale 0.98 |

Moments of delight are kept for real events: a permission granted, a pin dropped, a snippet closed, a task delivered. Everything else stays quiet. Reduce Motion replaces movement with fades.

## Copy

Short, direct, second person. Say what happens, not what the feature is called. Examples: "Scout hears you", "Switch on Scout", "Scout resumes right here". Avoid "packet", "capture mode" and other internal terms in the UI.
