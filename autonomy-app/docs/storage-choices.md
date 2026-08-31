# Local storage: Room, SQLCipher, or DataStore

Three stores were on the table. This app uses two of them and deliberately
declines the third. The reasoning matters more than the conclusion, because the
right answer changes with the shape of the data.

## The rule of thumb

| Use | When | Cost of getting it wrong |
| --- | --- | --- |
| **Room** | Data is relational, grows unbounded, or is queried/sorted/filtered | Hand-rolling queries over a blob; O(n) reads that should be indexed |
| **Preferences DataStore** | A handful of independent scalars, read whole, never queried | A table, a DAO, an entity and a migration path for one boolean |
| **Proto DataStore** | One structured object with a schema, read whole | Type-safety you did not need, plus a protobuf toolchain |
| **Room + SQLCipher** | The data would harm the user if the device were compromised | A passphrase problem you have not solved, and no plaintext recovery |

## What this app does

**Room** holds domains, milestones, decisions, habits and check-ins.

Every one of those is genuinely relational or genuinely queried:

- Milestones are a one-to-many under a domain with a cascading delete. That is a
  foreign key, not a nested list in a blob.
- The decision log is sorted by date and paged (`observeRecent(limit)`).
- Habit check-ins are range-scanned by date for the 30-day window, over an
  index. Storing them as a serialised map would turn each dashboard render into
  a full deserialise-and-scan.
- All of it grows without bound.

**Preferences DataStore** holds the celebration setting.

One boolean, read as a whole, never queried, never joined. Putting it in Room
would mean an entity, a DAO, a table and a migration obligation for a value the
app reads once per launch. DataStore also gives an async, transactional
`Flow<Preferences>` without a `commit()` that can silently block the main thread
the way SharedPreferences does.

**Proto DataStore** was not needed. It is the right upgrade the moment settings
grow into a structured object with invariants worth type-checking; with one
boolean, the `.proto` file and codegen would cost more than they return.

## SQLCipher: analysed and declined, with the condition to revisit

`net.zetetic:android-database-sqlcipher` plus `androidx.sqlite` swaps Room's
SQLite driver for an encrypted one:

```kotlin
// Not enabled in this app - shown so the trade-off is concrete.
val factory = SupportOpenHelperFactory(passphraseBytes)
Room.databaseBuilder(context, AutonomyDatabase::class.java, DATABASE_NAME)
    .openHelperFactory(factory)
    .build()
```

**Why it is not on.** The decision log is candidly personal - family dynamics,
boundaries, what you wanted versus what you settled for. That argues for
encryption. But encryption is only worth what the key management behind it is
worth, and the honest options are:

1. **Key in the Android Keystore, no user secret.** Protects against offline
   inspection of a *powered-off, encrypted* device barely more than
   full-disk encryption already does, and protects against nothing once the
   device is unlocked. It mostly adds the risk of permanent data loss if the
   keystore entry is invalidated - which happens on some biometric and lock
   screen changes.
2. **Passphrase the user types.** Real protection, real cost: a prompt on every
   cold start, and no recovery path whatsoever for a journal the user may have
   kept for years. For an app whose entire point is low-friction daily use, that
   is a poor trade.

Since Android 10, `android:allowBackup` plus device encryption already covers
the realistic threat model here: a lost or stolen device. SQLCipher would defend
against an attacker with root on an unlocked device - who can also read your
keystore-held key.

**Revisit it if any of these become true**, at which point option 2 becomes
worth its cost:

- The app gains cloud sync or any off-device export.
- It is used on shared or managed devices.
- It starts holding third-party information rather than only the user's own.
- A compliance regime requires encryption at rest as a control in its own right.

If it is revisited, do it with a real key-derivation step (Argon2 or scrypt over
a user secret), a written recovery story, and `PRAGMA cipher_memory_security`
considered explicitly - not by bolting a hardcoded passphrase onto the builder,
which is theatre.

## Why the schema survived the TypeConverter refactor

Entities now declare `LocalDate`, `Instant` and enums directly, with
`Converters` marshalling them. The stored representation was deliberately kept
identical to the hand-rolled mapping it replaced - epoch days, epoch millis,
enum `name` - so the columns did not change, no migration was needed, and
already-installed builds keep their data.

This is worth doing on purpose rather than by luck: had the converters chosen,
say, ISO-8601 strings for dates, every date column would have changed type and
every existing row would have needed a migration for zero user-visible gain.
