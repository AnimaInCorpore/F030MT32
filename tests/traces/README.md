# Conformance fixtures

Tracked MIDI byte streams that both the Munt oracle and the Falcon replay, so
a disagreement is a diff rather than an opinion. The format is described in
[`../../docs/midi-ground-truth.md`](../../docs/midi-ground-truth.md#fixture-format):
a comment header, then one event per line as a native 32,000 Hz sample
timestamp followed by MIDI bytes in hex.

Only `tone_probe.trace` exists so far, and nothing consumes it yet — there is
no oracle harness. It is here so the format is fixed before the first real
fixture is written, and so that whoever builds the harness has something to
point it at.

A fixture should isolate one behaviour and say which in its header, the way
F030MXDRV's traces do: one for each envelope stage, one per structure, one per
reverb mode, one for the SysEx timing behaviour, and so on. A fixture that
exercises five things at once cannot bisect a disagreement.
