#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Copy-RsMigrationBackup (Private helper)' {

    # Copies the two named .bak files from the SOURCE share to the TARGET share
    # over SMB. Both ends of every copy are built with Join-RsMigrationPath so the
    # paths are backslash-exact, and the copy command under test is Copy-Item
    # (chosen over robocopy because robocopy.exe does not exist on the macOS/Linux
    # gate and so cannot be mocked there).
    Context 'SMB copy of the .bak files' {

        It 'copies ReportServer.bak from the source share to the target share (exact UNC paths)' {
            InModuleScope RsMigration {
                Mock Copy-Item {}

                Copy-RsMigrationBackup -SourceSharePath '\\SRC\FileShare' `
                    -TargetSharePath '\\TGT\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Copy-Item -Times 1 -Exactly -ParameterFilter {
                    $Path -eq '\\SRC\FileShare\ReportServer.bak' -and
                    $Destination -eq '\\TGT\FileShare\ReportServer.bak'
                }
            }
        }

        It 'copies ReportServerTempDB.bak from the source share to the target share (exact UNC paths)' {
            InModuleScope RsMigration {
                Mock Copy-Item {}

                Copy-RsMigrationBackup -SourceSharePath '\\SRC\FileShare' `
                    -TargetSharePath '\\TGT\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Copy-Item -Times 1 -Exactly -ParameterFilter {
                    $Path -eq '\\SRC\FileShare\ReportServerTempDB.bak' -and
                    $Destination -eq '\\TGT\FileShare\ReportServerTempDB.bak'
                }
            }
        }

        It 'copies exactly one file per database (twice total)' {
            InModuleScope RsMigration {
                Mock Copy-Item {}

                Copy-RsMigrationBackup -SourceSharePath '\\SRC\FileShare' `
                    -TargetSharePath '\\TGT\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Copy-Item -Times 2 -Exactly
            }
        }
    }

    Context 'copy failure' {

        It 'surfaces a copy failure as a terminating error (does not swallow it)' {
            InModuleScope RsMigration {
                # Raise a NON-terminating error: this only becomes terminating
                # because production passes -ErrorAction Stop to Copy-Item. A plain
                # `throw` here would propagate regardless and so would not pin that
                # flag; Write-Error makes the test fail if -ErrorAction Stop is dropped.
                Mock Copy-Item { Write-Error 'copy failed' }

                # The underlying copy failure must propagate, not be swallowed: the
                # thrown message must carry the original copy error text.
                {
                    Copy-RsMigrationBackup -SourceSharePath '\\SRC\FileShare' `
                        -TargetSharePath '\\TGT\FileShare' `
                        -ReportServerBak 'ReportServer.bak' `
                        -ReportServerTempDbBak 'ReportServerTempDB.bak'
                } | Should -Throw -ExpectedMessage '*copy failed*'
            }
        }
    }
}
