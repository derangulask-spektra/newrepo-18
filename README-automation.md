# LAB511 — Build-Time Automation of Exercise 01

## Why this wasn't already automated

The client's Skillable implementation runs lifecycle blocks **"Execute Script in Cloud Platform"** against a lab service principal (`@lab.CloudSubscription.AppId` / `AppSecret`), in named stages (Pre-Build, First Displayable, Tearing Down). CloudLabs has no equivalent stage engine — it has exactly two build-time hooks:

1. the **ARM template**, and
2. **one CustomScriptExtension** on the lab VM.

So nothing here is a Spektra limitation. Every one of the client's seven scripts maps onto those two hooks; the work is re-homing them.

| Skillable script | New home on CloudLabs |
|---|---|
| `1_register_providers.ps1` | Not needed — providers are registered on the CloudLabs shared subscription (Sumit to confirm `Microsoft.HorizonDb` is registered). |
| `3_bicep_deployment.ps1` (deploy.bicep) | Merged **into the ARM template** as native resources. No bicep compile, no ARM REST wrapper, no deployment polling — ARM does all of it. |
| `2_clone_repo.ps1` | Already handled: the CSE downloads and extracts the lab ZIP to `C:\Lab`. |
| `5_set_firewall_rules.ps1` | `configure-horizondb.ps1` (runs on the VM). |
| `5b_set_parameter_group.ps1` | Split: the parameter group **content** is declared in ARM; the **attach + InSync poll** is in `configure-horizondb.ps1`. |
| `4_build_env.ps1` / `postprovision.ps1` / `postprovision.sh` | `psscript.ps1` writes `C:\Lab\.env` directly from ARM-injected values — no deployment-output lookup needed. |
| `6_deployment_validation.ps1` | Replaced by CloudLabs' own deployment status plus the existing lab-guide validation steps. |
| `7_purge_ai_resources.ps1` | Not needed — CloudLabs deletes the whole resource group at teardown. |

## What changed

**`deploy.json` (ARM template)**
- Added `Microsoft.CognitiveServices/accounts` (kind `AIServices`, `allowProjectManagement: true`) named `openai-lab-<DeploymentID>`, plus a default project `project-<DeploymentID>` — same names the lab guide already used, so guide edits stay minimal.
- Added both model deployments, chained with `dependsOn` because model deployments on one account must be created serially.
- Added `Microsoft.HorizonDb/clusters` named `horizondb-lab-<DeploymentID>` and `Microsoft.HorizonDb/parameterGroups` named `lab`.
- The CSE now `dependsOn` the cluster, the parameter group and the gpt-5 deployment, so it cannot run before its inputs exist.
- New outputs for injection into the guide: Foundry resource/project name, OpenAI endpoint and key, cluster name, HorizonDB username and password, and **`LabVM Public IP`** — read via `reference()` on the VM's public IP resource (`Standard` SKU, static allocation), not guessed or looked up at runtime.
- The CSE's `commandToExecute` now also passes `-labVmPublicIp` straight from that same `reference()` call, so the VM-side script never has to rediscover its own IP.
- New pinnable parameters: `aiLocation`, `horizonDbLocation`, `gptCapacity`, `embeddingCapacity`.

**`psscript.ps1`**
- Accepts the lab values from ARM, calls `configure-horizondb.ps1`, then writes a **fully populated** `C:\Lab\.env`, with a sanity check that logs a warning if any critical value came through empty.
- Hardened the pip install (skip-if-missing, retry, `pip freeze` to `C:\Logs\pip-freeze.txt`) and registers a `lab511` Jupyter kernel so the notebooks open ready to run.

**`configure-horizondb.ps1` (new)**
- Signs in with the ODL user, waits for the cluster, **resolves the real FQDN from the resource instead of guessing it**, attaches the parameter group with retries, polls to `InSync`, and creates the firewall rules.
- Firewall rules are now just **`AllowAzureServices`** (Azure-internal control plane, `0.0.0.0/0.0.0.0`) and **`AllowLabVM`**, scoped to the exact IP passed down from the ARM output `LabVM Public IP`. The old `AllowAll` (`0.0.0.0`–`255.255.255.255`) catch-all from the client's script is gone — it existed only because the earlier runtime IP lookup wasn't trustworthy enough to rely on alone. Now that the IP comes straight from the resource ARM created, `AllowLabVM` is the sole access-granting rule, and the script fails loudly (throws) if it can't resolve an IP, rather than silently falling back to opening the cluster to the internet.
- Writes `C:\LabFiles\horizondb-config.json` so `psscript.ps1` uses the authoritative host in `.env`.

