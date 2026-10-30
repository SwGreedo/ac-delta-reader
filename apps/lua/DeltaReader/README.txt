Delta Reader - live delta overlay (CSP Lua app)

Install: drag DeltaReader.zip onto Content Manager and click Install
(or copy apps/lua/DeltaReader into <Assetto Corsa>/apps/lua/).
Needs Custom Shaders Patch. Enable it in game from the right-hand app bar.

Use:
- Drive a clean lap. From then on the gauge shows your live delta.
- Click the gauge to cycle the reference: session best / session optimal / personal best / a saved lap.
- The small number under the delta is the second reference (optimal, or best when optimal is the main one).
- Predicted lap: purple = beating your PB, green = up on the reference, red = down.
- Resize the window by dragging its corner; everything scales.
- Settings (cog on the app bar): arc range, smoothing, track-limit rule, all-time optimal, pick any saved lap.

Data: Documents/Assetto Corsa/DeltaReader/<car>@<track>/
  pb.txt and the last 30 valid laps (lap_1..lap_30.txt).
Laps that start from the pits, cut the track (3+ wheels off), go backwards or teleport are not saved.
