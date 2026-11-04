# Security

PitCrew runs as administrator and changes system settings, so security reports are taken
seriously.

## Reporting a problem

Please don't open a public issue for a vulnerability. Use GitHub's private reporting instead: on
[github.com/jothank/pitcrew](https://github.com/jothank/pitcrew), open the **Security** tab and
choose **Report a vulnerability**.

Include what you did, what happened, the PitCrew version (shown on the About page) and, if you
can, the log from `C:\ProgramData\PitCrew\logs`.

## In scope

- Anything that lets a standard user, or a file in a place standard users can write to, make
  PitCrew change, delete or run something it shouldn't while it runs as administrator.
- Undo restoring a wrong value, or touching something PitCrew didn't change.
- `PitCrew.exe` starting anything other than `PitCrew.ps1` next to it.
- Cleanup deleting anything outside the folders it lists.

## Known limits

- PitCrew runs from the folder you extracted it to. Anything that can already write to that
  folder as you can also change what runs as administrator, as with any portable tool. Keep it in
  a folder only you use.
- Releases aren't digitally signed yet. Compare the zip with the SHA-256 published next to it.
