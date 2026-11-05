# Code signing

`PitCrew.exe` is the only file that gets signed. It's a small launcher (`tools/launcher/PitCrew.cs`);
everything else in the zip is readable PowerShell, XAML and JSON. Without a signature, Smart App
Control on Windows 11 blocks the exe outright, and SmartScreen warns about it.

Signing is set up with [SignPath Foundation](https://signpath.org)'s free code signing for open
source projects. The certificate is issued to SignPath Foundation, so Windows shows **SignPath
Foundation** as the publisher. SignPath only signs builds made by a CI from the public source, so the
signed exe always comes from `.github/workflows/build.yml` on a GitHub-hosted runner, never from a
local build.

## How a release is signed

1. Bump `$script:PcVersion` in `src/Core/Context.ps1`, update `CHANGELOG.md`, commit and push.
2. Tag the commit with the same version and push the tag: `git tag v0.1.1-beta` and then
   `git push origin v0.1.1-beta`.
3. The workflow tests the code, builds `PitCrew.exe` and sends it to SignPath with the version.
   It waits up to an hour for approval.
4. An approver opens the signing request on signpath.io, checks that it comes from that tag, and
   approves it.
5. The workflow builds the zip around the signed exe. Before zipping, it checks that the signature is
   valid and timestamped, and that the product name is PitCrew with this version. Then it creates a
   **draft** release with the zip and its SHA-256.
6. Download the zip from the draft and try it. If it works, publish the release.

A tag pushed before signing is configured only builds the unsigned zip, as a workflow artifact.

## One-time setup

On signpath.io, after the project is accepted:

- Add the predefined **GitHub.com** trusted build system and link it to the project.
- Create an artifact configuration from [`.github/signpath/artifact-configuration.xml`](../.github/signpath/artifact-configuration.xml).
  It signs only `PitCrew.exe`, and only when its product name is PitCrew and its version is the one
  the workflow sends.
- Create a release-signing policy with manual approval. In its GitHub build policies:
  - require GitHub-hosted runners (`runners.require_github_hosted: true`);
  - turn on `disallow_reruns`, so a re-run of an old build can't be signed again.
- Create a CI user with submitter rights and an API token for it.

On GitHub (Settings > Secrets and variables > Actions):

| Kind | Name | Value |
|---|---|---|
| Secret | `SIGNPATH_API_TOKEN` | API token of the SignPath CI user |
| Variable | `SIGNPATH_ORGANIZATION_ID` | SignPath organization ID |
| Variable | `SIGNPATH_PROJECT_SLUG` | Project slug |
| Variable | `SIGNPATH_POLICY_SLUG` | Signing policy slug |
| Variable | `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` | Artifact configuration slug |

Signing turns on once `SIGNPATH_ORGANIZATION_ID` exists. Every team member uses two-factor
authentication on GitHub and SignPath, as SignPath Foundation requires.

The rule "only version tags get signed" lives in the workflow, and anyone with write access could
change the workflow. Two safeguards back it up:

- Add a tag ruleset on GitHub (Settings > Rules) so only the maintainer can create, move or delete
  `v*` tags.
- Approve each signing request on signpath.io only after checking that it comes from the expected
  tag and commit.
