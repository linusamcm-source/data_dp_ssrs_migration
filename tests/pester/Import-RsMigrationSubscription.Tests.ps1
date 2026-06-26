#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force

    # Source artefact PS5 adds. AC5's "no plaintext credential" half is a static
    # source contract: REST auth must flow ONLY through the WebSession opened by
    # New-RsMigrationRestSession, so the cmdlet may not wire an explicit
    # -Credential. A removed/absent symbol cannot be mocked for Should -Invoke,
    # so this can only be proven by grepping the source (exactly as PS4 proved its
    # integrated-auth contract).
    $script:SubscriptionSource = Join-Path $script:ModuleRoot 'Public' 'Import-RsMigrationSubscription.ps1'
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# CONTRACT THIS SUITE PINS (stated for the GREEN engineer)
#
# Import-RsMigrationSubscription recreates CATALOG subscriptions from a SOURCE
# portal onto a TARGET portal over the PBIRS REST v2.0 API. The RST subscription
# cmdlets (Get-/New-/Set-RsSubscription) are SOAP-only -- they take
# -ReportServerUri/-Proxy and have NO -WebSession parameter -- so they cannot
# consume the integrated-auth REST session AC5 mandates. There is no REST
# subscription cmdlet in ReportingServicesTools (Get-Command *Rest*Subscription*
# returns nothing). The only contract that routes through the helper's WebSession
# is therefore direct REST via Invoke-RestMethod -WebSession:
#
#   * ENUMERATE : Invoke-RestMethod -Method Get  -Uri "<portal>/api/v2.0/Subscriptions"
#                 -WebSession <session>   -> returns an OData envelope whose
#                 .value property is the array of subscription objects.
#   * CREATE    : Invoke-RestMethod -Method Post -Uri "<target>/api/v2.0/Subscriptions"
#                 -WebSession <targetSession> -Body <json> -ContentType application/json
#   * UPDATE    : Invoke-RestMethod -Method Put  -Uri "<target>/api/v2.0/Subscriptions(<Id>)"
#                 -WebSession <targetSession> -Body <json>   (addressed by the
#                 TARGET subscription's server-assigned Id).
#
# Every Invoke-RestMethod call passes an explicit -Method and a -WebSession; the
# session objects come solely from New-RsMigrationRestSession (one per portal).
#
# IDEMPOTENCY MATCH KEY: a source subscription is "already present" on the target
# when an existing target subscription shares the tuple
#   (Owner, Path, Description, EventType)
# -- NOT Id, which the server assigns and therefore differs after a recreate.
# A content-match is UPDATED in place (PUT to the target Id); a non-match is
# CREATED (POST).
#
# -IncludeSubscription allow-list: filters source subscriptions by Description
# (the operator-facing name). Non-empty => only those Descriptions; empty/omitted
# => all. A name matching no source Description is reported, not fatal.
#
# RETURN VALUE: a summary [pscustomobject] carrying at least UnmatchedInclude
# ([string[]] -- the include names that matched nothing; empty when all matched).
# -----------------------------------------------------------------------------

Describe 'Import-RsMigrationSubscription parameter contract' {

    # AC1: the public surface the orchestrator drives.
    It 'exposes -SourceReportPortalUri, -TargetReportPortalUri and -IncludeSubscription' {
        $keys = (Get-Command Import-RsMigrationSubscription).Parameters.Keys
        $keys | Should -Contain 'SourceReportPortalUri'
        $keys | Should -Contain 'TargetReportPortalUri'
        $keys | Should -Contain 'IncludeSubscription'
    }

    # AC1: the allow-list is a string array.
    It 'types -IncludeSubscription as [string[]]' {
        (Get-Command Import-RsMigrationSubscription).Parameters['IncludeSubscription'].ParameterType |
            Should -Be ([string[]])
    }

    # AC1: SupportsShouldProcess -- the cmdlet writes to the target, so it must be
    # gated by -WhatIf/-Confirm (SupportsShouldProcess auto-adds -WhatIf).
    It 'supports ShouldProcess (exposes -WhatIf)' {
        (Get-Command Import-RsMigrationSubscription).Parameters.Keys | Should -Contain 'WhatIf'
    }
}

