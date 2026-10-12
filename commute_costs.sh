#!/usr/bin/env bash
# commute_costs.sh
# Per-day commute costs. Default: daily totals only. -d/--detail: leg-by-leg composition.
#
# Usage: ./commute_costs.sh [-d|--detail] reistransacties_*.csv
# Requires gawk (macOS: brew install gawk; Linux: usually preinstalled).

set -euo pipefail

usage() {
  echo "Usage: $0 [-d|--detail] <transactions.csv>" >&2
  echo "  -d, --detail   print the leg-by-leg composition for each day" >&2
}

DETAIL=0
FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--detail) DETAIL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)           FILE="$1"; shift ;;
  esac
done

[[ -n $FILE && -f $FILE ]] || { usage; exit 1; }
command -v gawk >/dev/null || { echo "gawk is required" >&2; exit 1; }

# Write the awk program to a temp file so no shell quoting is involved.
AWK_SRC="$(mktemp)"
trap 'rm -f "$AWK_SRC"' EXIT

cat > "$AWK_SRC" <<'AWK'
function clean(s) { gsub(/^"|"$/, "", s); gsub(/^ +| +$/, "", s); return s }
function euro(s)  { s = clean(s); gsub(/€| /, "", s); gsub(/,/, ".", s); return s + 0 }
function mins(t,  p) { split(t, p, ":"); return p[1] * 60 + p[2] }
function fmt(x) { return sprintf("€%.2f", x) }

# Nijmegen train stops used for commuting (Goffert removed)
function isNijTrain(s) { return s ~ /^Nijmegen( Lent| Heyendaal)?$/ }

# Any Graafseweg/Wolfskuil bus stop (spellings vary in the export)
function isGraaf(s) { return s ~ /^Nijmegen, Graafseweg/ }

# DD-MM-YYYY -> weekday tests (noon avoids DST edge cases)
function isWeekend(d,  p, t) {
  split(d, p, "-")
  t = mktime(p[3] " " p[2] " " p[1] " 12 0 0")
  return (strftime("%u", t) + 0) >= 6            # Saturday=6, Sunday=7
}
function nextIsWorkday(d,  p, t) {
  split(d, p, "-")
  t = mktime(p[3] " " p[2] " " p[1] " 12 0 0")
  return (strftime("%u", t + 86400) + 0) <= 5
}

BEGIN {
  FPAT = "([^,]*)|(\"[^\"]+\")"       # handles quoted fields containing commas
  CUT  = 17 * 60                     # "evening" starts at 17:00

  # Work stops (same stop can appear under two spellings)
  W["Nijmegen, Han"] = 1
  W["Nijmegen, Radboudumc"] = 1
  W["Nijmegen, Huygensgebouw"] = 1
  W["Nijmegen, Erasmusgebouw"] = 1
  W["Nijmegen, Station Heyendaal"] = 1
  W["Nijmegen, Spinozagebouw"] = 1
  W["Nijmegen, Spinozageb/tandheelk"] = 1
  W["Nijmegen Heyendaal"] = 1
}

clean($8) != "Reis" && clean($10) != "OV Fiets" { next }

{
  d = clean($1); from = clean($3); to = clean($5)
  tS = clean($2); tE = clean($4)
  c  = euro($6)

  dir = ""
  if (from == "Arnhem Centraal" && isNijTrain(to))      dir = "IN"    # to Nijmegen
  else if (to == "Arnhem Centraal" && isNijTrain(from)) dir = "OUT"   # back to Arnhem

  if (clean($10) == "OV Fiets")                      cat = "bike"
  else if (isGraaf(to))                              cat = "cond"
  else if (dir != "" || (from in W) || (to in W))    cat = "base"
  else                                               next

  n++
  L_day[n] = d; L_from[n] = from; L_to[n] = to
  L_time[n] = tS "-" tE; L_cost[n] = c; L_cat[n] = cat
  L_dir[n] = dir; L_st[n] = mins(tS)
  # bus leg touching a work stop (used to rule out OV fiets on that day)
  L_bus[n] = (clean($10) == "Bus, Tram en Metro reizen" && ((from in W) || (to in W)))

  if (!(d in dseen)) { dseen[d] = ++nd; dlist[nd] = d }
  if (dir == "OUT") hasOut[d] = 1                     # returned to Arnhem that day
}

