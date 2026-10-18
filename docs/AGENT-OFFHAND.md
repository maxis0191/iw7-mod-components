# Protected secondary-offhand input

The private typed agent protocol accepts `smoke`, mapped to retail `+smoke`.
Shaolin's eye scanner uses this binding; possessing its power or directly
invoking an activation callback does not establish that the equipped offhand
responds to client input.

This adds one fixed binding, with the existing PID/nonce/sequence, private
client, fresh protection, duration and release gates. It accepts no arbitrary
console command. Completion, abort and protection loss release the offhand.
All earlier binding indexes remain unchanged; requests use typed string names.

The generic Source tests cover parsing, unarmed refusal, actual dispatched
binding and release paths. An isolated build with its independent AppData,
auth mutex and profiles is required for simultaneous testing alongside an
occupied owner client. Source tests do not establish scanner gameplay.

The server owns the Shaolin quest/inventory fixture and actual acceptance in
[server PR310](https://github.com/maxis0191/iw7-paris-server/pull/310).
Paris Main and its client remain outside these private test inputs.
