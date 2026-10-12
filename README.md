# commute

Calculates daily commute costs from a travel-transactions CSV export and
marks which legs are declarable.

## Usage

```bash
chmod +x commute_costs.sh
./commute_costs.sh transactions.csv       # daily totals only
./commute_costs.sh -d transactions.csv    # leg-by-leg composition
```

Requires `gawk`.

## Rules

- **Commute legs:** train trips between Arnhem Centraal and Nijmegen, plus any
  bus, tram, or train leg touching a work stop (Han, Radboudumc, Huygensgebouw,
  Erasmusgebouw, Spinozagebouw, Station Heyendaal).
- **Evening** means 17:00 or later.
- **Evening trip to Nijmegen:** declarable, unless it is part of a same-evening
  roundtrip on a weekend.
- **Evening return to Arnhem:** declarable, unless the most recent earlier trip to
  Nijmegen was on a weekend or the same evening already had a trip to Nijmegen.
- **Graafseweg/Wolfskuil bus rides:** declarable only if you do not return to
  Arnhem that day and the next day is a weekday.

## Notes

CSV exports are ignored by git (see `.gitignore`).
