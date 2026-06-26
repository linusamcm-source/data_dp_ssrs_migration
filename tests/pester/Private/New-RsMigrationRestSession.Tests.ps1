#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'New-RsMigrationRestSession (Private helper)' {

    # The helper wraps ReportingServicesTools' New-RsRestSession. "Current Windows
    # identity" is expressed simply by NOT supplying a credential: New-RsRestSession
    # defaults to the calling Windows user when no -Credential is passed (the cmdlet
    # has no username/password parameters at all). The object it returns is the REST
    # WebSession that the render / data-source seams thread into the underlying RS
    # cmdlets via -WebSession, so the session is typed
    # [Microsoft.PowerShell.Commands.WebRequestSession] throughout.

    Context 'AC1 builds and returns a REST session for the portal URI' {

        It 'wraps New-RsRestSession, passes -ReportPortalUri, and returns its session' {
            InModuleScope RsMigration {
                # A real WebRequestSession sentinel: -WebSession on the downstream RS
                # cmdlets is strongly typed, so the session that flows through the
                # seams must be that type, not an arbitrary pscustomobject.
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsRestSession { return $sentinel }

                $session = New-RsMigrationRestSession -ReportPortalUri 'https://target/reports'

                # Returns exactly the session produced by the underlying cmdlet.
                [object]::ReferenceEquals($session, $sentinel) | Should -BeTrue
                $session | Should -BeOfType [Microsoft.PowerShell.Commands.WebRequestSession]

                Should -Invoke New-RsRestSession -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports'
                }
            }
        }

        It 'exposes a -ReportPortalUri parameter' {
            InModuleScope RsMigration {
                (Get-Command New-RsMigrationRestSession).Parameters.Keys |
                    Should -Contain 'ReportPortalUri'
            }
        }
    }

    Context 'AC1/AC2 authenticates as the current Windows identity (no credential)' {

        It 'never passes -Credential / username / password to New-RsRestSession' {
            InModuleScope RsMigration {
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsRestSession { return $sentinel }

                New-RsMigrationRestSession -ReportPortalUri 'https://target/reports'

                # Integrated auth = the underlying session cmdlet is invoked WITHOUT
                # any credential-bearing parameter, so it defaults to the current
                # Windows user. No NTLM/basic username or plaintext credential is wired.
                Should -Invoke New-RsRestSession -Times 1 -Exactly -ParameterFilter {
                    -not $PSBoundParameters.ContainsKey('Credential') -and
                    -not $PSBoundParameters.ContainsKey('UserName') -and
                    -not $PSBoundParameters.ContainsKey('Password')
                }
            }
        }
    }

    Context 'AC4 no credential wiring in the integrated-auth source files' {

        # A static source grep over the three files that participate in the
        # integrated-auth REST path: the helper and the two seams it feeds. None of
        # them may wire an explicit credential (the whole point is the current
        # Windows identity), so the credential tokens must not appear at all.
        It '<_> wires no credential (-Credential / UserName / Password / NetworkCredential)' -ForEach @(
            'New-RsMigrationRestSession.ps1'
            'Invoke-RsReportRender.ps1'
            'Test-RsDataSourceConnection.ps1'
        ) {
            $path = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration' 'Private' $_
            Test-Path $path | Should -BeTrue -Because "$_ must exist for the integrated-auth contract"
            if (Test-Path $path) {
                $content = Get-Content -Path $path -Raw
                $content | Should -Not -Match '-Credential'
                $content | Should -Not -Match 'UserName'
                $content | Should -Not -Match 'Password'
                $content | Should -Not -Match 'NetworkCredential'
            }
        }
    }
}
