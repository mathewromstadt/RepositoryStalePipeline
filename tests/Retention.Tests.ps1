BeforeAll {Import-Module "$PSScriptRoot/../Modules/BranchLifecycle/Retention.psm1" -Force}
Describe 'Warning grace period' {
 It 'warns on first detection then marks eligible after grace period' {
  $branch=[pscustomobject]@{ProjectId='p';RepoId='r';Ref='refs/heads/feature/a';ObjectId='abc'}
  $state=@{};$now=[datetime]'2026-10-01T00:00:00Z'
  Update-BranchRetention -Branch $branch -Decision 'Stale' -State $state -Now $now -GraceDays 7 | Should -Be 'Warn'
  Update-BranchRetention -Branch $branch -Decision 'Stale' -State $state -Now $now.AddDays(8) -GraceDays 7 | Should -Be 'Eligible'
 }
 It 'resets warning when tip changes' {
  $branch=[pscustomobject]@{ProjectId='p';RepoId='r';Ref='refs/heads/feature/a';ObjectId='abc'}
  $state=@{};$now=[datetime]'2026-10-01T00:00:00Z'
  Update-BranchRetention -Branch $branch -Decision 'Stale' -State $state -Now $now -GraceDays 7 | Should -Be 'Warn'
  $branch.ObjectId='def'
  Update-BranchRetention -Branch $branch -Decision 'Stale' -State $state -Now $now.AddDays(8) -GraceDays 7 | Should -Be 'Warn'
 }
}
