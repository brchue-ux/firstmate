# Autonomy

A local-only Android app for managing personal autonomy: solo projects, the
decisions you make and own, and the daily boundaries you hold.

Single activity, Jetpack Compose, Material 3, Room. No network permission, no
account, no sync - everything lives in one SQLite file on the device.

## Features

| Screen | What it does |
| --- | --- |
| **Dashboard** | Active projects and their completion, recent decisions, today's check-in, and the three quick actions. |
| **My Domains** | Solo projects with a category, a stage (Planning / In Progress / Completed), milestone checkboxes, a Notes & Specifications field, and milestone-derived progress. |
| **Decision Log** | Journal of choices: title, date, category, "My preference" vs "Final choice made", and an "Outcome & how it felt" reflection filled in later. |
| **Boundaries & Habits** | Daily check-in for non-negotiable micro-habits, with a seven-day strip and a 30-day consistency rate per habit. |

Every list handles its empty state explicitly, and nothing is ever seeded into
the database - a fresh install genuinely starts blank.

## Architecture

Clean Architecture with MVVM. Dependencies point inward: `ui` knows `domain`,
`data` implements `domain`, and `domain` knows neither.

```
app/src/main/java/com/firstmate/autonomy/
├── AutonomyApplication.kt      Owns the dependency graph
├── MainActivity.kt             The only activity
├── domain/                     Pure Kotlin - no Android, no Room
│   ├── model/                  ProjectDomain, Milestone, Decision, Habit, …
│   ├── repository/             Interfaces the UI depends on
│   └── usecase/                Dashboard assembly, habit-consistency densifying
├── data/
│   ├── local/                  Room database, DAOs, entities, relations
│   ├── mapper/                 Entity <-> domain model translation
│   └── repository/             Room-backed implementations
├── di/                         Hand-rolled container + one ViewModel factory
└── ui/
    ├── theme/                  Material 3 light/dark + dynamic color
    ├── navigation/             Routes, bottom bar, NavHost
    ├── components/             Shared: empty states, chips, progress, week strip
    ├── dashboard/ domains/ decisions/ habits/   Screen + ViewModel per feature
    ├── preview/                @ThemePreviews / @ScreenPreviews + sample data
    └── util/                   Date formatting
```

State flows one way: Room `Flow` → repository → use case → `StateFlow` in a
ViewModel → Compose. Writes go straight to the database and come back through
the same flow, so no screen keeps a second copy of the truth.

### Notable decisions

- **Manual DI** instead of Hilt. The graph is small and entirely local;
  constructor injection through `AppContainer` keeps builds fast and tests
  plumbing-free.
- **Sparse check-in rows.** The habit table only stores days that were ticked.
  `GetHabitConsistencyUseCase` densifies that into a gap-free series, so the
  weekly strip and the monthly rate share one query.
- **Epoch primitives in entities.** Dates are stored as epoch days and times as
  epoch millis, so range queries stay plain SQL and `java.time` never leaks into
  the schema. Conversion happens in `data/mapper`.
- **Stateless screen content.** Every screen is a `XScreen(viewModel)` wrapper
  around a stateless `XContent(uiState, callbacks)`, which is what the previews
  render.

## Previews

`ui/preview/PreviewData.kt` holds fixed sample data - projects mid-build, a
decision that went the user's way and one that did not, habits with strong,
patchy and empty weeks. `@ThemePreviews` and `@ScreenPreviews` render each
component in light and dark. None of it ever reaches the database.

## Build

```bash
cd autonomy-app
./gradlew assembleDebug     # build
./gradlew test              # JVM unit tests
```

Requires JDK 17+, the Android SDK (compileSdk 35), and network access to
`dl.google.com` for AndroidX and the Android Gradle Plugin. minSdk is 26.

## Tests

`app/src/test/` covers the domain layer on the JVM: milestone-derived progress,
status/category fallbacks for unknown stored values, preference-vs-choice
matching, dashboard aggregation, and the habit-consistency densifying (window
edges, gaps, streaks).