Describe 'Import-RsMigrationSubscription' {

    # ---- AC2: import everything when no allow-list is given -------------------
    Context 'AC2 imports every source subscription when no include filter is given' {

        It 'creates all three source subscriptions on the target' {
            InModuleScope RsMigration {
                $sourceSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                $targetSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession {
                    if ($ReportPortalUri -eq 'https://source/reports') { $sourceSession } else { $targetSession }
                }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                $subCharlie = [pscustomobject]@{ Id = 's-charlie'; Owner = 'o3'; Path = '/reports/charlie'; Description = 'Charlie'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo, $subCharlie) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                $result = Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                # The target is empty, so all three are CREATED (POST); none updated.
                Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $Method -eq 'Post' }
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Put' }

                # No include filter -> nothing unmatched.
                @($result.UnmatchedInclude).Count | Should -Be 0
            }
        }

        It 'treats an empty -IncludeSubscription the same as omitted (imports all)' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports' `
                    -IncludeSubscription @()

                Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'Post' }
            }
        }
    }

    # ---- AC3: the allow-list selects exactly the named subscriptions ----------
    Context 'AC3 honours the -IncludeSubscription allow-list' {

        It 'imports only the named subscription and skips the rest' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                $subCharlie = [pscustomobject]@{ Id = 's-charlie'; Owner = 'o3'; Path = '/reports/charlie'; Description = 'Charlie'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo, $subCharlie) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports' `
                    -IncludeSubscription @('Alpha')

                # Exactly one create, and it is Alpha (its serialized body names it).
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' }
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and "$Body" -match '"Description"\s*:\s*"Alpha"' }

                # Bravo and Charlie are never created. Match the Description token
                # specifically -- a loose 'Bravo' would also match Path tokens.
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' -and "$Body" -match '"Description"\s*:\s*"Bravo"' }
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' -and "$Body" -match '"Description"\s*:\s*"Charlie"' }
            }
        }
    }

    # ---- AC4: idempotent refresh -- update an existing content-match ----------
    Context 'AC4 is idempotent: an existing content-match is updated, not duplicated' {

        It 'updates the matching target subscription in place and creates only the new ones' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                $subCharlie = [pscustomobject]@{ Id = 's-charlie'; Owner = 'o3'; Path = '/reports/charlie'; Description = 'Charlie'; EventType = 'TimedSubscription' }

                # The target already holds a content-match for Alpha: SAME
                # (Owner, Path, Description, EventType) but a DIFFERENT, server-
                # assigned Id. Matching on that tuple (and NOT on Id) is what makes
                # the re-run an update rather than a duplicate create.
                $existingAlpha = [pscustomobject]@{ Id = 't-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo, $subCharlie) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($existingAlpha) }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                # Alpha is UPDATED in place (PUT) addressed by the TARGET's Id...
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Put' -and "$Uri" -like '*t-alpha*' }
                # ...and is NOT recreated.
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' -and "$Body" -match '"Description"\s*:\s*"Alpha"' }
                # Only the two genuinely-new subscriptions are created.
                Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'Post' }
            }
        }
    }

    # ---- AC5: every REST hop is opened by New-RsMigrationRestSession ----------
    Context 'AC5 routes all REST access through New-RsMigrationRestSession' {

        It 'opens a session for both portals and threads each into Invoke-RestMethod' {
            InModuleScope RsMigration {
                # Distinct sentinel sessions so the threading can be proven by identity.
                $sourceSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                $targetSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession {
                    if ($ReportPortalUri -eq 'https://source/reports') { $sourceSession } else { $targetSession }
                }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                # A REST session is opened for BOTH the source and the target portal.
                Should -Invoke New-RsMigrationRestSession -ParameterFilter { $ReportPortalUri -eq 'https://source/reports' }
                Should -Invoke New-RsMigrationRestSession -ParameterFilter { $ReportPortalUri -eq 'https://target/reports' }

                # The source enumerate uses the source session; the target write uses
                # the target session -- the helper's output is what authenticates REST.
                Should -Invoke Invoke-RestMethod -ParameterFilter { "$Uri" -like '*source*' -and $WebSession -eq $sourceSession }
                Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $WebSession -eq $targetSession }
            }
        }
    }

    # ---- AC6: an unmatched include name is surfaced, not fatal ----------------
    Context 'AC6 surfaces an unmatched include name without throwing' {

        It 'warns and reports the unmatched name while still importing the matched ones' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
                Mock Write-Warning { }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                # Captured via $script: so the value survives the child scope the
                # Should -Not -Throw block runs in (a plain local would not leak out).
                $script:ac6Result = $null
                {
                    $script:ac6Result = Import-RsMigrationSubscription `
                        -SourceReportPortalUri 'https://source/reports' `
                        -TargetReportPortalUri 'https://target/reports' `
                        -IncludeSubscription @('Alpha', 'Zeta')
                } | Should -Not -Throw

                # A non-terminating warning fired naming the unmatched include.
                Should -Invoke Write-Warning -ParameterFilter { "$Message" -like '*Zeta*' }

                # The unmatched name is surfaced on the returned summary object.
                $script:ac6Result.UnmatchedInclude | Should -Contain 'Zeta'

                # ...and the matched include was still imported.
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and "$Body" -match '"Description"\s*:\s*"Alpha"' }
            }
        }

        It 'returns an empty UnmatchedInclude when every include matches a source subscription' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                $result = Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports' `
                    -IncludeSubscription @('Alpha', 'Bravo')

                @($result.UnmatchedInclude).Count | Should -Be 0
            }
        }
    }

    # ---- PS5-#1: the REST body is a clean payload (no source / server Id) -----
    Context 'PS5-#1 sends a clean payload that strips the source / server-managed Id' {

        It 'PUTs the TARGET id in the body (never the source id) and POSTs no id at all' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                # Carry an extra server-managed field (Status) to prove it is stripped.
                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription'; Status = 'Active' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                # Target already holds Alpha under a DIFFERENT (server-assigned) id.
                $existingAlpha = [pscustomobject]@{ Id = 't-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($existingAlpha) }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                # PUT body's Id is the TARGET id, parsed precisely from the JSON...
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'Put' -and ($Body | ConvertFrom-Json).Id -eq 't-alpha'
                }
                # ...and never the SOURCE id.
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
                    $Method -eq 'Put' -and ($Body | ConvertFrom-Json).Id -eq 's-alpha'
                }
                # The server-managed Status field is stripped from the PUT body.
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
                    $Method -eq 'Put' -and ($Body | ConvertFrom-Json).PSObject.Properties['Status']
                }
                # POST body carries no Id whatsoever (the server assigns it).
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'Post' -and -not ($Body | ConvertFrom-Json).PSObject.Properties['Id']
                }
            }
        }
    }

    # ---- PS5-#2: a non-unique target match key is surfaced, not silent --------
    Context 'PS5-#2 warns when two target subscriptions collide on the match key' {

        It 'emits a non-terminating warning naming the colliding key' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
                Mock Write-Warning { }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                # Two TARGET subs share (Owner, Path, Description, EventType) but
                # carry different server-assigned ids -- the match key cannot tell
                # them apart, so one will overwrite the other.
                $dup1 = [pscustomobject]@{ Id = 't-1'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $dup2 = [pscustomobject]@{ Id = 't-2'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($dup1, $dup2) }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                Should -Invoke Write-Warning -ParameterFilter { "$Message" -like '*collide*' }
            }
        }
    }

    # ---- PS5-#3: only the summary object is returned --------------------------
    Context 'PS5-#3 returns only the summary; REST responses do not leak' {

        It 'returns exactly one object (the summary) even when the server echoes the write' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                $existingAlpha = [pscustomobject]@{ Id = 't-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($existingAlpha) }
                }
                # The real PBIRS API echoes the written subscription on both verbs;
                # those responses must NOT reach the pipeline.
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } { [pscustomobject]@{ Id = 't-new'; Echoed = 'post' } }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Put' } { [pscustomobject]@{ Id = 't-alpha'; Echoed = 'put' } }

                $r = Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports'

                ($r | Measure-Object).Count | Should -Be 1
                $r.PSObject.Properties.Name | Should -Contain 'Created'
                $r.PSObject.Properties.Name | Should -Contain 'Updated'
                $r.PSObject.Properties.Name | Should -Contain 'UnmatchedInclude'
                $r.Created | Should -Be 1
                $r.Updated | Should -Be 1
            }
        }
    }

    # ---- PS5-#4: match-key reads are tolerant under StrictMode ----------------
    Context 'PS5-#4 tolerates a missing match-key property under StrictMode' {

        It 'does not throw when source/target objects are missing a key field' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                # Source sub MISSING 'Path'; target sub MISSING 'EventType'. A naive
                # $sub.Path read hard-throws under the module-wide Set-StrictMode.
                $subNoPath = [pscustomobject]@{ Id = 's-x'; Owner = 'o1'; Description = 'Xray'; EventType = 'TimedSubscription' }
                $targetNoEvent = [pscustomobject]@{ Id = 't-y'; Owner = 'o9'; Path = '/reports/yankee'; Description = 'Yankee' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subNoPath) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($targetNoEvent) }
                }

                { Import-RsMigrationSubscription `
                        -SourceReportPortalUri 'https://source/reports' `
                        -TargetReportPortalUri 'https://target/reports' } | Should -Not -Throw
            }
        }
    }

    # ---- PS5-#5: WhatIf is read-only; include names dedup case-insensitively --
    Context 'PS5-#5 WhatIf makes no writes and duplicate include names collapse' {

        It 'makes zero POST/PUT calls under -WhatIf' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }
                $subBravo = [pscustomobject]@{ Id = 's-bravo'; Owner = 'o2'; Path = '/reports/bravo'; Description = 'Bravo'; EventType = 'TimedSubscription' }
                $existingAlpha = [pscustomobject]@{ Id = 't-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha, $subBravo) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @($existingAlpha) }
                }

                Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports' -WhatIf

                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Put' }
            }
        }

        It 'collapses case-variant duplicate include names to one warning and one unmatched entry' {
            InModuleScope RsMigration {
                Mock New-RsMigrationRestSession { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
                Mock Write-Warning { }

                $subAlpha = [pscustomobject]@{ Id = 's-alpha'; Owner = 'o1'; Path = '/reports/alpha'; Description = 'Alpha'; EventType = 'TimedSubscription' }

                Mock Invoke-RestMethod { }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*source*' } {
                    [pscustomobject]@{ value = @($subAlpha) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and "$Uri" -like '*target*' } {
                    [pscustomobject]@{ value = @() }
                }

                $result = Import-RsMigrationSubscription `
                    -SourceReportPortalUri 'https://source/reports' `
                    -TargetReportPortalUri 'https://target/reports' `
                    -IncludeSubscription @('Zeta', 'zeta')

                # 'Zeta' and 'zeta' are the same name -> one unmatched entry...
                @($result.UnmatchedInclude).Count | Should -Be 1
                # ...and the unmatched warning fires exactly once.
                Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { "$Message" -like '*matched no source*' }
            }
        }
    }
}

Describe 'Import-RsMigrationSubscription REST auth (source contract)' {

    # AC5 (static half): REST auth must flow ONLY through the WebSession opened by
    # New-RsMigrationRestSession. The cmdlet therefore wires no explicit
    # credential -- no -Credential parameter is forwarded to the REST calls, and
    # no plaintext credential is constructed. The file must exist for the
    # integrated-auth contract to hold.
    It 'wires no plaintext credential -- REST auth flows only through the WebSession' {
        Test-Path $script:SubscriptionSource | Should -BeTrue -Because 'Import-RsMigrationSubscription.ps1 must exist for the REST-auth contract'
        if (Test-Path $script:SubscriptionSource) {
            $content = Get-Content -LiteralPath $script:SubscriptionSource -Raw
            $content | Should -Not -Match '-Credential'
            $content | Should -Not -Match 'ConvertTo-SecureString'
        }
    }
}
