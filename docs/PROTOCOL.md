# Wire protocol

Three streams, and one of them is the only thing a policy has to understand.

## 1. The player socket (Sprite v1)

`GET /player?slot=N&token=T` upgrades to a websocket carrying the starter's
Sprite v1 binary protocol. The game sends one binary frame per tick; the seat
sends:

* **ONE chat message (`0x81`) carrying its registration**, re-sent for the first
  ~10 s of frames:

  ```json
  {"type": "register",
   "llm": true | false,
   "prompt": "<strategy text, or empty>",
   "scripted": "focusfire" | "charge" | null,
   "policy": "<free label>"}
  ```

  Joins are strictly slot-sequential, so a seat whose slot is not the next open
  one is not admitted until the lower slots have joined. The server HOLDS an
  unappliable registration and re-reads it when the slot lands, and this end
  keeps re-sending it — registering twice is harmless. Model seats declare
  `COWORLD_LLM_ENABLED=true` (and/or `PLAYER_PROMPT`) with `scripted: null`;
  scripted seats declare `PLAYER_SCRIPTED=focusfire` or `charge`.

  The prompt is a secret: the server consumes the registration and writes a
  REDACTED `register` record to the replay carrying the policy label and kind
  only. Any other chat text from a seat is dropped — units shout, seats do not.

* **The Ready packet (`0x85`) after every received frame.** This is legitimate
  here in a way it is not for an ordinary Sprite v1 client: the seat sends NO
  inputs at all (the server computes every actuator mask), so the dead-reckoning
  hazard the packet normally causes on a wall-clock-paced server cannot arise,
  and `fastMode` can advance the tick as soon as every seat has acknowledged the
  frame.

**A seat sends no inputs.** Every decision reaches the sim as a directive
(below), compiled by a deterministic server-side control layer.

Exit cleanly on a dead socket: the receive loop must be wrapped in
`try/except`, because a close frame RAISES, and the game's own `quit(0)` can
outrun the flushed final frame. A naive player exits 1 and fails certification
intermittently.

## 2. The directive channel (what a policy actually speaks)

Every `turnTicks` = 120 ticks (5.0 s) the GAME SERVER — not the player
container — builds each seat's view, asks that seat's policy for one order, and
compiles the answer into per-tick actuator masks for the next five seconds. All
five seats are asked as ONE parallel batch.

### The view the seat is given

Map pixels, integers. Abridged; the full object is built by
`src/smac/decide.nim`.

```json
{"battle": 2, "of": 3, "scenario": "default",
 "turn": 5, "turns": 12, "clock": {"played_s": 25, "left_s": 35},
 "you": {"id": "RANGER-alpha", "role": "ranger", "alive": true,
         "pos": [412, 330], "aim": 128, "hp": 44, "hp_max": 60,
         "range_px": 380, "cooldown_ticks": 7, "ready": false,
         "damage_dealt": 96, "kills": 1, "speed_px_s": 66},
 "armies": {"ours": {"alive": 4, "hp": 301, "hp_max": 480, "hp_pct": 63},
            "theirs": {"alive": 3, "hp": 214, "hp_max": 480, "hp_pct": 45}},
 "enemies": [{"id": 3, "name": "E3", "role": "blade", "pos": [640, 302],
              "hp": 34, "hp_max": 120, "dist_px": 229, "in_your_range": true,
              "attacking": "RANGER-alpha", "focused_by": 2,
              "reach_px": 56, "speed_px_s": 76}],
 "squad": [{"id": "BLADE-alpha", "role": "blade", "pos": [600, 420],
            "alive": true, "hp": 88, "hp_max": 120, "damage_dealt": 140,
            "attacking": "E3", "last_intent": "focus",
            "last_note": "I body-block for the rangers", "last_say": "screen"}],
 "last_turn": {"your_damage": 24, "your_shots": 6, "team_damage": 88,
               "enemy_kills": 1, "our_losses": 0},
 "your_last_directive": "...",
 "score": {"team_so_far": 0.31, "battles_won": 0, "battle_damage_pct": 55,
           "battle_loss_pct": 37, "win_weight": 0.6, "dmg_weight": 0.3,
           "surv_weight": 0.1}}
```

`enemies` is sorted nearest-to-you first and capped at 24 entries.

**Visible:** the whole board. Every living unit on both sides with its position,
aim, role, current and maximum hit points; every enemy's current target and how
many of ours are already attacking it; both armies' totals; the other four
seats' LAST-turn note, say and intent; shouts within 247 px; the battle index,
the scenario, the clock, the running team score and the scoring weights.

**Hidden:** the other seats' directives FOR THE TURN BEING DECIDED (all five
decide simultaneously — that is exactly why `say` and `note` matter); every
seat's `PLAYER_PROMPT`; the identity of any policy; the episode seed; the RNG
state and therefore every future spawn and every future shot's aim jitter; the
enemy AI's internal retarget, leash and stuck counters; and future ticks.

### The reply

```json
{"note": "everyone on E3, blades screen the rangers",
 "cogs": [{"id": "RANGER-alpha", "intent": "focus", "target_id": 3,
           "target": [640, 302], "face": [700, 300], "say": "E3"}]}
```