END {
  # Pass 1: find the last evening trip back to Arnhem per day
  for (i = 1; i <= n; i++)
    if (L_dir[i] == "OUT" && L_st[i] >= CUT) lastEveOut[L_day[i]] = i

  # Pass 2: decide each leg in chronological order
  lastIn = ""
  for (i = 1; i <= n; i++) {
    if (L_cat[i] == "bike") continue                  # OV fiets: decided in pass 3
    d = L_day[i]; s = L_st[i]; c = L_cost[i]
    sx = ""; dec = 0
    roundtrip = (d in lastEveOut) && lastEveOut[d] > i   # a later evening return exists

    if (L_cat[i] == "cond") {
      if (!hasOut[d] && nextIsWorkday(d)) { sx = "conditional, declarable"; dec = c }
      else                                { sx = "conditional, not declarable" }

    } else if (L_dir[i] == "IN") {
      if (s >= CUT && roundtrip && isWeekend(d)) {
        sx = "not declarable: evening roundtrip on weekend"
      } else if (s >= CUT && roundtrip) {
        sx = "declarable: evening roundtrip on weekday"; dec = c
      } else if (s >= CUT) {
        sx = "declarable: evening trip to Nijmegen"; dec = c
      } else {
        sx = "commute"; dec = c
      }
      if (s >= CUT) inEve[d] = 1
      lastIn = d

    } else if (L_dir[i] == "OUT" && s >= CUT) {
      if (inEve[d]) {
        sx = "not declarable: evening roundtrip"
      } else if (lastIn != "" && isWeekend(lastIn)) {
        sx = "not declarable: prior trip to Nijmegen on weekend"
      } else {
        sx = "declarable: evening return to Arnhem"; dec = c
      }

    } else {
      sx = "commute"; dec = c                         # daytime legs and work bus legs
    }

    S[i] = sx; D[i] = dec
    if (L_bus[i] && dec > 0) busDeclared[d] = 1       # a work-stop bus leg was declared
    dayTot[d] += c; dayDec[d] += dec
    grandTot += c; grandDec += dec
  }

  # Pass 3: OV fiets rentals. Declarable only on a working day (Mon-Fri)
  # when no work-stop bus leg was declared that day.
  for (i = 1; i <= n; i++) {
    if (L_cat[i] != "bike") continue
    d = L_day[i]; c = L_cost[i]
    if (isWeekend(d))                  { sx = "not declarable: OV fiets on weekend"; dec = 0 }
    else if (busDeclared[d])           { sx = "not declarable: work bus declared that day"; dec = 0 }
    else                               { sx = "declarable: OV fiets, working day, no work bus"; dec = c }
    S[i] = sx; D[i] = dec
    dayTot[d] += c; dayDec[d] += dec
    grandTot += c; grandDec += dec
  }

  if (detail == 1) {
    # Full composition: one block per day, legs in order
    for (k = 1; k <= nd; k++) {
      d = dlist[k]
      printf "\n%s   total %s   declarable %s\n", d, fmt(dayTot[d]), fmt(dayDec[d])
      print "------------------------------------------------------------------------------------------"
      for (i = 1; i <= n; i++) {
        if (L_day[i] != d) continue
        printf "  %-11s %-50s %8s  [%s]\n", L_time[i], L_from[i] " → " L_to[i], fmt(L_cost[i]), S[i]
      }
    }
    printf "\n==========================================================================================\n"
    printf "GRAND TOTAL: all counted legs %s   declarable %s\n", fmt(grandTot), fmt(grandDec)
  } else {
    # Minimal table: daily sums only
    printf "%-12s %12s %12s\n", "Date", "Total", "Declarable"
    printf "%-12s %12s %12s\n", "------------", "------------", "------------"
    for (k = 1; k <= nd; k++) {
      d = dlist[k]
      printf "%-12s %12s %12s\n", d, fmt(dayTot[d]), fmt(dayDec[d])
    }
    printf "%-12s %12s %12s\n", "------------", "------------", "------------"
    printf "%-12s %12s %12s\n", "TOTAL", fmt(grandTot), fmt(grandDec)
  }
}
AWK

# The export lists days newest-first; tac puts legs in chronological order.
tail -n +2 "$FILE" | tac | gawk -v detail="$DETAIL" -f "$AWK_SRC"
