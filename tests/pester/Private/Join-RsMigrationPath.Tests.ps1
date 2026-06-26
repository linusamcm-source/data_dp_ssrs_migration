#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Join-RsMigrationPath (Private helper)' {

    # The migration runs over SMB fileshares whose paths are always
    # backslash-delimited UNC, but the quality gate runs on macOS/Linux where
    # Join-Path / [IO.Path] emit forward slashes. The helper must therefore build
    # the path by hand and produce the SAME backslash string on every host. Every
    # assertion below is an exact-string equality (Should -BeExactly), not a
    # host-dependent comparison.
    Context 'UNC share + file name' {

        It 'joins a share root and a file name with exactly one backslash (host-independent exact string)' {
            InModuleScope RsMigration {
                Join-RsMigrationPath -Share '\\h\FileShare' -FileName 'ReportServer.bak' |
                    Should -BeExactly '\\h\FileShare\ReportServer.bak'
            }
        }

        It 'normalises a trailing backslash on the share and a leading backslash on the file name to a single join' {
            InModuleScope RsMigration {
                Join-RsMigrationPath -Share '\\h\FileShare\' -FileName '\ReportServer.bak' |
                    Should -BeExactly '\\h\FileShare\ReportServer.bak'
            }
        }

        It 'collapses multiple separators between the inputs to exactly one backslash' {
            InModuleScope RsMigration {
                Join-RsMigrationPath -Share '\\h\FileShare\\' -FileName '\\ReportServerTempDB.bak' |
                    Should -BeExactly '\\h\FileShare\ReportServerTempDB.bak'
            }
        }

        It 'emits no forward slash in the joined path' {
            InModuleScope RsMigration {
                $joined = Join-RsMigrationPath -Share '\\h\FileShare' -FileName 'ReportServerTempDB.bak'
                $joined | Should -Not -Match '/'
            }
        }

        It 'does not use Join-Path (cross-OS separator safety)' {
            InModuleScope RsMigration {
                Mock Join-Path {}
                Join-RsMigrationPath -Share '\\h\FileShare' -FileName 'ReportServer.bak' | Out-Null
                Should -Invoke Join-Path -Times 0 -Exactly
            }
        }
    }
}