## Three bugs in the supplied scripts you should know about

1. **`pg_fts` does not exist.** `5b_set_parameter_group.ps1` and `test_set_parameter_group.ps1` allow-list `pg_fts`. The real BM25 extension is **`pg_textsearch`**, and it also has to be in `shared_preload_libraries` — the client's script only preloads `age`. Both are fixed in the new template. As shipped, the client's script would have produced a cluster where every BM25 exercise fails.
2. **Model capacity is 33× too high.** `deploy.bicep` sets `sku.capacity: 1000` on both deployments. That unit is thousands of TPM, so it requests **1,000,000 TPM per attendee**. On a shared subscription that exhausts quota after a couple of ODLs. The template now uses 30 and 120, matching the lab guide's stated 30,000 and 120,000 TPM.
3. **`listKeys()` / `reference()` cannot be used in the `variables` section.** The OpenAI key is therefore built inline inside `protectedSettings.commandToExecute`, not in a variable. (Same class of bug we hit on the earlier ARM iteration.)

Also worth noting: the PG admin password is now generated as `Pg<uniqueString>Lab26` — alphanumeric only. This is deliberate. A password containing `@` breaks the psycopg connection string unless URL-encoded, which is exactly the bug we chased down earlier in this lab.

## Rollout steps

1. Upload `psscript.ps1` and `configure-horizondb.ps1` to
   `https://experienceazure.blob.core.windows.net/templates/Building-an-Agentic-Legal-Research-Application/scripts/`
   (the template's `fileUris` already points there — the new file must be added to that container or the CSE will 404).
2. Publish `deploy.json` as the LAB511 ARM template.
3. Pin the regions before the first build. Set `horizonDbLocation` to a region where **Azure HorizonDB preview and `pg_textsearch` are both available** — West US 2 is confirmed working; East US is not. Set `aiLocation` to a region with gpt-5 GlobalStandard quota.
4. Ask Sumit to confirm `Microsoft.HorizonDb` and `Microsoft.CognitiveServices` are registered on the shared subscription, and to confirm the ODL user can sign in via username/password (the VM script uses ROPC; if MFA is enforced we switch to a VM managed identity with Contributor on the RG).
5. Replace `exercise-01.md` with the rewritten version and delete the now-unused screenshots for the creation flows.
6. Add the new inject keys to the lab profile: `HorizonDB Username`, `HorizonDB Password`, and optionally `Azure OpenAI Endpoint`.
7. Ask Sai Sindhuja to re-run checkpoint testing against the four Exercise 01 validation functions. They now validate pre-existing resources, so all four should pass on first click — the useful signal is that they fail loudly if the build partially failed.

## Timing impact

Exercise 01 drops from **60 minutes to about 15**. Build time goes up by roughly 20–25 minutes, since the CSE now waits on the HorizonDB cluster (15–20 min) plus the parameter group sync (3–5 min). Recommend raising the CloudLabs deployment timeout to 90 minutes and keeping ODLs pre-provisioned ahead of delivery.

## Open risks to flag to the client

- **HorizonDB is preview.** It is now a hard dependency of environment provisioning: if the provider throttles or a region runs out of capacity, the environment fails to build rather than the attendee hitting an error mid-lab. That is the right trade-off, but it makes region pinning and pre-provisioning non-negotiable.
- **`AllowLabVM` is now a hard dependency.** Since `AllowAll` is gone, if the ARM output `LabVM Public IP` is ever empty or malformed, `configure-horizondb.ps1` throws rather than quietly leaving the cluster unreachable (or, as the old script did, wide open). That's the intended trade-off, but it means a NIC/public-IP change on Azure's side between VM creation and CSE execution would surface as a build failure — worth watching for in the first few deliveries.
- **API version `2026-01-20-preview`** is used for both the cluster and the parameter group. Preview API versions get retired; this needs a re-test before each delivery.
- **The parameter group attach is still imperative.** If a future API version supports setting `properties.parameterGroup` at cluster create time, that block can move into the ARM template and `configure-horizondb.ps1` shrinks to just the firewall rules.