| field | cap / legal values | handling when violated |
|---|---|---|
| `note` | <= 160 runes | truncated on a rune boundary; newlines collapse to spaces |
| `cogs` | JSON array with exactly 1 entry — your own unit | rejected (`DirectiveError`) |
| `cogs[].id` | your exact unit alias (e.g. `RANGER-alpha`) | rejected (`DirectiveError`) |
| `cogs[].intent` | `focus` `attack_move` `kite` `hold` `screen` `retreat` `regroup` | rejected (`DirectiveError`) |
| `cogs[].target_id` | integer enemy id or `null` | non-integer/non-null rejected (`DirectiveError`) |
| `cogs[].target` | `[x, y]` or `null` (clamped to the map box) | malformed value rejected (`DirectiveError`) |
| `cogs[].face` | `[x, y]` or `null` | malformed value rejected (`DirectiveError`) |
| `cogs[].say` | <= 10 runes | truncated on a rune boundary, then printable ASCII minus braces; becomes a real in-game SHOUT audible within 247 px |

Parsing is STRICT: replies must be a single JSON object starting with `{`
matching the schema above. Invalid JSON, wrong types, unknown intents, wrong
unit ids, or missing/extra `cogs` entries are rejected rather than silently
repaired or replaced with a scripted move.

**Truncation is on RUNE (Unicode codepoint) boundaries, never bytes.** Slicing a
string by byte index anywhere on the path to the replay is forbidden: a
byte-truncated multi-byte character renders fine in a browser and then fails a
strict UTF-8 parser.

### Timing, and fail-closed policy errors

Attempt 1 gets a **6000 ms** batch deadline. Any LLM seat that timed out,
errored, returned invalid JSON, or returned an invalid directive is retried
**once** in a single batch with a **3000 ms** deadline — worst case 9.0 s inside
the **10000 ms** per-turn cap. A provider throttle (HTTP 429) skips the retry
outright.

If an LLM seat still has no valid directive (due to `timeout`, `parse_error`,
`transport_error`, `throttled`, `no_credentials`, or `budget_guard`), the
engine does **not** fabricate a substitute move (`hold`, `focusfire`, or last
turn's directive). It preserves the failed attempt evidence, writes a terminal
policy failure to `COGAME_PLAYER_FAILURE_URI`, and terminates the episode
without publishing `results.json` scores.

A **12000 ms** wall-clock floor separates the STARTS of consecutive batches,
which holds the episode at 25 requests/minute. It is a floor, not a sleep on the
critical path — the loop keeps stepping sim ticks while it waits.

## 3. The spectator streams

* `GET /global` and `GET /client/global` — the broadcast board and its JSON
  chrome frame (scorebug, army bars, feed, transport, endcard).
* `GET /client/player?slot=N&token=T` — a real page, registered before any
  catch-all route, that does NOT open the player socket.
* `GET /healthz`, `GET /replay-data`, `GET /reward` — as inherited.

Both `/client/` routes serve real pages and `/healthz` + `/global` keep
answering for a bounded shutdown grace (~20 s) after the artifacts are written.

## 4. The replay

A binary `COWLDSMC` file: magic + format version + game name/version header,
the resolved config JSON (seed, `mapSpec`, roster, `roles`, `enemyRoles` and
every tuning field), then the record stream — joins, leaves, per-UNIT input-mask
changes for the five friendly units, chat records, and **one `gameHash` per
tick**.

| `k` | fields |
|---|---|
| `register` | `seat`, `alias`, `role`, `policy` (<= 48 runes), `kind`, `baseline` |
| `directive` | `battle`, `turn`, `seat`, `alias`, `role`, `source`, `latency_ms`, `note`, `cogs[]` |
| `fallback` | `battle`, `turn`, `seat`, `attempt`, `cause`, `detail` (<= 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `stop` | `tick`, `reason`, `endRule` — the load-bearing wall-clock stop, applied by the SAME proc on record and on playback |
| `result` | the full results document, written once at episode end |

The whole serialized `directive` record is capped at 900 runes.

**The entire enemy army is re-derived, never recorded**: its spawn positions come
from the sim RNG seeded by the config seed, and every one of its decisions is a
pure integer function of the sim state. That is why the file stays around 330 KB
and why a hash mismatch is a real integrity signal rather than a rendering nit.

`tools/replay_summary.py` (Python 3 standard library only) turns the bytes into
one strict-UTF-8 JSON object on stdout for forensics.

## 5. The results document

Written to `COGAME_RESULTS_URI`. It must equal the manifest's `results_schema`
key for key — that schema is `additionalProperties: false` and the certifier
rejects any unknown field. See `docs/RULES.md` for what the numbers mean.

The twelve seat-indexed arrays (`names`, `scores`, `win`, `role`, `alias`,
`damageDealt`, `damageTaken`, `kills`, `deaths`, `shots`, `llmTurns`,
`fallbackTurns`) have exactly five entries. The four battle-indexed arrays
(`battleResults`, `battleTicks`, `battleDamagePct`, `battleLossPct`) have
between one and six.

`names` are the REAL policy names (spectator side). `alias` and `role` carry the
in-game names, which are the only names a seat, a prompt or a shout ever sees.
